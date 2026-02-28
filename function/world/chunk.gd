# world/chunk.gd
extends TileMapLayer
class_name Chunk

static var chunk_size = 16
var chunk_pos = Vector2i(0, 0)
var chunk_parent: ChunkParent

@export var tileset_width = 8
@export var tileset_height = 8
var tileset_count = tileset_width * tileset_height

@export var map_width: int = 16
@export var map_height: int = 16

var tile_pixel_size = 1

var cells = PackedByteArray()

# Cave generation parameters
@export var fill_percent := 48
@export var smoothing_iterations := 12
@export_range(0, 999999) var world_seed := 1

var generation_complete := false

# Use PackedByteArrays instead of Dictionary
var _temp_solid: PackedByteArray      # 0 or 1 — is solid?
var _temp_material: PackedByteArray   # material index
var _smooth_buffer: PackedByteArray   # double-buffer for smoothing

func clear_cells():
    cells.clear()

func create_cells():
    clear_cells()
    cells.resize(map_width * map_height)
    cells.fill(1)

func pos_to_cell_index(pos: Vector2i) -> int:
    return pos.x + pos.y * map_width

func cell_index_to_pos(index: int) -> Vector2i:
    return Vector2i(index % map_width, index / map_width)

func local_to_world_pos(local_pos: Vector2i) -> Vector2i:
    return local_pos + chunk_pos * map_width

func world_to_local_pos(world_pos: Vector2i) -> Vector2i:
    return world_pos - chunk_pos * map_width

func api_get_tile_pos(pos: Vector2i) -> int:
    return api_get_tile(pos_to_cell_index(pos))

func api_set_tile_pos(pos: Vector2i, val: int):
    api_set_tile(pos_to_cell_index(pos), val)

func api_get_tile(index: int) -> int:
    return cells[index]

func api_set_tile(index: int, val: int):
    cells[index] = val
    var coords = cell_index_to_pos(index)
    set_tileset_tile(coords, val)

func global_to_grid(pos: Vector2) -> Vector2i:
    pos = pos / tile_set.tile_size.x
    return pos as Vector2i

func tilemap_index_to_source_coord(i: int) -> Vector2i:
    return Vector2i(i % tileset_width, i / tileset_width)

func set_tileset_tile(pos: Vector2i, b: int):
    if b == 0:
        set_cell(pos, -1, Vector2i(-1, -1), -1)
    else:
        var i = (b - 1) % tileset_count
        set_cell(pos, 0, tilemap_index_to_source_coord(i), 0)

func update_cells():
    for i in range(cells.size()):
        var val = cells[i]
        var pos = cell_index_to_pos(i)
        set_tileset_tile(pos, val)

func calculate_tile_size() -> float:
    return scale.x * tile_set.tile_size.x

func _ready() -> void:
    tile_pixel_size = calculate_tile_size()

# --- Generation ---

func gen_init(pos: Vector2i):
    chunk_pos = pos
    global_position = pos * chunk_size * tile_pixel_size
    create_cells()
    generate()

func generate():
    generation_complete = false
    var total_size: int = map_width * map_height

    _temp_solid.resize(total_size)
    _temp_material.resize(total_size)
    _smooth_buffer.resize(total_size)

    _initialize_cave_map()

    for iteration in smoothing_iterations:
        _smooth_map()

    _apply_cave_to_cells()
    generation_complete = true
    
func _initialize_cave_map() -> void:
    var threshold: float = (fill_percent - 50.0) / 50.0 * 0.5
    var cave_noise: FastNoiseLite = chunk_parent.cave_noise
    var chunk_offset: Vector2i = chunk_pos * map_width

    var index: int = 0
    for y in range(map_height):
        var wy: int = chunk_offset.y + y
        for x in range(map_width):
            var wx: int = chunk_offset.x + x
            var cave_val: float = cave_noise.get_noise_2d(wx, wy)

            if cave_val > threshold:
                _temp_solid[index] = 1
                _temp_material[index] = chunk_parent.get_material_at_world_pos(Vector2i(wx, wy))
            else:
                _temp_solid[index] = 0
                _temp_material[index] = 0
            index += 1
            
func _smooth_map() -> void:
    # Pre-cache border solid values so cross-chunk lookups are batched
    # For interior cells, direct array access is used (no dictionary)

    var w := map_width
    var h := map_height
    var chunk_offset: Vector2i = chunk_pos * w

    # Copy solid to smooth_buffer first, then swap
    _smooth_buffer.fill(0)

    var index := 0
    for y in range(h):
        for x in range(w):
            var wall_count := _count_neighbors_fast(x, y, w, h, chunk_offset)
            var current_solid: int = _temp_solid[index]

            if wall_count > 4:
                _smooth_buffer[index] = 1
                # If it was empty and now becoming solid, pick a material
                if current_solid == 0:
                    _temp_material[index] = _get_dominant_neighbor_material_fast(x, y, w, h, chunk_offset)
            elif wall_count < 4:
                _smooth_buffer[index] = 0
                _temp_material[index] = 0
            else:
                _smooth_buffer[index] = current_solid
            index += 1

    # Swap buffers
    var tmp := _temp_solid
    _temp_solid = _smooth_buffer
    _smooth_buffer = tmp

func _count_neighbors_fast(x: int, y: int, w: int, h: int, chunk_offset: Vector2i) -> int:
    var count := 0

    # Unrolled 3x3 neighbor check (skip center)
    for dy in range(-1, 2):
        var ny := y + dy
        for dx in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
            var nx := x + dx

            if nx >= 0 and nx < w and ny >= 0 and ny < h:
                # Interior — direct array access
                if _temp_solid[nx + ny * w] != 0:
                    count += 1
            else:
                # Border — cross-chunk lookup via noise (no chunk instantiation)
                var world_pos := Vector2i(chunk_offset.x + nx, chunk_offset.y + ny)
                if chunk_parent.is_solid_at_world_pos(world_pos):
                    count += 1
    return count

func _get_dominant_neighbor_material_fast(x: int, y: int, w: int, h: int, chunk_offset: Vector2i) -> int:
    # Use a small fixed array for counting materials (max ~64 material types)
    # For simplicity, track best inline
    var best_mat := 1
    var best_count := 0
    # Simple approach: small dictionary is fine here since this is called rarely
    var counts := {}

    for dy in range(-1, 2):
        var ny := y + dy
        for dx in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
            var nx := x + dx
            var val := 0

            if nx >= 0 and nx < w and ny >= 0 and ny < h:
                var ni := nx + ny * w
                if _temp_solid[ni] != 0:
                    val = _temp_material[ni]
            else:
                var world_pos := Vector2i(chunk_offset.x + nx, chunk_offset.y + ny)
                if chunk_parent.is_solid_at_world_pos(world_pos):
                    val = chunk_parent.get_material_at_world_pos(world_pos)

            if val != 0:
                var c: int = counts.get(val, 0) + 1
                counts[val] = c
                if c > best_count:
                    best_count = c
                    best_mat = val

    return best_mat

func _apply_cave_to_cells() -> void:
    var size := cells.size()
    for i in range(size):
        if _temp_solid[i] != 0:
            cells[i] = _temp_material[i]
        else:
            cells[i] = 0

    update_cells()

    # Free buffers
    _temp_solid = PackedByteArray()
    _temp_material = PackedByteArray()
    _smooth_buffer = PackedByteArray()

# Room Creation
func create_room(center: Vector2i, radius: int) -> void:
    var r_sq := radius * radius
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            var local_pos := Vector2i(center.x + x, center.y + y)
            if local_pos.x >= 0 and local_pos.x < map_width and \
               local_pos.y >= 0 and local_pos.y < map_height:
                if x * x + y * y <= r_sq:  # Avoid sqrt
                    var index = pos_to_cell_index(local_pos)
                    cells[index] = 0
                    set_tileset_tile(local_pos, 0)
