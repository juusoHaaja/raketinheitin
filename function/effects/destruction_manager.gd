# effects/destruction_manager.gd
extends Node
class_name DestructionManager

static var instance: DestructionManager

# Debris settings
const MAX_ACTIVE_DEBRIS := 300
const MAX_ACTIVE_DEBRIS_WEB := 120
const BASE_DEBRIS_PER_TILE := 2
const BASE_MAX_DEBRIS := 40
const BASE_MAX_DEBRIS_WEB := 20
const BASE_EXPLOSION_RADIUS := 4.0  # Reference radius for scaling

# Active debris tracking
var _active_debris: Array[Node2D] = []

# Tile color cache
var _tile_color_cache: Dictionary = {}  # material_id -> Color

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
    # Defer the entire explosion creation to avoid physics query flushing issues
    call_deferred("_create_explosion_deferred", global_pos, destroyed_tiles, explosion_radius)

func _create_explosion_deferred(global_pos: Vector2, destroyed_tiles: Array[Dictionary], explosion_radius: float) -> void:
    var tile_count := destroyed_tiles.size()
    var intensity := clampf(tile_count / 20.0, 0.3, 1.5)
    
    shake_camera(0.15 + intensity * 0.1, 3.0 + intensity * 4.0)
    _spawn_flash(global_pos, explosion_radius)
    _spawn_shockwave(global_pos, explosion_radius)
    #_spawn_fire_burst(global_pos, explosion_radius)
    _spawn_debris(global_pos, destroyed_tiles, explosion_radius)
    _spawn_dust_cloud(global_pos, explosion_radius, tile_count)
    #_spawn_sparks(global_pos, explosion_radius, tile_count)

func shake_camera(duration: float, intensity: float) -> void:
    if duration > _shake_duration - _shake_timer:
        _shake_duration = duration
        _shake_timer = 0.0
    _shake_intensity = maxf(_shake_intensity, intensity)

## Spawns a burst of organic-colored particles (e.g. worm segment death).
func spawn_organic_burst(global_pos: Vector2) -> void:
    var particle_count := randi_range(5, 9)
    var radius := 25.0

    var organic_colors: Array[Color] = [
        Color(0.35, 0.55, 0.3, 0.6),
        Color(0.45, 0.5, 0.35, 0.6),
        Color(0.5, 0.4, 0.3, 0.6),
        Color(0.25, 0.45, 0.2, 0.6),
    ]

    for i in particle_count:
        var dust := DustParticle.new()
        var offset := Vector2.from_angle(randf() * TAU) * randf() * radius
        dust.global_position = global_pos + offset
        var angle := offset.angle() if offset.length() > 0 else randf() * TAU
        dust.velocity = Vector2.from_angle(angle) * randf_range(15, 45) + Vector2(0, randf_range(-25, -10))
        dust.size = snappedf(randf_range(2, 5), 1.0)
        dust.lifetime = randf_range(0.35, 0.6)
        dust.color = organic_colors.pick_random()
        add_child(dust)

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

func _spawn_flash(pos: Vector2, radius: float) -> void:
    var flash := ExplosionFlash.new()
    flash.global_position = pos
    flash.max_radius = radius * 1.5
    add_child(flash)
    
    var tween := create_tween()
    tween.tween_method(func(p: float):
        flash.progress = p
        flash.queue_redraw()
    , 0.0, 1.0, 0.15)
    tween.tween_callback(flash.queue_free)
    
# ============================================
# SHOCKWAVE RING
# ============================================

func _spawn_shockwave(pos: Vector2, radius: float) -> void:
    var ring := PixelShockwave.new()
    ring.global_position = pos
    ring.radius = 4.0
    ring.thickness = 3.0
    ring.color = Color(1.0, 0.9, 0.6, 1.0)  # Bright yellow
    add_child(ring)
    
    var target_radius := radius * 1.4
    
    var tween := create_tween()
    tween.set_parallel(true)
    tween.tween_property(ring, "radius", target_radius, 0.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
    tween.tween_property(ring, "thickness", 1.0, 0.2)
    tween.tween_property(ring, "modulate:a", 0.0, 0.25).set_ease(Tween.EASE_IN)
    tween.set_parallel(false)
    tween.tween_callback(ring.queue_free)

# ============================================
# FIRE BURST
# ============================================

func _spawn_fire_burst(pos: Vector2, radius: float) -> void:
    var burst_count := clampi(int(radius / 4), 6, 16)
    
    for i in burst_count:
        var fire := FireBurst.new()
        var angle := (float(i) / burst_count) * TAU + randf_range(-0.2, 0.2)
        var distance := randf_range(radius * 0.3, radius * 0.8)
        
        fire.global_position = pos + Vector2.from_angle(angle) * distance
        fire.velocity = Vector2.from_angle(angle) * randf_range(40, 80)
        fire.size = snappedf(randf_range(3, 6), 1.0)
        fire.lifetime = randf_range(0.3, 0.6)
        
        add_child(fire)

# ============================================
# SPARKS
# ============================================

func _spawn_sparks(pos: Vector2, radius: float, tile_count: int) -> void:
    var spark_count := clampi(tile_count / 2, 8, 24)
    
    for i in spark_count:
        var spark := Spark.new()
        
        var offset := Vector2.from_angle(randf() * TAU) * randf() * radius * 0.3
        spark.global_position = pos + offset
        
        var angle := randf() * TAU
        spark.velocity = Vector2.from_angle(angle) * randf_range(120, 250)
        spark.size = snappedf(randf_range(1, 3), 1.0)
        spark.lifetime = randf_range(0.2, 0.5)
        spark.color = [
            Color(1.0, 1.0, 0.6),    # Bright yellow
            Color(1.0, 0.7, 0.3),    # Orange
            Color(1.0, 0.4, 0.2),    # Red-orange
        ].pick_random()
        
        add_child(spark)
    
# ============================================
# DEBRIS PARTICLES
# ============================================

func _spawn_debris(pos: Vector2, destroyed_tiles: Array[Dictionary], radius: float) -> void:
    if destroyed_tiles.is_empty():
        return
    
    # Scale debris count with explosion radius
    var tile_size := _get_tile_size()
    var radius_scale := radius / (BASE_EXPLOSION_RADIUS * tile_size)
    var scaled_debris_per_tile := ceili(BASE_DEBRIS_PER_TILE * radius_scale)
    var base_max := BASE_MAX_DEBRIS_WEB if GameState.is_web() else BASE_MAX_DEBRIS
    var scaled_max_debris := ceili(base_max * radius_scale)
    
    var debris_count := mini(destroyed_tiles.size() * scaled_debris_per_tile, scaled_max_debris)
    
    # Clean invalid references first
    var valid_debris: Array[Node2D] = []
    for d in _active_debris:
        if is_instance_valid(d):
            valid_debris.append(d)
    _active_debris = valid_debris
    
    var max_debris := MAX_ACTIVE_DEBRIS_WEB if GameState.is_web() else MAX_ACTIVE_DEBRIS
    while _active_debris.size() + debris_count > max_debris and _active_debris.size() > 0:
        var old: Node2D = _active_debris.pop_front()
        if is_instance_valid(old):
            old.queue_free()
    
    for i in debris_count:
        var tile_data: Dictionary = destroyed_tiles[i % destroyed_tiles.size()]
        var debris := DebrisParticle.new()
        
        var offset := Vector2(randf_range(-4, 4), randf_range(-4, 4))
        debris.global_position = pos + offset
        
        # Get actual tile color from tileset
        debris.color = _get_tile_color(tile_data.get("material", 1))
        
        # Scale debris size with explosion radius
        var size_scale := clampf(radius_scale, 0.5, 2.0)
        debris.size = snappedf(randf_range(2.0, 4.0) * size_scale, 1.0)
        debris.lifetime = randf_range(0.6, 1.2)
        debris.rotation_speed = randf_range(-10, 10)
        debris.on_fire = randf() < 0.3  # 30% chance of flaming debris
        
        add_child(debris)
        
        var angle := randf() * TAU
        var force := randf_range(80, 200) * (radius / 32.0)
        var direction := Vector2.from_angle(angle) + Vector2(0, -0.6)
        debris.apply_explosion_force(direction.normalized(), force)
        
        _active_debris.append(debris)

func _get_tile_size() -> float:
    if ChunkParent.instance != null:
        var ts: float = ChunkParent.instance.get_tile_size()
        if ts > 0.0:
            return ts
    return 16.0  # Fallback

func _get_tile_color(material_id: int) -> Color:
    if material_id == 0:
        return Color(0.5, 0.5, 0.5)  # Fallback for empty
    
    # Check cache first
    if _tile_color_cache.has(material_id):
        var base_color: Color = _tile_color_cache[material_id]
        return _add_color_variation(base_color)
    
    # Try to get color from tileset texture
    var chunk: Chunk = null
    if ChunkParent.instance != null:
        chunk = ChunkParent.instance.get_chunk(Vector2i.ZERO)
    
    if chunk == null or chunk.tile_set == null:
        return _get_fallback_material_color(material_id)
    
    var source := chunk.tile_set.get_source(0) as TileSetAtlasSource
    if source == null or source.texture == null:
        return _get_fallback_material_color(material_id)
    
    var texture := source.texture
    var image := texture.get_image()
    if image == null:
        return _get_fallback_material_color(material_id)
    
    # Calculate tile atlas position from material_id
    var tileset_width: int = chunk.tileset_width
    var tileset_count: int = chunk.tileset_count
    var tile_index: int = (material_id - 1) % tileset_count
    var atlas_coords := Vector2i(tile_index % tileset_width, tile_index / tileset_width)
    
    var tile_size := chunk.tile_set.tile_size
    var tile_region := Rect2i(atlas_coords * tile_size, tile_size)
    
    # Sample multiple pixels and average them for a representative color
    var color := _sample_tile_average_color(image, tile_region)
    
    # Cache the result
    _tile_color_cache[material_id] = color
    
    return _add_color_variation(color)

func _sample_tile_average_color(image: Image, region: Rect2i) -> Color:
    var total_r := 0.0
    var total_g := 0.0
    var total_b := 0.0
    var sample_count := 0
    
    # Sample a grid of points within the tile
    var sample_step := maxi(region.size.x / 4, 1)
    
    for y in range(region.position.y, region.position.y + region.size.y, sample_step):
        for x in range(region.position.x, region.position.x + region.size.x, sample_step):
            if x < image.get_width() and y < image.get_height():
                var pixel := image.get_pixel(x, y)
                # Skip transparent pixels
                if pixel.a > 0.1:
                    total_r += pixel.r
                    total_g += pixel.g
                    total_b += pixel.b
                    sample_count += 1
    
    if sample_count == 0:
        return Color(0.5, 0.5, 0.5)
    
    return Color(
        total_r / sample_count,
        total_g / sample_count,
        total_b / sample_count
    )

func _add_color_variation(color: Color) -> Color:
    var variation := randf_range(-0.1, 0.1)
    return Color(
        clampf(color.r + variation, 0.0, 1.0),
        clampf(color.g + variation, 0.0, 1.0),
        clampf(color.b + variation, 0.0, 1.0)
    )

# Keep fallback for edge cases
func _get_fallback_material_color(material_id: int) -> Color:
    match material_id:
        1: return Color(0.5, 0.4, 0.35)    # Dirt
        2: return Color(0.65, 0.45, 0.25)  # Stone
        3: return Color(0.7, 0.7, 0.65)    # Rock
        4: return Color(0.4, 0.35, 0.3)    # Coal
        5: return Color(0.8, 0.6, 0.35)    # Ore
        _: return Color(0.6, 0.5, 0.45)

# ============================================
# DUST CLOUD
# ============================================

func _spawn_dust_cloud(pos: Vector2, radius: float, tile_count: int) -> void:
    var particle_count := clampi(tile_count / 4, 3, 12)
    
    for i in particle_count:
        var dust := DustParticle.new()
        
        var offset := Vector2.from_angle(randf() * TAU) * randf() * radius * 0.4
        dust.global_position = pos + offset
        
        var angle := offset.angle() if offset.length() > 0 else randf() * TAU
        dust.velocity = Vector2.from_angle(angle) * randf_range(8, 25) + Vector2(0, randf_range(-20, -8))
        dust.size = snappedf(randf_range(3, 6), 1.0)  # Slightly larger
        dust.lifetime = randf_range(0.5, 0.9)
        
        # Warmer, more visible dust
        var brightness := randf_range(0.5, 0.65)
        dust.color = Color(brightness, brightness * 0.85, brightness * 0.7, 0.6)
        
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
