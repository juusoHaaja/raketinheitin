extends Node2D
class_name WormHead

@export var move_speed: float = 1000.0
@export var turn_speed: float = 5.5  ## Radians per second toward target
@export var acceleration: float = 10.0  ## How quickly velocity catches up (higher = snappier)
@export var min_speed_ratio: float = 0.15  ## Keep crawling even when facing away

var target_node: Node2D

var dir: Vector2 = Vector2.RIGHT
var dir_angle: float = 0
var velocity := Vector2.ZERO

func _process(_delta: float) -> void:
	global_rotation = dir_angle

func _physics_process(delta: float) -> void:
	if not is_instance_valid(target_node):
		return
	var to_target := target_node.global_position - global_position
	var dist_sq := to_target.length_squared()
	if dist_sq < 1.0:
		velocity = velocity.lerp(Vector2.ZERO, acceleration * delta)
		global_position += velocity * delta
		return

	var target_angle := to_target.angle()
	var angle_diff := angle_difference(dir_angle, target_angle)
	var alignment: float = 1.0 - abs(angle_diff) / PI  ## 1 = facing target, 0 = opposite
	var motivation: float = lerp(min_speed_ratio, 1.0, alignment)
	var desired_speed: float = motivation * move_speed

	var angle_step := clampf(angle_difference(dir_angle, target_angle), -turn_speed * delta, turn_speed * delta)
	dir_angle += angle_step
	dir = Vector2.RIGHT.rotated(dir_angle)

	var desired_velocity: Vector2 = dir * desired_speed
	velocity = velocity.lerp(desired_velocity, acceleration * delta)
	global_position += velocity * delta
    