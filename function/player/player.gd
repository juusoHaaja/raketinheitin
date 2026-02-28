extends RigidBody2D
class_name Player


@onready var ground_raycast: RayCast2D = $GroundRaycast
@onready var line_holder = $Lines


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass

func _physics_process(delta: float) -> void:
    var wish_dir = Input.get_vector("left", "right", "up", "down")

    if grounded():
        if abs(linear_velocity.x) < 500.0:
            apply_central_force(Vector2(wish_dir.x, 0) * 100000 * delta)

        if wish_dir.y < 0.0:
            apply_central_force(Vector2.UP * 10000)
        
            

    var lines = line_holder.get_children()

    if wish_dir.length() > 0.1:
        for line: GrappleLine in lines:
            line.get_angle_vector()
        

func grounded():
    return ground_raycast.is_colliding()
