extends TileMapLayer
class_name Grid

@export var tileset_width = 4
@export var tileset_height = 4
var tileset_count = tileset_width*tileset_height

@export var map_width = 100
@export var map_height = 100

var cells = PackedByteArray()

func clear_cells():
    cells.clear()

func create_cells():
    clear_cells()
    for i in range(map_height):
        for l in range(map_width):
            cells.push_back(1)
    update_cells()

func pos_to_cell_index(pos: Vector2i) -> int:
    return pos.x+pos.y*map_width

func cell_index_to_pos(index: int) -> Vector2i:
    return Vector2i(index % map_width, index / map_width)

func api_get_tile_pos(pos:Vector2i) -> int:
    return api_get_tile(pos_to_cell_index(pos))

func api_set_tile_pos(pos:Vector2i, val:int):
    api_set_tile(pos_to_cell_index(pos), val)

func api_get_tile(index:int) -> int:
    return cells[index]

func api_set_tile(index:int, val:int):
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
    #i = i % tileset_count
    return Vector2i(i % tileset_width, i / tileset_width)

func set_tileset_tile(pos:Vector2i, b:int):
    if b == 0:
        set_cell(pos, -1, Vector2i(-1, -1), -1)
    else:
        var i = (b-1) % tileset_count
        set_cell(pos, 0, tilemap_index_to_source_coord(i), 0)

func update_cells():
    for i in range(cells.size()):
        var val = cells[i]
        var pos = cell_index_to_pos(i)
        set_tileset_tile(pos, val)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    create_cells()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass
