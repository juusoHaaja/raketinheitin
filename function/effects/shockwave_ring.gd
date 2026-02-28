# effects/shockwave_ring.gd
extends Node2D
class_name ShockwaveRing

func _draw():
    draw_arc(Vector2.ZERO, 10.0, 0, TAU, 32, Color(1, 0.8, 0.5, 1), 2.0, true)
    draw_arc(Vector2.ZERO, 8.0, 0, TAU, 32, Color(1, 0.6, 0.3, 0.5), 1.0, true)