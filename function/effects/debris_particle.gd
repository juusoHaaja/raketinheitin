# effects/debris_particle.gd
extends RigidBody2D
class_name DebrisParticle

var color: Color = Color.WHITE
var size: float = 3.0
var lifetime: float = 1.0
var time: float = 0.0
var rotation_speed: float = 0.0

# Cache random shape offsets for irregular polygon
var _shape_offsets: PackedFloat32Array
var _collision_shape: CollisionShape2D

func _ready():
    # Physics settings
    gravity_scale = 1.0
    linear_damp = 0.5
    angular_damp = 0.5
    physics_material_override = _create_physics_material()
    
    # Collision setup
    collision_layer = 4  # Debris layer (layer 3, 0-indexed as bit 4)
    collision_mask = 1   # Collide with terrain (layer 1)
    
    # Create collision shape
    _collision_shape = CollisionShape2D.new()
    var circle := CircleShape2D.new()
    circle.radius = size * 0.5
    _collision_shape.shape = circle
    add_child(_collision_shape)
    
    # Pre-generate random shape for drawing
    _shape_offsets.resize(5)
    for i in 5:
        _shape_offsets[i] = randf_range(0.7, 1.0)
    
    # Apply initial angular velocity
    angular_velocity = rotation_speed

func _create_physics_material() -> PhysicsMaterial:
    var mat := PhysicsMaterial.new()
    mat.bounce = 0.3
    mat.friction = 0.8
    return mat

func _process(delta: float):
    time += delta
    
    if time >= lifetime:
        queue_free()
        return
    
    var progress := time / lifetime
    
    # Fade out
    modulate.a = 1.0 - progress
    
    # Slow down physics near end of life
    if progress > 0.7:
        linear_damp = 5.0
        angular_damp = 5.0
    
    queue_redraw()

func _draw():
    var points := PackedVector2Array()
    var s := size * (1.0 - time / lifetime * 0.3)
    
    for i in 5:
        var angle := i * TAU / 5
        var r := s * _shape_offsets[i]
        points.append(Vector2.from_angle(angle) * r)
    
    draw_colored_polygon(points, color)

# Call this instead of setting velocity directly
func apply_explosion_force(direction: Vector2, force: float) -> void:
    apply_central_impulse(direction * force)
