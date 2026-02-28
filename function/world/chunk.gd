# world/chunk.gd
extends TileMapLayer
class_name Chunk

# Chunk properties
static var chunk_size = 100
var chunk_pos = Vector2i(0, 0)
var chunk_parent: ChunkParent

@export var tileset_width = 8
@export var tileset_height = 8
var tileset_count = tileset_width * tileset_height

@export var map_width = 100
@export var map_height = 100

var tile_pixel_size = 1

var cells = PackedByteArray()

# Cave generation parameters
@export var fill_percent := 48
@export var smoothing_iterations := 12
@export_range(0, 999999) var world_seed := 1

var generation_complete := false

var _temp_map := {}

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

func _process(delta: float) -> void:
    pass

# Chunk generation
func gen_init(pos: Vector2i):
    chunk_pos = pos
    global_position = pos * chunk_size * tile_pixel_size
    create_cells()
    generate()

func generate():
    generation_complete = false
    _initialize_cave_map()
    
    for i in smoothing_iterations:
        _smooth_map()
    
    _apply_cave_to_cells()
    generation_complete = true

# Cave Generation Init
func _initialize_cave_map() -> void:
    _temp_map.clear()
    
    for x in range(map_width):
        for y in range(map_height):
            var local_pos := Vector2i(x, y)
            var world_pos := local_to_world_pos(local_pos)
            
            # Use noise for cave structure
            var cave_val = chunk_parent.get_cave_value_at_world_pos(world_pos)
            
            # Convert fill_percent to threshold
            var threshold = (fill_percent - 50.0) / 50.0 * 0.5
            
            if cave_val > threshold:
                # Solid - get material from noise
                _temp_map[local_pos] = chunk_parent.get_material_at_world_pos(world_pos)
            else:
                _temp_map[local_pos] = 0  # Empty

# Cellular Automata Smoothing
func _smooth_map() -> void:
    var new_map := {}
    
    for x in range(map_width):
        for y in range(map_height):
            var local_pos := Vector2i(x, y)
            var wall_count := _get_surrounding_wall_count(local_pos)
            var current_val: int = _temp_map.get(local_pos, 1)
            
            if wall_count > 4:
                if current_val == 0:
                    new_map[local_pos] = _get_dominant_neighbor_material(local_pos)
                else:
                    new_map[local_pos] = current_val
            elif wall_count < 4:
                new_map[local_pos] = 0
            else:
                new_map[local_pos] = current_val
    
    _temp_map = new_map

func _get_surrounding_wall_count(local_pos: Vector2i) -> int:
    var wall_count := 0
    
    for dx in range(-1, 2):
        for dy in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
                
            var check_local := Vector2i(local_pos.x + dx, local_pos.y + dy)
            
            # Check if within this chunk
            if check_local.x >= 0 and check_local.x < map_width and \
               check_local.y >= 0 and check_local.y < map_height:
                # Use local temp map
                var val: int = _temp_map.get(check_local, 1)
                if val != 0:
                    wall_count += 1
            else:
                # Cross-chunk lookup using world position
                var world_pos := local_to_world_pos(check_local)
                if chunk_parent.is_solid_at_world_pos(world_pos):
                    wall_count += 1
    
    return wall_count

func _get_dominant_neighbor_material(local_pos: Vector2i) -> int:
    var counts := {}
    
    for dx in range(-1, 2):
        for dy in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
                
            var check_local := Vector2i(local_pos.x + dx, local_pos.y + dy)
            var val := 0
            
            if check_local.x >= 0 and check_local.x < map_width and \
               check_local.y >= 0 and check_local.y < map_height:
                val = _temp_map.get(check_local, 1)
            else:
                # For cross-chunk, get material from noise
                var world_pos := local_to_world_pos(check_local)
                if chunk_parent.is_solid_at_world_pos(world_pos):
                    val = chunk_parent.get_material_at_world_pos(world_pos)
            
            if val != 0:
                counts[val] = counts.get(val, 0) + 1
    
    var best_mat := 1
    var best_count := 0
    for mat in counts:
        if counts[mat] > best_count:
            best_count = counts[mat]
            best_mat = mat
    
    return best_mat

# Room Creation
func create_room(center: Vector2i, radius: int) -> void:
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            var local_pos := Vector2i(center.x + x, center.y + y)
            
            if local_pos.x >= 0 and local_pos.x < map_width and \
               local_pos.y >= 0 and local_pos.y < map_height:
                if Vector2(x, y).length() <= radius:
                    var index = pos_to_cell_index(local_pos)
                    cells[index] = 0
                    set_tileset_tile(local_pos, 0)

func _apply_cave_to_cells() -> void:
    for i in range(cells.size()):
        var pos = cell_index_to_pos(i)
        var val: int = _temp_map.get(pos, 1)
        cells[i] = val
    
    update_cells()
    _temp_map.clear()
