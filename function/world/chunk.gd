# world/chunk.gd
extends TileMapLayer
class_name Chunk

# chunk
static var chunk_size = 100 # size in tiles
var chunk_pos = Vector2i(0,0)

@export var tileset_width = 8
@export var tileset_height = 8
var tileset_count = tileset_width*tileset_height

@export var map_width = 100
@export var map_height = 100

var tile_pixel_size = 1

var cells = PackedByteArray()

# Cave generation parameters
@export var fill_percent := 48
@export var smoothing_iterations := 12
@export_range(0, 999999) var world_seed := 1

var _temp_map := {}  # Temporary dictionary for cave generation

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

func cell_byte_to_tilemap(b: int) -> int:
    if b == 0:
        return 0
    else:
        return 1

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

# Chunk generation functions

func gen_init(pos: Vector2i):
    chunk_pos = pos
    global_position = pos * chunk_size * tile_pixel_size
    create_cells()
    generate()

func generate():
    _initialize_cave_map()
    
    for i in smoothing_iterations:
        _smooth_map()
    
    _apply_cave_to_cells()

# Cave Generation - Initialization

func _get_chunk_seed() -> int:
    # Create unique seed based on chunk position and world seed
    # Using large prime numbers for better distribution
    return world_seed + chunk_pos.x * 73856093 + chunk_pos.y * 19349663

func _initialize_cave_map() -> void:
    seed(_get_chunk_seed())
    _temp_map.clear()
    
    for x in range(map_width):
        for y in range(map_height):
            var pos := Vector2i(x, y)
            # Edges are always walls for cleaner chunk boundaries
            if x == 0 or x == map_width - 1 or y == 0 or y == map_height - 1:
                _temp_map[pos] = true
            else:
                _temp_map[pos] = randf() * 100 < fill_percent

# Cave Generation - Cellular Automata Smoothing

func _smooth_map() -> void:
    var new_map := {}
    
    for x in range(map_width):
        for y in range(map_height):
            var pos := Vector2i(x, y)
            var wall_count := _get_surrounding_wall_count(pos)
            
            # Cellular automata rules
            if wall_count > 4:
                new_map[pos] = true
            elif wall_count < 4:
                new_map[pos] = false
            else:
                new_map[pos] = _temp_map[pos]
    
    _temp_map = new_map

func _get_surrounding_wall_count(pos: Vector2i) -> int:
    var wall_count := 0
    
    for x in range(-1, 2):
        for y in range(-1, 2):
            var check_pos := Vector2i(pos.x + x, pos.y + y)
            if check_pos != pos:
                # Default to wall if outside bounds
                if _temp_map.get(check_pos, true):
                    wall_count += 1
    
    return wall_count

# Cave Generation - Room Creation

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

# Cave Generation - Apply to Cell Array

func _apply_cave_to_cells() -> void:
    for i in range(cells.size()):
        var pos = cell_index_to_pos(i)
        if _temp_map.get(pos, true):
            cells[i] = 1  # Wall tile
        else:
            cells[i] = 0  # Empty
    
    update_cells()
    _temp_map.clear()  # Free memory

# Cave Generation - Force Walls at Edges

func force_edge_walls() -> void:
    # Top and bottom edges
    for x in range(map_width):
        api_set_tile_pos(Vector2i(x, 0), 1)
        api_set_tile_pos(Vector2i(x, map_height - 1), 1)
    
    # Left and right edges
    for y in range(map_height):
        api_set_tile_pos(Vector2i(0, y), 1)
        api_set_tile_pos(Vector2i(map_width - 1, y), 1)
