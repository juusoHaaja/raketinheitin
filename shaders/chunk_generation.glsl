#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// ============================================
// UNIFORMS
// ============================================

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int offset_x;
    int offset_y;
    int width;
    int height;
    int seed;
    float cave_threshold;
    int smoothing_iterations;
    int num_materials;
    // Material data: [threshold, weight, frequency, octaves] x num_materials
    vec4 material_params[8];
} params;

layout(set = 0, binding = 1, std430) restrict buffer CellsA {
    int cells[];
} cells_a;

layout(set = 0, binding = 2, std430) restrict buffer CellsB {
    int cells[];
} cells_b;

layout(set = 0, binding = 3, std430) restrict buffer MaterialBuffer {
    int materials[];
} mat_buf;

layout(set = 0, binding = 4, std430) restrict buffer OutputCells {
    int output_cells[];
} output_buf;

// Push constant for ping-pong and pass type
layout(push_constant) uniform PushConstants {
    int pass_type;      // 0 = init, 1 = smooth (read A write B), 2 = smooth (read B write A), 3 = finalize
    int iteration;
} pc;

// ============================================
// NOISE FUNCTIONS
// ============================================

// Permutation polynomial
vec3 permute(vec3 x) {
    return mod(((x * 34.0) + 1.0) * x, 289.0);
}

// Simplex 2D noise
float snoise(vec2 v) {
    const vec4 C = vec4(
        0.211324865405187,   // (3.0-sqrt(3.0))/6.0
        0.366025403784439,   // 0.5*(sqrt(3.0)-1.0)
        -0.577350269189626,  // -1.0 + 2.0 * C.x
        0.024390243902439    // 1.0 / 41.0
    );
    
    // First corner
    vec2 i = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    
    // Other corners
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    
    // Permutations
    i = mod(i, 289.0);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    
    // Gradients
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    
    return 130.0 * dot(m, g);
}

// Fractal Brownian Motion noise
float fbm(vec2 pos, float frequency, int octaves, int seed_offset) {
    float value = 0.0;
    float amplitude = 0.5;
    float freq = frequency;
    float seed_f = float(params.seed + seed_offset);
    
    for (int i = 0; i < octaves && i < 8; i++) {
        vec2 p = pos * freq + vec2(seed_f * 0.1, seed_f * 0.07);
        value += amplitude * snoise(p);
        freq *= 2.0;
        amplitude *= 0.5;
    }
    
    return value;
}

// ============================================
// HELPER FUNCTIONS
// ============================================

int get_cell_a(int x, int y) {
    if (x < 0 || x >= params.width || y < 0 || y >= params.height) {
        // Out of bounds - use noise to determine
        float wx = float(params.offset_x + x);
        float wy = float(params.offset_y + y);
        float noise_val = fbm(vec2(wx, wy), 0.01, 4, 0);
        return (noise_val > params.cave_threshold) ? 1 : 0;
    }
    return cells_a.cells[x + y * params.width];
}

int get_cell_b(int x, int y) {
    if (x < 0 || x >= params.width || y < 0 || y >= params.height) {
        float wx = float(params.offset_x + x);
        float wy = float(params.offset_y + y);
        float noise_val = fbm(vec2(wx, wy), 0.01, 4, 0);
        return (noise_val > params.cave_threshold) ? 1 : 0;
    }
    return cells_b.cells[x + y * params.width];
}

int count_neighbors_a(int x, int y) {
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            count += get_cell_a(x + dx, y + dy);
        }
    }
    return count;
}

int count_neighbors_b(int x, int y) {
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            count += get_cell_b(x + dx, y + dy);
        }
    }
    return count;
}

int get_material(int wx, int wy) {
    int best_material = 1;
    float best_value = -999.0;
    
    vec2 world_pos = vec2(float(wx), float(wy));
    
    for (int i = 0; i < params.num_materials && i < 8; i++) {
        vec4 mp = params.material_params[i];
        float threshold = mp.x;
        float weight = mp.y;
        float frequency = mp.z;
        int octaves = int(mp.w);
        
        if (weight > 0.0) {
            float noise_val = fbm(world_pos, frequency, octaves, (i + 1) * 12345);
            float adjusted = (noise_val - threshold) * weight;
            
            if (adjusted > best_value) {
                best_value = adjusted;
                best_material = i + 1;
            }
        }
    }
    
    return best_material;
}

int get_dominant_neighbor_material(int x, int y, int wx, int wy, bool read_from_a) {
    int counts[16];
    for (int i = 0; i < 16; i++) counts[i] = 0;
    
    int best_mat = 1;
    int best_count = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            int nx = x + dx;
            int ny = y + dy;
            int nwx = wx + dx;
            int nwy = wy + dy;
            
            int is_solid;
            int mat_val = 0;
            
            if (nx >= 0 && nx < params.width && ny >= 0 && ny < params.height) {
                int idx = nx + ny * params.width;
                is_solid = read_from_a ? cells_a.cells[idx] : cells_b.cells[idx];
                if (is_solid != 0) {
                    mat_val = mat_buf.materials[idx];
                }
            } else {
                float noise_val = fbm(vec2(float(nwx), float(nwy)), 0.01, 4, 0);
                if (noise_val > params.cave_threshold) {
                    mat_val = get_material(nwx, nwy);
                }
            }
            
            if (mat_val > 0 && mat_val < 16) {
                counts[mat_val]++;
                if (counts[mat_val] > best_count) {
                    best_count = counts[mat_val];
                    best_mat = mat_val;
                }
            }
        }
    }
    
    return best_mat;
}

// ============================================
// MAIN
// ============================================

void main() {
    int x = int(gl_GlobalInvocationID.x);
    int y = int(gl_GlobalInvocationID.y);
    
    if (x >= params.width || y >= params.height) {
        return;
    }
    
    int idx = x + y * params.width;
    int wx = params.offset_x + x;
    int wy = params.offset_y + y;
    
    // Pass 0: Initialize from noise
    if (pc.pass_type == 0) {
        float cave_val = fbm(vec2(float(wx), float(wy)), 0.01, 4, 0);
        
        if (cave_val > params.cave_threshold) {
            cells_a.cells[idx] = 1;
            mat_buf.materials[idx] = get_material(wx, wy);
        } else {
            cells_a.cells[idx] = 0;
            mat_buf.materials[idx] = 0;
        }
        return;
    }
    
    // Pass 1: Smooth (read A, write B)
    if (pc.pass_type == 1) {
        int neighbors = count_neighbors_a(x, y);
        int current = cells_a.cells[idx];
        
        if (neighbors > 4) {
            cells_b.cells[idx] = 1;
            if (current == 0) {
                mat_buf.materials[idx] = get_dominant_neighbor_material(x, y, wx, wy, true);
            }
        } else if (neighbors < 4) {
            cells_b.cells[idx] = 0;
            mat_buf.materials[idx] = 0;
        } else {
            cells_b.cells[idx] = current;
        }
        return;
    }
    
    // Pass 2: Smooth (read B, write A)
    if (pc.pass_type == 2) {
        int neighbors = count_neighbors_b(x, y);
        int current = cells_b.cells[idx];
        
        if (neighbors > 4) {
            cells_a.cells[idx] = 1;
            if (current == 0) {
                mat_buf.materials[idx] = get_dominant_neighbor_material(x, y, wx, wy, false);
            }
        } else if (neighbors < 4) {
            cells_a.cells[idx] = 0;
            mat_buf.materials[idx] = 0;
        } else {
            cells_a.cells[idx] = current;
        }
        return;
    }
    
    // Pass 3: Finalize (combine solid + material into output)
    if (pc.pass_type == 3) {
        // After even iterations, result is in A; after odd, in B
        int is_solid = ((params.smoothing_iterations % 2) == 0)
            ? cells_a.cells[idx]
            : cells_b.cells[idx];
        
        if (is_solid != 0) {
            output_buf.output_cells[idx] = mat_buf.materials[idx];
        } else {
            output_buf.output_cells[idx] = 0;
        }
        return;
    }
}
