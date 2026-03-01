#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// ============================================
// CONSTANTS
// ============================================

const int FOG_SIZE = 16;
const float LIGHT_RADIUS = 48.0;
const float LIGHT_INNER_RADIUS = 4.0;
const float LIGHT_FULL_BRIGHT = 2.0;
const float EXPLORED_BRIGHTNESS = 0.55;
const float EXPLORED_EDGE_BRIGHTNESS = 0.30;
const int FLOOD_FILL_THRESHOLD = 4;

// ============================================
// BUFFERS
// ============================================

layout(set = 0, binding = 0, std430) restrict buffer Params {
    int num_chunks;
    int num_lights;
    int pass_type;          // 0=stamp, 1=flood, 2=blur, 3=compose
    int iteration;
    // Chunk data: [chunk_world_x, chunk_world_y, buffer_offset, padding] per chunk
    ivec4 chunk_info[256];  // Support up to 256 chunks per batch
} params;

layout(set = 0, binding = 1, std430) restrict buffer Lights {
    // [world_tile_x, world_tile_y, radius, intensity] per light
    vec4 lights[64];  // Support up to 64 lights
} light_buf;

layout(set = 0, binding = 2, std430) restrict buffer ExploredData {
    float explored[];  // FOG_SIZE * FOG_SIZE * num_chunks
} explored_buf;

layout(set = 0, binding = 3, std430) restrict buffer VisibleData {
    float visible[];
} visible_buf;

layout(set = 0, binding = 4, std430) restrict buffer TempData {
    float temp[];
} temp_buf;

layout(set = 0, binding = 5, std430) restrict buffer TempData2 {
    float temp2[];
} temp2_buf;

layout(set = 0, binding = 6, std430) restrict buffer OutputData {
    uint output_rgba[];  // Packed RGBA8 output
} output_buf;

// ============================================
// SHARED MEMORY
// ============================================

shared float s_visible[18][18];   // 16x16 + 1 border each side
shared float s_explored[18][18];
shared float s_temp[18][18];

// ============================================
// HELPER FUNCTIONS
// ============================================

float smoothstep_custom(float t) {
    t = clamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

float smootherstep(float t) {
    t = clamp(t, 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float calculate_light_value(float dist, float radius, float intensity) {
    if (dist <= LIGHT_FULL_BRIGHT) {
        return intensity;
    } else if (dist <= LIGHT_INNER_RADIUS) {
        float t = (dist - LIGHT_FULL_BRIGHT) / (LIGHT_INNER_RADIUS - LIGHT_FULL_BRIGHT);
        t = smoothstep_custom(t);
        return mix(intensity, intensity * 0.92, t);
    } else if (dist >= radius) {
        return 0.0;
    } else {
        float t = (dist - LIGHT_INNER_RADIUS) / (radius - LIGHT_INNER_RADIUS);
        t = smootherstep(t);
        return mix(intensity * 0.92, 0.0, t);
    }
}

// ============================================
// PASS FUNCTIONS
// ============================================

void stamp_lights(int chunk_idx, int local_x, int local_y, int buf_offset) {
    int chunk_world_x = params.chunk_info[chunk_idx].x;
    int chunk_world_y = params.chunk_info[chunk_idx].y;

    // World tile position of this pixel
    int world_x = chunk_world_x * FOG_SIZE + local_x;
    int world_y = chunk_world_y * FOG_SIZE + local_y;

    float max_light = 0.0;

    // Check all lights
    for (int i = 0; i < params.num_lights; i++) {
        vec4 light = light_buf.lights[i];
        float light_x = light.x;
        float light_y = light.y;
        float radius = light.z;
        float intensity = light.w;

        float dx = float(world_x) - light_x;
        float dy = float(world_y) - light_y;
        float dist = sqrt(dx * dx + dy * dy);

        if (dist < radius) {
            float value = calculate_light_value(dist, radius, intensity);
            max_light = max(max_light, value);
        }
    }

    int idx = buf_offset + local_y * FOG_SIZE + local_x;
    visible_buf.visible[idx] = max_light;

    // Update explored
    float current_explored = explored_buf.explored[idx];
    if (max_light > current_explored) {
        explored_buf.explored[idx] = max_light;
    }
}

void flood_fill_pass(int chunk_idx, int local_x, int local_y, int buf_offset) {
    // Load into shared memory
    int idx = buf_offset + local_y * FOG_SIZE + local_x;
    s_explored[local_y + 1][local_x + 1] = explored_buf.explored[idx];

    // Load borders (edges remain 0)
    if (local_x == 0) {
        s_explored[local_y + 1][0] = 0.0;
    }
    if (local_x == 15) {
        s_explored[local_y + 1][17] = 0.0;
    }
    if (local_y == 0) {
        s_explored[0][local_x + 1] = 0.0;
    }
    if (local_y == 15) {
        s_explored[17][local_x + 1] = 0.0;
    }
    if (local_x == 0 && local_y == 0) {
        s_explored[0][0] = 0.0;
    }
    if (local_x == 15 && local_y == 0) {
        s_explored[0][17] = 0.0;
    }
    if (local_x == 0 && local_y == 15) {
        s_explored[17][0] = 0.0;
    }
    if (local_x == 15 && local_y == 15) {
        s_explored[17][17] = 0.0;
    }

    barrier();

    // Skip edges for flood fill
    if (local_x == 0 || local_x == 15 || local_y == 0 || local_y == 15) {
        return;
    }

    float current = s_explored[local_y + 1][local_x + 1];
    if (current >= EXPLORED_BRIGHTNESS) {
        return;
    }

    // Count explored neighbors
    int count = 0;
    float neighbor_sum = 0.0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float nv = s_explored[local_y + 1 + dy][local_x + 1 + dx];
            if (nv >= EXPLORED_BRIGHTNESS) {
                count++;
                neighbor_sum += nv;
            }
        }
    }

    if (count >= FLOOD_FILL_THRESHOLD) {
        float avg = neighbor_sum / float(count);
        float new_val = min(avg, EXPLORED_BRIGHTNESS);
        if (new_val > current) {
            explored_buf.explored[idx] = new_val;
        }
    }
}

// Blur pass with ping-pong: iteration 0 read explored write temp, 1 read temp write temp2, 2 read temp2 write temp
float _blur_read(int buf_offset, int local_x, int local_y, int iter) {
    int idx = buf_offset + local_y * FOG_SIZE + local_x;
    if (iter == 0) {
        return explored_buf.explored[idx];
    } else if (iter == 1) {
        return temp_buf.temp[idx];
    } else {
        return temp2_buf.temp2[idx];
    }
}

void blur_pass(int chunk_idx, int local_x, int local_y, int buf_offset) {
    int idx = buf_offset + local_y * FOG_SIZE + local_x;
    int iter = params.iteration;

    // Load into shared memory from the appropriate source
    float current = _blur_read(buf_offset, local_x, local_y, iter);
    s_temp[local_y + 1][local_x + 1] = current;

    // Load borders
    if (local_x == 0) {
        s_temp[local_y + 1][0] = _blur_read(buf_offset, 0, local_y, iter);
    }
    if (local_x == 15) {
        s_temp[local_y + 1][17] = _blur_read(buf_offset, 15, local_y, iter);
    }
    if (local_y == 0) {
        s_temp[0][local_x + 1] = _blur_read(buf_offset, local_x, 0, iter);
    }
    if (local_y == 15) {
        s_temp[17][local_x + 1] = _blur_read(buf_offset, local_x, 15, iter);
    }
    if (local_x == 0 && local_y == 0) {
        s_temp[0][0] = _blur_read(buf_offset, 0, 0, iter);
    }
    if (local_x == 15 && local_y == 0) {
        s_temp[0][17] = _blur_read(buf_offset, 15, 0, iter);
    }
    if (local_x == 0 && local_y == 15) {
        s_temp[17][0] = _blur_read(buf_offset, 0, 15, iter);
    }
    if (local_x == 15 && local_y == 15) {
        s_temp[17][17] = _blur_read(buf_offset, 15, 15, iter);
    }

    barrier();

    float center = s_temp[local_y + 1][local_x + 1];

    if (center >= EXPLORED_BRIGHTNESS) {
        if (iter == 0) {
            temp_buf.temp[idx] = center;
        } else if (iter == 1) {
            temp2_buf.temp2[idx] = center;
        } else {
            temp_buf.temp[idx] = center;
        }
        return;
    }

    // Find max neighbor with falloff
    float max_neighbor = 0.0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            float nv = s_temp[local_y + 1 + dy][local_x + 1 + dx];
            float weight = (dx != 0 && dy != 0) ? 0.6 : 0.75;
            float contributed = nv * weight;
            max_neighbor = max(max_neighbor, contributed);
        }
    }

    float result = center;
    if (max_neighbor > result && max_neighbor > EXPLORED_EDGE_BRIGHTNESS * 0.3) {
        result = max_neighbor;
    }
    result = min(result, EXPLORED_BRIGHTNESS);

    if (iter == 0) {
        temp_buf.temp[idx] = result;
    } else if (iter == 1) {
        temp2_buf.temp2[idx] = result;
    } else {
        temp_buf.temp[idx] = result;
    }
}

// Compose reads from temp_buf (final blur output after odd number of iterations)
void compose_output(int chunk_idx, int local_x, int local_y, int buf_offset) {
    int idx = buf_offset + local_y * FOG_SIZE + local_x;

    float vis = visible_buf.visible[idx];
    float exp_val = temp_buf.temp[idx];

    float brightness;
    if (vis > 0.0) {
        float explored_contrib = exp_val * EXPLORED_BRIGHTNESS;
        brightness = max(vis, explored_contrib);
    } else {
        brightness = exp_val * EXPLORED_BRIGHTNESS;
        if (brightness > 0.0 && brightness < EXPLORED_BRIGHTNESS * 0.9) {
            float t = brightness / (EXPLORED_BRIGHTNESS * 0.9);
            t = smoothstep_custom(t);
            brightness = t * EXPLORED_BRIGHTNESS * 0.9;
        }
    }

    brightness = clamp(brightness, 0.0, 1.0);

    // Pack as RGBA8 (grayscale)
    uint r = uint(brightness * 255.0);
    uint g = r;
    uint b = r;
    uint a = 255u;

    output_buf.output_rgba[idx] = (a << 24) | (b << 16) | (g << 8) | r;
}

// ============================================
// MAIN
// ============================================

void main() {
    int local_x = int(gl_LocalInvocationID.x);
    int local_y = int(gl_LocalInvocationID.y);
    int chunk_idx = int(gl_WorkGroupID.z);

    if (chunk_idx >= params.num_chunks) {
        return;
    }

    int buf_offset = params.chunk_info[chunk_idx].z;

    switch (params.pass_type) {
        case 0:  // Stamp lights
            stamp_lights(chunk_idx, local_x, local_y, buf_offset);
            break;
        case 1:  // Flood fill
            flood_fill_pass(chunk_idx, local_x, local_y, buf_offset);
            break;
        case 2:  // Blur
            blur_pass(chunk_idx, local_x, local_y, buf_offset);
            break;
        case 3:  // Compose output
            compose_output(chunk_idx, local_x, local_y, buf_offset);
            break;
    }
}
