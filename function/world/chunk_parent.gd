extends Node2D

@export var chunk_scene: PackedScene
var chunks = Array()

func generate_chunk(pos: Vector2i):
    if is_generated(pos):
        return
    force_generate(pos)

func is_generated(pos: Vector2i)-> bool:
    for c:Grid in chunks:
        if c.chunk_pos == pos:
            return true
    return false

func force_generate(pos:Vector2i):
    var c = chunk_scene.instantiate() as Grid
    chunks.push_back(c)
    add_child(c);
    c.gen_init(pos)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    generate_chunk(Vector2i(0,0))
    generate_chunk(Vector2i(1,1))
    generate_chunk(Vector2i(-1,0))


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass
