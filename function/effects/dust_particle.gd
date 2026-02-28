# effects/dust_particle.gd
extends Node2D
class_name DustParticle

var velocity: Vector2 = Vector2.ZERO
var size: float = 10.0
var lifetime: float = 1.0
var time: float = 0.0
var color: Color = Color(0.5, 0.5, 0.5, 0.4)
var original_size: float = 10.0

func _ready():
    original_size = size
    z_index = 10

func _process(delta: float):
    time += delta
    if time >= lifetime:
        queue_free()
        return
    
    var progress := time / lifetime
    
    velocity *= 0.95
    position += velocity * delta
    
    size = original_size * (1.0 + progress * 1.5)
    modulate.a = color.a * (1.0 - progress * progress)
    
    queue_redraw()

func _draw():
    var alpha := modulate.a
    for i in range(3, 0, -1):
        var layer_size := size * (float(i) / 3.0)
        var layer_alpha := alpha * (1.0 - float(i) / 4.0)
        draw_circle(Vector2.ZERO, layer_size, Color(color.r, color.g, color.b, layer_alpha * 0.3))
