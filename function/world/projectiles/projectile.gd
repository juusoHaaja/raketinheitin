# projectiles/projectile.gd
extends Area2D
class_name Projectile

@export var speed: float = 1000.0
@export var explosion_radius: float = 4.0
@export var lifetime: float = 5.0

var velocity: Vector2 = Vector2.ZERO
var circle_tool: CircleTool
var time_alive: float = 0.0

func initialize(start_pos: Vector2, direction: Vector2, p_circle_tool: TileTool):
    global_position = start_pos
    velocity = direction.normalized() * speed
    circle_tool = p_circle_tool
    connect("body_entered", body_enter)
    rotation = direction.angle()

func _physics_process(delta: float):
    position += velocity * delta
    
    time_alive += delta
    if time_alive >= lifetime:
        queue_free()
        return "disable_mode"

func explode():
    circle_tool.radius = explosion_radius
    circle_tool.apply_global(global_position)
    queue_free()

func body_enter(_body: Node2D):
    explode()
