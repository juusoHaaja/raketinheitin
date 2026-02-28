# effects/pixel_shockwave.gd
extends Node2D
class_name PixelShockwave

var radius: float = 8.0
var thickness: float = 2.0
var color: Color = Color(1.0, 0.85, 0.5)

func _ready():
    z_index = 99

func _draw():
    # Draw pixelated ring using rectangles
    var segments := 8
    
    for i in segments:
        var angle := i * TAU / segments
        var next_angle := (i + 1) * TAU / segments
        
        var p1 := Vector2.from_angle(angle) * radius
        var p2 := Vector2.from_angle(next_angle) * radius
        var p3 := Vector2.from_angle(next_angle) * (radius - thickness)
        var p4 := Vector2.from_angle(angle) * (radius - thickness)
        
        var points := PackedVector2Array([p1, p2, p3, p4])
        draw_colored_polygon(points, color)
