# projectiles/projectile.gd
extends Area2D
class_name Projectile

signal exploded

@export var speed: float = 700.0
@export var explosion_radius: float = 4.0
@export var lifetime: float = 5.0

var velocity: Vector2 = Vector2.ZERO
var circle_tool: CircleTool
var time_alive: float = 0.0

func initialize(start_pos: Vector2, direction: Vector2, p_circle_tool: TileTool):
    global_position = start_pos
    velocity = direction.normalized() * speed
    circle_tool = p_circle_tool
    body_entered.connect(_on_body_entered)
    rotation = direction.angle()

func _physics_process(delta: float):
    position += velocity * delta
    
    time_alive += delta
    if time_alive >= lifetime:
        queue_free()

func explode():
    emit_signal("exploded")
    circle_tool.radius = explosion_radius
    # Single pass: apply destruction and get destroyed tiles (no duplicate iteration or double create_explosion)
    var destroyed: Array[Dictionary] = circle_tool.apply_global_return_destroyed(global_position)
    if DestructionManager.instance != null:
        var tile_size: float = ChunkParent.instance.get_tile_size()
        DestructionManager.instance.create_explosion(
            global_position,
            destroyed,
            explosion_radius * tile_size
        )
    queue_free()

func _on_body_entered(_body: Node2D) -> void:
    # Defer to next frame so collision callback returns immediately and cost is spread
    call_deferred("explode")
