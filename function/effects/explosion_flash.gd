# effects/explosion_flash.gd
extends Node2D
class_name ExplosionFlash

var max_radius: float = 32.0
var progress: float = 0.0
var center_color := Color(1.0, 0.95, 0.7, 1.0)
var edge_color := Color(1.0, 0.4, 0.1, 0.0)

func _ready():
    z_index = 15

func _draw():
    var current_radius := max_radius * progress
    var alpha := 1.0 - progress
    
    # Outer orange glow layers
    for i in range(4, 0, -1):
        var layer_size := current_radius * (float(i) / 4.0)
        var layer_color := edge_color.lerp(center_color, 1.0 - float(i) / 4.0)
        layer_color.a = alpha * (1.0 - float(i) / 5.0)
        draw_circle(Vector2.ZERO, layer_size, layer_color)
    
    # Bright white center
    draw_circle(Vector2.ZERO, current_radius * 0.3, Color(1, 1, 1, alpha))
