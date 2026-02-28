# effects/spark.gd
extends Node2D
class_name Spark

var velocity: Vector2 = Vector2.ZERO
var size: float = 2.0
var lifetime: float = 0.3
var time: float = 0.0
var color: Color = Color(1, 1, 0.6)
var trail_points: PackedVector2Array = []
const MAX_TRAIL_LENGTH := 5

func _ready():
    z_index = 13

func _process(delta: float):
    time += delta
    if time >= lifetime:
        queue_free()
        return
    
    # Add current position to trail
    trail_points.append(Vector2.ZERO)
    if trail_points.size() > MAX_TRAIL_LENGTH:
        trail_points.remove_at(0)
    
    # Gravity and slowdown
    velocity += Vector2(0, 300) * delta
    velocity *= 0.96
    
    # Update all trail points
    for i in trail_points.size():
        trail_points[i] -= velocity * delta
    
    position += velocity * delta
    
    queue_redraw()

func _draw():
    var progress := time / lifetime
    
    # Draw trail
    for i in trail_points.size():
        var trail_progress := float(i) / MAX_TRAIL_LENGTH
        var trail_alpha := (1.0 - progress) * (trail_progress * 0.5)
        var trail_size := size * trail_progress * 0.5
        var trail_color := color
        trail_color.a = trail_alpha
        draw_circle(trail_points[i], trail_size, trail_color)
    
    # Draw bright spark head
    var alpha := 1.0 - progress
    draw_circle(Vector2.ZERO, size, color * Color(1, 1, 1, alpha))
    # Bright core
    draw_circle(Vector2.ZERO, size * 0.5, Color(1, 1, 1, alpha))
