# projectiles/projectile.gd
extends Area2D
class_name Projectile

signal exploded
signal damage_dealt(amount: float)

@export var speed: float = 700.0
@export var explosion_radius: float = 4.0
@export var lifetime: float = 5.0
@export var damage: float = 25.0

var velocity: Vector2 = Vector2.ZERO
var circle_tool: CircleTool
var time_alive: float = 0.0
var _hit_body: Node2D = null
## Body to ignore when detecting hits (e.g. the player who shot). Prevents instant self-damage.
var ignore_body: Node2D = null

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
    if _hit_body != null:
        var health_node = _find_health_component(_hit_body)
        if health_node != null:
            health_node.take_damage(damage)
            damage_dealt.emit(damage)
        _hit_body = null

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

func _find_health_component(node: Node) -> HealthComponent:
    var n: Node = node
    while n != null:
        var h = n.get_node_or_null("Health")
        if h is HealthComponent:
            return h as HealthComponent
        n = n.get_parent()
    return null

func _on_body_entered(body: Node2D) -> void:
    if body == ignore_body:
        return
    _hit_body = body
    # Defer to next frame so collision callback returns immediately and cost is spread
    call_deferred("explode")
