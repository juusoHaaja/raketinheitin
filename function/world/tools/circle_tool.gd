# world/tools/circle_tool.gd
class_name CircleTool
extends TileTool

var radius: float = 3.0
var radius_squared: float = radius*radius

func apply(center: Vector2i):
    var radius_int = int(ceil(radius))
    
    for y in range(center.y - radius_int, center.y + radius_int + 1):
        for x in range(center.x - radius_int, center.x + radius_int + 1):
            var pos = Vector2i(x, y)
            
            var distance = Vector2(center).distance_squared_to(Vector2(pos))
            if distance > radius_squared:
                continue
            
            set_tile(pos, material_index)

func set_radius(r:float):
    radius = r
    radius_squared = r*r

func _init(r: float) -> void:
    set_radius(r)
    super._init()
