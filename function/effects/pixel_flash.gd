# effects/pixel_flash.gd
extends Node2D
class_name PixelFlash

func _ready():
    z_index = 100

func _draw():
    var radius: float = get_meta("radius", 32.0)
    var color: Color = get_meta("color", Color.WHITE)
    
    # Octagon shape (pixel-art friendly)
    var points := PackedVector2Array()
    for i in 8:
        var angle := i * TAU / 8 + PI / 8
        points.append(Vector2.from_angle(angle) * radius)
    
    draw_colored_polygon(points, color)
    
    # Inner highlight
    var inner_points := PackedVector2Array()
    for i in 8:
        var angle := i * TAU / 8 + PI / 8
        inner_points.append(Vector2.from_angle(angle) * radius * 0.5)
    
    draw_colored_polygon(inner_points, Color(1, 1, 1, 0.8))
