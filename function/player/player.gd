extends RigidBody2D
class_name Player


@onready var ground_raycast: RayCast2D = $GroundRaycast
@onready var line_holder = $Lines
@onready var collider = $CollisionShape2D

var local_collisions: PackedVector2Array


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass

func _physics_process(delta: float) -> void:
    var wish_dir = Input.get_vector("left", "right", "up", "down")

    if grounded():
        if linear_velocity.x * wish_dir.x < 500.0:
            apply_central_force(Vector2(wish_dir.x, 0) * 100000 * delta)

        if wish_dir.y < 0.0:
            apply_central_force(Vector2.UP * 10000)
    else:
        if linear_velocity.x * wish_dir.x < 500.0:
            apply_central_force(Vector2(wish_dir.x, 0) * 10000 * delta)

        
            

    var lines = line_holder.get_children()

    if wish_dir.length() > 0.1:
        for line: GrappleLine in lines:
            line.get_angle_vector()
        

func grounded() -> bool:
    if ground_raycast.is_colliding():
        return true
    if local_collisions.size() > 0:
        for point in local_collisions:
            if point.y > collider.shape.height / 2.0 - collider.shape.radius and abs(point.x) < collider.shape.radius / 2.0 - 0.01:
                return true  

    return false

func _integrate_forces(state: PhysicsDirectBodyState2D):
    local_collisions.clear()
    for i in state.get_contact_count():
        local_collisions.push_back(to_local(state.get_contact_local_position(i)))
