# effects/debris_particle.gd (updated)
extends RigidBody2D
class_name DebrisParticle

var color: Color = Color.WHITE
var size: float = 3.0
var lifetime: float = 1.0
var time: float = 0.0
var rotation_speed: float = 0.0
var on_fire: bool = false

var _shape_offsets: PackedFloat32Array
var _collision_shape: CollisionShape2D
var _fire_time: float = 0.0

func _ready():
    gravity_scale = 1.0
    linear_damp = 0.5
    angular_damp = 0.5
    physics_material_override = _create_physics_material()
    
    collision_layer = 4
    collision_mask = 1
    
    _collision_shape = CollisionShape2D.new()
    var circle := CircleShape2D.new()
    circle.radius = size * 0.5
    _collision_shape.shape = circle
    add_child(_collision_shape)
    
    _shape_offsets.resize(5)
    for i in 5:
        _shape_offsets[i] = randf_range(0.7, 1.0)
    
    angular_velocity = rotation_speed

func _create_physics_material() -> PhysicsMaterial:
    var mat := PhysicsMaterial.new()
    mat.bounce = 0.3
    mat.friction = 0.8
    return mat

func _process(delta: float):
    time += delta
    _fire_time += delta
    
    if time >= lifetime:
        queue_free()
        return
    
    var progress := time / lifetime
    
    modulate.a = 1.0 - progress
    
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
    
    # Draw debris
    draw_colored_polygon(points, color)
    
    # Draw fire effect if on fire
    if on_fire and time < lifetime * 0.7:
        var fire_progress := time / (lifetime * 0.7)
        var fire_alpha := (1.0 - fire_progress) * 0.8
        
        # Flickering flame
        var flicker := sin(_fire_time * 20) * 0.4 + 1.0
        var fire_size := s * 1.5 * flicker
        
        # Yellow-orange fire glow
        draw_circle(Vector2(0, -s * 0.5), fire_size * 0.6, Color(1, 0.7, 0.2, fire_alpha * 0.6))
        draw_circle(Vector2(0, -s * 0.5), fire_size * 0.3, Color(1, 1, 0.6, fire_alpha))

func apply_explosion_force(direction: Vector2, force: float) -> void:
    apply_central_impulse(direction * force)
