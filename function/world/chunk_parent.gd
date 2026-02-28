extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
var chunks = Array()

func generate_chunk(pos: Vector2i):
    if is_generated(pos):
        return
    force_generate(pos)

func is_generated(pos: Vector2i)-> bool:
    for c:Chunk in chunks:
        if c.chunk_pos == pos:
            return true
    return false

func force_generate(pos:Vector2i) -> Chunk:
    var c = chunk_scene.instantiate() as Chunk
    chunks.push_back(c)
    add_child(c);
    c.gen_init(pos)
    return c

func get_chunk(pos: Vector2i) -> Chunk:
    for c:Chunk in chunks:
        if c.chunk_pos == pos:
            return c
    return force_generate(pos)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    generate_chunk(Vector2i(0,0))
    api_init()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass

func _enter_tree() -> void:
    instance = self

#API
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

func api_get_tile_pos(pos:Vector2i) -> int:
    check_chunk(pos)
    pos = pos_modulo_chunk(pos)
    return current_chunk.api_get_tile_pos(pos)

func api_set_tile_pos(tile_pos:Vector2i, val:int):
    var c_pos = get_chunk_pos(tile_pos)
    check_chunk(c_pos)
    tile_pos = pos_modulo_chunk(tile_pos)
    current_chunk.api_set_tile_pos(tile_pos, val)

func snap_global_to_grid(pos: Vector2) -> Vector2i:
    pos = floor(pos / chunks[0].tile_set.tile_size.x)
    return pos as Vector2i

func get_chunk_pos(pos: Vector2i) -> Vector2i:
    return floor(pos as Vector2 / chunks[0].map_width)

func pos_modulo_chunk(pos: Vector2i) -> Vector2i:
    var width = chunks[0].map_width
    return Vector2i(posmod(pos.x, width), posmod(pos.y, width))

#\API
