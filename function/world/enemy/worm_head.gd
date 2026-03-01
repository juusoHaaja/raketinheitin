extends Node2D
class_name WormHead

@export var move_speed:float = 1000.0
@export var turn_speed:float = 1.0

var target_node:Node2D

var dir:Vector2 = Vector2.RIGHT
var dir_angle:float = 0

var velocity = Vector2.ZERO

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    global_rotation = dir_angle

func _physics_process(delta: float) -> void:
    var diff = target_node.global_position-global_position
    var target_dir = diff.angle()
    var angle_diff = angle_difference(dir_angle,target_dir)

    var alignment = abs(angle_diff) / PI
    var motivation = (2-alignment)/2
    var desired_speed = motivation*move_speed

    var desired_velocity = dir*desired_speed
    
    velocity = lerp(velocity,desired_velocity,0.5)

    global_position+= velocity*delta
    
    dir_angle = lerp_angle(dir_angle,target_dir,0.05)
    dir = Vector2.RIGHT.rotated(dir_angle)
    