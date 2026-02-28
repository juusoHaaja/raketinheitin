class_name TileTool

var grid: Grid

func apply_global(pos:Vector2):
    apply(grid.global_to_grid(pos))

func apply(pos:Vector2i):
    grid.api_set_tile_pos(pos, 0)