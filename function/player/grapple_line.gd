extends Node2D
class_name GrappleLine

var anchor: Vector2 = Vector2.ZERO


@onready var line2d: Line2D = $Line2D
@onready var raycast: RayCast2D = $RayCast2D
@onready var player: Player = get_parent().get_parent()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    position = player.global_position

func _physics_process(delta: float) -> void:
    update()

func update():
    position = player.global_position
    raycast.target_position = to_local(anchor)

    raycast.force_raycast_update()

    if raycast.is_colliding():
        if raycast.get_collision_point().distance_squared_to(global_position) / get_length_squared() < 0.8 * 0.8:
            queue_free()

    line2d.set_point_position(1, to_local(anchor))

func update_anchor(global_pos: Vector2):
    anchor = global_pos

"""func _unhandled_input(event: InputEvent):
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_MIDDLE:
            update_anchor(get_global_mouse_position())"""

func get_angle_vector() -> Vector2:
    return (anchor - global_position).normalized()

func get_length() -> float:
    return (anchor - global_position).length()

func get_length_squared() -> float:
    return (anchor - global_position).length_squared()
