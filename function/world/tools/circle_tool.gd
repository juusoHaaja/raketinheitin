# world/tools/circle_tool.gd
class_name CircleTool
extends TileTool

var radius: float = 3.0

func apply(center: Vector2i):
    var radius_int = int(ceil(radius))
    
    for y in range(center.y - radius_int, center.y + radius_int + 1):
        for x in range(center.x - radius_int, center.x + radius_int + 1):
            var pos = Vector2i(x, y)
            
            var distance = Vector2(center).distance_to(Vector2(pos))
            if distance > radius:
                continue
            
            super.apply(pos)
