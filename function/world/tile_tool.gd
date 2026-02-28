# world/tile_tool.gd
class_name TileTool

static var chunk_parent: ChunkParent
var material_index:int = 0

func apply_global(pos: Vector2):
    apply(chunk_parent.snap_global_to_grid(pos))

func apply(pos: Vector2i):
    set_tile(pos, material_index)

func set_tile(pos: Vector2i, val):
    chunk_parent.api_set_tile_pos(pos, val)

func _init() -> void:
    chunk_parent = ChunkParent.instance
