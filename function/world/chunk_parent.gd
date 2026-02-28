# world/chunk_parent.gd
extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
@export var world_seed := 1
@export var fill_percent := 48
@export var smoothing_iterations := 12

var chunks = Array()

func generate_chunk(pos: Vector2i):
    if is_generated(pos):
        return
    force_generate(pos)

func is_generated(pos: Vector2i) -> bool:
    for c: Chunk in chunks:
        if c.chunk_pos == pos:
            return true
    return false

func force_generate(pos: Vector2i) -> Chunk:
    var c = chunk_scene.instantiate() as Chunk
    
    # Pass generation parameters to chunk
    c.world_seed = world_seed
    c.fill_percent = fill_percent
    c.smoothing_iterations = smoothing_iterations
    
    chunks.push_back(c)
    add_child(c)
    c.gen_init(pos)
    return c

func get_chunk(pos: Vector2i) -> Chunk:
    for c: Chunk in chunks:
        if c.chunk_pos == pos:
            return c
    return force_generate(pos)

func _ready() -> void:
    generate_chunk(Vector2i(0, 0))
    api_init()

func _process(delta: float) -> void:
    pass

func _enter_tree() -> void:
    instance = self

# World-space room creation (spans chunks if needed)
func create_room_at_world_pos(world_tile_pos: Vector2i, radius: int) -> void:
    # Get all chunks that this room might touch
    var min_chunk = get_chunk_pos(world_tile_pos - Vector2i(radius, radius))
    var max_chunk = get_chunk_pos(world_tile_pos + Vector2i(radius, radius))
    
    for cx in range(min_chunk.x, max_chunk.x + 1):
        for cy in range(min_chunk.y, max_chunk.y + 1):
            var chunk_p = Vector2i(cx, cy)
            var chunk = get_chunk(chunk_p)
            
            # Convert world pos to local chunk pos
            var local_center = world_tile_pos - (chunk_p * chunk.map_width)
            chunk.create_room(local_center, radius)

# API
var current_chunk: Chunk
var current_chunk_pos: Vector2i

func api_init():
    set_api_chunk(chunks[0])

func set_api_chunk(chunk: Chunk):
    current_chunk = chunk
    current_chunk_pos = current_chunk.chunk_pos

func check_chunk(pos: Vector2i):
    if current_chunk_pos == pos:
        return
    set_api_chunk(get_chunk(pos))

func api_get_tile_pos(pos: Vector2i) -> int:
    var c_pos = get_chunk_pos(pos)
    check_chunk(c_pos)
    pos = pos_modulo_chunk(pos)
    return current_chunk.api_get_tile_pos(pos)

func api_set_tile_pos(tile_pos: Vector2i, val: int):
    var c_pos = get_chunk_pos(tile_pos)
    check_chunk(c_pos)
    tile_pos = pos_modulo_chunk(tile_pos)
    current_chunk.api_set_tile_pos(tile_pos, val)

func snap_global_to_grid(pos: Vector2) -> Vector2i:
    pos = pos / chunks[0].tile_set.tile_size.x
    return pos as Vector2i

func get_chunk_pos(pos: Vector2i) -> Vector2i:
    # Handle negative positions correctly
    var chunk_w = chunks[0].map_width
    return Vector2i(
        floori(float(pos.x) / chunk_w),
        floori(float(pos.y) / chunk_w)
    )

func pos_modulo_chunk(pos: Vector2i) -> Vector2i:
    var chunk_w = chunks[0].map_width
    # Handle negative modulo correctly
    return Vector2i(
        posmod(pos.x, chunk_w),
        posmod(pos.y, chunk_w)
    )

# Regenerate a specific chunk
func regenerate_chunk(pos: Vector2i) -> void:
    var chunk = get_chunk(pos)
    chunk.create_cells()
    chunk.generate()

# \API
