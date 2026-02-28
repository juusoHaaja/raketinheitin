# world/tile_tool.gd
class_name TileTool

var grid: Grid
var selected_tile: int = 1

func apply_global(pos: Vector2):
    apply(grid.global_to_grid(pos))

func apply(pos: Vector2i):
    # Bounds check
    if pos.x < 0 or pos.x >= grid.map_width:
        return
    if pos.y < 0 or pos.y >= grid.map_height:
        return
    grid.api_set_tile_pos(pos, selected_tile)
