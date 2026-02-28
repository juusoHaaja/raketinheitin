# effects/fire_burst.gd
extends Node2D
class_name FireBurst

var velocity: Vector2 = Vector2.ZERO
var size: float = 4.0
var lifetime: float = 0.4
var time: float = 0.0

func _ready():
    z_index = 12

func _process(delta: float):
    time += delta
    if time >= lifetime:
        queue_free()
        return
    
    var progress := time / lifetime
    
    # Rise up and slow down
    velocity += Vector2(0, -80) * delta
    velocity *= 0.92
    position += velocity * delta
    
    queue_redraw()

func _draw():
    var progress := time / lifetime
    var current_size := size * (1.0 - progress * 0.5)
    
    # Animate through fire colors: yellow -> orange -> red
    var color_yellow := Color(1.0, 1.0, 0.6)
    var color_orange := Color(1.0, 0.7, 0.2)
    var color_red := Color(0.9, 0.3, 0.1)
    
    var color: Color
    if progress < 0.5:
        color = color_yellow.lerp(color_orange, progress * 2.0)
    else:
        color = color_orange.lerp(color_red, (progress - 0.5) * 2.0)
    
    color.a = 1.0 - progress
    
    # Draw flickering flame shape
    var flicker := sin(time * 30) * 0.3 + 1.0
    draw_circle(Vector2(0, -current_size * 0.3), current_size * 0.6 * flicker, color)
    draw_circle(Vector2.ZERO, current_size, color * Color(1, 1, 1, 0.7))
