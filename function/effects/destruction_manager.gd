# effects/destruction_manager.gd
extends Node
class_name DestructionManager

static var instance: DestructionManager

# Debris settings
const MAX_ACTIVE_DEBRIS := 300
const DEBRIS_PER_TILE := 2
const MAX_DEBRIS_PER_EXPLOSION := 40

# Active debris tracking
var _active_debris: Array[Node2D] = []

# Screen shake
var _camera: Camera2D
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0
var _shake_timer: float = 0.0
var _original_offset: Vector2

func _enter_tree() -> void:
    instance = self

func _ready() -> void:
    await get_tree().process_frame
    _find_camera()

func _find_camera() -> void:
    _camera = get_viewport().get_camera_2d()
    if _camera:
        _original_offset = _camera.offset

func _process(delta: float) -> void:
    _update_shake(delta)
    _cleanup_debris()

# ============================================
# PUBLIC API
# ============================================

func create_explosion(global_pos: Vector2, destroyed_tiles: Array[Dictionary], explosion_radius: float) -> void:
    var tile_count := destroyed_tiles.size()
    var intensity := clampf(tile_count / 20.0, 0.3, 1.5)
    
    shake_camera(0.15 + intensity * 0.1, 3.0 + intensity * 4.0)
    _spawn_explosion_flash(global_pos, explosion_radius)
    _spawn_shockwave(global_pos, explosion_radius)
    _spawn_debris(global_pos, destroyed_tiles, explosion_radius)
    _spawn_dust_cloud(global_pos, explosion_radius, tile_count)

func shake_camera(duration: float, intensity: float) -> void:
    if duration > _shake_duration - _shake_timer:
        _shake_duration = duration
        _shake_timer = 0.0
    _shake_intensity = maxf(_shake_intensity, intensity)

# ============================================
# SCREEN SHAKE
# ============================================

func _update_shake(delta: float) -> void:
    if _camera == null or _shake_duration <= 0:
        return
    
    _shake_timer += delta
    
    if _shake_timer >= _shake_duration:
        _camera.offset = _original_offset
        _shake_intensity = 0.0
        _shake_duration = 0.0
        return
    
    var progress := _shake_timer / _shake_duration
    var current_intensity := _shake_intensity * (1.0 - progress)
    
    var offset := Vector2(
        randf_range(-1, 1) * current_intensity,
        randf_range(-1, 1) * current_intensity
    )
    _camera.offset = _original_offset + offset

# ============================================
# EXPLOSION FLASH
# ============================================

func _spawn_explosion_flash(pos: Vector2, radius: float) -> void:
    # Spawn square chunks that fly out and fade
    var chunk_count := 8
    
    for i in chunk_count:
        var chunk := ColorRect.new()
        chunk.size = Vector2(radius * 0.3, radius * 0.3)
        chunk.position = pos - chunk.size / 2
        chunk.color = Color(1, 0.95, 0.8)
        chunk.pivot_offset = chunk.size / 2
        add_child(chunk)
        
        var angle := i * TAU / chunk_count
        var target_pos := pos + Vector2.from_angle(angle) * radius * 0.8
        
        var tween := create_tween()
        tween.set_parallel(true)
        tween.tween_property(chunk, "position", target_pos - chunk.size / 2, 0.15).set_ease(Tween.EASE_OUT)
        tween.tween_property(chunk, "modulate:a", 0.0, 0.2)
        tween.tween_property(chunk, "rotation", randf_range(-1, 1), 0.2)
        tween.set_parallel(false)
        tween.tween_callback(chunk.queue_free)
    
func _create_gradient_texture(size: int, center_color: Color, edge_color: Color) -> GradientTexture2D:
    var tex := GradientTexture2D.new()
    tex.width = size
    tex.height = size
    tex.fill = GradientTexture2D.FILL_RADIAL
    tex.fill_from = Vector2(0.5, 0.5)
    tex.fill_to = Vector2(1.0, 0.5)
    
    var gradient := Gradient.new()
    gradient.set_color(0, center_color)
    gradient.set_color(1, edge_color)
    tex.gradient = gradient
    
    return tex

# ============================================
# SHOCKWAVE RING
# ============================================

func _spawn_shockwave(pos: Vector2, radius: float) -> void:
    var ring := PixelShockwave.new()
    ring.global_position = pos
    ring.radius = 4.0
    ring.thickness = 2.0
    ring.color = Color(1.0, 0.85, 0.5, 0.9)
    add_child(ring)
    
    var target_radius := radius * 1.2
    
    var tween := create_tween()
    tween.set_parallel(true)
    tween.tween_property(ring, "radius", target_radius, 0.12).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
    tween.tween_property(ring, "thickness", 1.0, 0.12)
    tween.tween_property(ring, "modulate:a", 0.0, 0.15).set_ease(Tween.EASE_IN)
    tween.set_parallel(false)
    tween.tween_callback(ring.queue_free)
    
# ============================================
# DEBRIS PARTICLES
# ============================================

func _spawn_debris(pos: Vector2, destroyed_tiles: Array[Dictionary], radius: float) -> void:
    if destroyed_tiles.is_empty():
        return
    
    var debris_count := mini(destroyed_tiles.size() * DEBRIS_PER_TILE, MAX_DEBRIS_PER_EXPLOSION)
    
    # Clean invalid references first
    var valid_debris: Array[Node2D] = []
    for d in _active_debris:
        if is_instance_valid(d):
            valid_debris.append(d)
    _active_debris = valid_debris
    
    # Trim excess if needed
    while _active_debris.size() + debris_count > MAX_ACTIVE_DEBRIS and _active_debris.size() > 0:
        var old: Node2D = _active_debris.pop_front()
        if is_instance_valid(old):
            old.queue_free()
    
    # Spawn new debris
    for i in debris_count:
        var tile_data: Dictionary = destroyed_tiles[i % destroyed_tiles.size()]
        var debris := DebrisParticle.new()
        
        # Random offset from center
        var offset := Vector2(randf_range(-8, 8), randf_range(-8, 8))
        debris.global_position = pos + offset
        
        # Random properties
        debris.color = _get_material_color(tile_data.get("material", 1))
        debris.size = randf_range(2.0, 5.0)
        debris.lifetime = randf_range(0.8, 1.5)
        debris.rotation_speed = randf_range(-15, 15)
        
        # Must add to tree before applying physics
        add_child(debris)
        
        # Apply outward explosion force
        var angle := randf() * TAU
        var force := randf_range(150, 400) * (radius / 64.0)
        var direction := Vector2.from_angle(angle) + Vector2(0, -0.5)  # Bias upward
        debris.apply_explosion_force(direction.normalized(), force)
        
        _active_debris.append(debris)
        
func _get_material_color(material_id: int) -> Color:
    match material_id:
        1: return Color(0.4, 0.35, 0.3)
        2: return Color(0.55, 0.35, 0.2)
        3: return Color(0.6, 0.6, 0.55)
        4: return Color(0.3, 0.25, 0.2)
        5: return Color(0.7, 0.5, 0.3)
        _: return Color(0.5, 0.45, 0.4)

# ============================================
# DUST CLOUD
# ============================================

func _spawn_dust_cloud(pos: Vector2, radius: float, tile_count: int) -> void:
    var particle_count := clampi(tile_count / 3, 5, 20)
    
    for i in particle_count:
        var dust := DustParticle.new()
        
        var offset := Vector2.from_angle(randf() * TAU) * randf() * radius * 0.5
        dust.global_position = pos + offset
        
        var angle := offset.angle() if offset.length() > 0 else randf() * TAU
        dust.velocity = Vector2.from_angle(angle) * randf_range(10, 40) + Vector2(0, randf_range(-30, -10))
        dust.size = randf_range(8, 20)
        dust.lifetime = randf_range(0.6, 1.2)
        
        var brightness := randf_range(0.4, 0.6)
        dust.color = Color(brightness, brightness * 0.9, brightness * 0.8, 0.4)
        
        add_child(dust)

# ============================================
# CLEANUP
# ============================================

func _cleanup_debris() -> void:
    var valid_debris: Array[Node2D] = []
    for d in _active_debris:
        if is_instance_valid(d):
            valid_debris.append(d)
    _active_debris = valid_debris
