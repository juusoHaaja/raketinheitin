# world/lighting/fog_of_war.gd
extends Node2D

const FogTextureSystemScript = preload("res://function/world/lighting/fog_texture_system.gd")
const GPUFogSystemScript = preload("res://scripts/gpu_fog_system.gd")

const VIEW_CHUNK_RADIUS := 16
const _UPDATE_INTERVAL := 0.06

# Projectile light settings
const PROJECTILE_LIGHT_RADIUS := 12.0
const PROJECTILE_LIGHT_INTENSITY := 0.85
# Explosion flash settings
const EXPLOSION_LIGHT_RADIUS := 12.0
const EXPLOSION_LIGHT_INTENSITY := 1.0
const EXPLOSION_LIGHT_DECAY := 3.0  # seconds to fade

## Debug: set to false to disable fog of war (e.g. in editor or for debugging)
var fog_enabled: bool = true
## Use GPU compute shader for fog when available (falls back to CPU automatically)
@export var use_gpu_fog: bool = true

var _player: Node2D = null
var _chunk_parent: ChunkParent = null
var _fog_system: RefCounted  # CPU fallback: FogTextureSystem
var _gpu_fog_system: RefCounted  # GPUFogSystem when use_gpu_fog
var _gpu_available: bool = false
var _update_timer: float = 0.0

# Track active projectiles for lighting
var _tracked_projectiles: Array[Node2D] = []

# Explosion flashes: { "position": Vector2, "radius": float, "intensity": float, "time_left": float }
var _explosion_flashes: Array[Dictionary] = []

# Cursor-as-flashlight (e.g. in menu): world position; use invalid to disable
const _CURSOR_LIGHT_INVALID := Vector2(1e30, 1e30)
var _cursor_light_pos: Vector2 = _CURSOR_LIGHT_INVALID
const CURSOR_LIGHT_RADIUS_TILES: float = 24.0
const CURSOR_LIGHT_INTENSITY: float = 0.9

# Cache: avoid re-assigning textures when nothing changed
var _textures_dirty: bool = true

func _ready() -> void:
    _fog_system = FogTextureSystemScript.new()

    if use_gpu_fog:
        _gpu_fog_system = GPUFogSystemScript.new()
        if _gpu_fog_system.initialize():
            _gpu_available = true
            print("[FogOfWar] GPU fog system enabled")
        else:
            _gpu_available = false
            _gpu_fog_system.cleanup()
            _gpu_fog_system = null
            print("[FogOfWar] GPU fog not available, using CPU")

    var parent = get_parent()
    if parent is Main:
        _player = parent.player
        _chunk_parent = parent.get_node_or_null("ChunkParent") as ChunkParent
    else:
        _chunk_parent = parent.get_node_or_null("ChunkParent") as ChunkParent
        var players: Array[Node] = get_tree().get_nodes_in_group("player")
        if players.size() > 0:
            _player = players[0] as Node2D

func _exit_tree() -> void:
    if _gpu_fog_system:
        _gpu_fog_system.cleanup()
        _gpu_fog_system = null

func _process(delta: float) -> void:
    if _player == null or _chunk_parent == null:
        var parent = get_parent()
        if parent is Main:
            _player = parent.player
            _chunk_parent = parent.get_node_or_null("ChunkParent") as ChunkParent
        else:
            _chunk_parent = parent.get_node_or_null("ChunkParent") as ChunkParent
            var players: Array[Node] = get_tree().get_nodes_in_group("player")
            if players.size() > 0:
                _player = players[0] as Node2D
        return

    # Decay explosion flashes
    var i := _explosion_flashes.size() - 1
    while i >= 0:
        var flash := _explosion_flashes[i]
        flash["time_left"] -= delta
        flash["intensity"] *= (1.0 - delta * EXPLOSION_LIGHT_DECAY)
        if flash["time_left"] <= 0.0 or flash["intensity"] < 0.01:
            _explosion_flashes.remove_at(i)
            _textures_dirty = true
        i -= 1

    # Clean up dead projectile references
    var old_count := _tracked_projectiles.size()
    _tracked_projectiles = _tracked_projectiles.filter(func(p): return is_instance_valid(p))
    if _tracked_projectiles.size() != old_count:
        _textures_dirty = true

    _update_timer -= delta
    if _update_timer > 0.0:
        if _textures_dirty:
            _assign_textures_to_overlays()
        return

    if not fog_enabled:
        if _textures_dirty:
            _assign_textures_to_overlays()
        return

    _update_timer = _UPDATE_INTERVAL
    _textures_dirty = true

    if _gpu_available:
        _update_fog_gpu()
    else:
        _update_fog_cpu()

    _assign_textures_to_overlays()

func _update_fog_gpu() -> void:
    var w: int = _chunk_parent._chunk_width if _chunk_parent._chunk_width > 0 else 16
    var light_radius_tiles: float = float(FogTextureSystemScript.LIGHT_RADIUS_TILES)

    # Build lights array (player + cursor + projectiles + explosions)
    var lights: Array[Dictionary] = []
    if is_instance_valid(_player):
        var player_tile: Vector2i = _chunk_parent.snap_global_to_grid(_player.global_position)
        lights.append({
            "tile_pos": player_tile,
            "radius": light_radius_tiles,
            "intensity": 1.0
        })
    if _cursor_light_pos != _CURSOR_LIGHT_INVALID:
        var cursor_tile: Vector2i = _chunk_parent.snap_global_to_grid(_cursor_light_pos)
        lights.append({
            "tile_pos": cursor_tile,
            "radius": CURSOR_LIGHT_RADIUS_TILES,
            "intensity": CURSOR_LIGHT_INTENSITY
        })

    for proj in _tracked_projectiles:
        if is_instance_valid(proj):
            var proj_tile: Vector2i = _chunk_parent.snap_global_to_grid(proj.global_position)
            lights.append({
                "tile_pos": proj_tile,
                "radius": PROJECTILE_LIGHT_RADIUS,
                "intensity": PROJECTILE_LIGHT_INTENSITY
            })

    for flash in _explosion_flashes:
        var flash_tile: Vector2i = _chunk_parent.snap_global_to_grid(flash["position"])
        lights.append({
            "tile_pos": flash_tile,
            "radius": flash["radius"],
            "intensity": flash["intensity"]
        })

    if lights.is_empty():
        return

    # Compute bounding box of chunks needing update
    var min_cx: int = 0x7FFFFFFF
    var max_cx: int = -0x7FFFFFFF
    var min_cy: int = 0x7FFFFFFF
    var max_cy: int = -0x7FFFFFFF
    for light in lights:
        var lc: Vector2i = _chunk_parent.get_chunk_pos(light["tile_pos"])
        var lr: int = int(ceil(light["radius"] / float(w))) + 1
        min_cx = mini(min_cx, lc.x - lr)
        max_cx = maxi(max_cx, lc.x + lr)
        min_cy = mini(min_cy, lc.y - lr)
        max_cy = maxi(max_cy, lc.y + lr)

    var chunks_to_update: Array[Vector2i] = []
    for cx in range(min_cx, max_cx + 1):
        for cy in range(min_cy, max_cy + 1):
            var cpos := Vector2i(cx, cy)
            var ch: Chunk = _chunk_parent.get_chunk_if_exists(cpos)
            if ch and ch.generation_complete:
                chunks_to_update.append(cpos)

    if not chunks_to_update.is_empty():
        _gpu_fog_system.update_fog_batch(chunks_to_update, lights)

func _update_fog_cpu() -> void:
    _fog_system.clear_extra_lights()

    if _cursor_light_pos != _CURSOR_LIGHT_INVALID:
        var cursor_tile: Vector2i = _chunk_parent.snap_global_to_grid(_cursor_light_pos)
        _fog_system.add_extra_light(cursor_tile, CURSOR_LIGHT_RADIUS_TILES, CURSOR_LIGHT_INTENSITY)

    for proj in _tracked_projectiles:
        if is_instance_valid(proj):
            var proj_tile: Vector2i = _chunk_parent.snap_global_to_grid(proj.global_position)
            _fog_system.add_extra_light(proj_tile, PROJECTILE_LIGHT_RADIUS, PROJECTILE_LIGHT_INTENSITY)

    for flash in _explosion_flashes:
        var flash_tile: Vector2i = _chunk_parent.snap_global_to_grid(flash["position"])
        _fog_system.add_extra_light(flash_tile, flash["radius"], flash["intensity"])

    var center_tile: Vector2i
    if is_instance_valid(_player):
        center_tile = _chunk_parent.snap_global_to_grid(_player.global_position)
    elif _cursor_light_pos != _CURSOR_LIGHT_INVALID:
        center_tile = _chunk_parent.snap_global_to_grid(_cursor_light_pos)
    else:
        center_tile = Vector2i.ZERO
    var center_chunk: Vector2i = _chunk_parent.get_chunk_pos(center_tile)
    var w: int = _chunk_parent._chunk_width if _chunk_parent._chunk_width > 0 else 16

    var light_chunks: int = int(ceil(FogTextureSystemScript.LIGHT_RADIUS_TILES / float(w))) + 1
    var min_cx: int = center_chunk.x - light_chunks
    var max_cx: int = center_chunk.x + light_chunks
    var min_cy: int = center_chunk.y - light_chunks
    var max_cy: int = center_chunk.y + light_chunks

    for light in _fog_system.get_extra_lights():
        var lc: Vector2i = _chunk_parent.get_chunk_pos(light["tile_pos"])
        var lr := int(ceil(light["radius"] / float(w))) + 1
        min_cx = mini(min_cx, lc.x - lr)
        max_cx = maxi(max_cx, lc.x + lr)
        min_cy = mini(min_cy, lc.y - lr)
        max_cy = maxi(max_cy, lc.y + lr)

    for cx in range(min_cx, max_cx + 1):
        for cy in range(min_cy, max_cy + 1):
            var cpos := Vector2i(cx, cy)
            var ch: Chunk = _chunk_parent.get_chunk_if_exists(cpos)
            if not ch or not ch.generation_complete:
                continue
            var local_tx: int = center_tile.x - cx * w
            var local_ty: int = center_tile.y - cy * w
            _fog_system.update_fog(cpos, local_tx, local_ty, ch.map_width, ch.map_height)

    for cx in range(center_chunk.x - VIEW_CHUNK_RADIUS, center_chunk.x + VIEW_CHUNK_RADIUS + 1):
        for cy in range(center_chunk.y - VIEW_CHUNK_RADIUS, center_chunk.y + VIEW_CHUNK_RADIUS + 1):
            var cpos := Vector2i(cx, cy)
            var ch: Chunk = _chunk_parent.get_chunk_if_exists(cpos)
            if not ch:
                continue
            _fog_system.get_or_create_fog(cpos, ch.map_width, ch.map_height)

func _assign_textures_to_overlays() -> void:
    _textures_dirty = false
    if not _chunk_parent:
        return
    if not fog_enabled:
        _hide_all_fog_overlays()
        return
    if _gpu_available:
        _assign_gpu_textures()
    else:
        _assign_cpu_textures()

func _assign_gpu_textures() -> void:
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        _gpu_fog_system.get_or_create_chunk(ch.chunk_pos)
        ch.create_fog_overlay_if_needed()
        var tex: ImageTexture = _gpu_fog_system.get_texture(ch.chunk_pos)
        if tex:
            if ch.fog_overlay.texture != tex:
                ch.fog_overlay.texture = tex
            ch.fog_overlay.visible = true
        else:
            ch.fog_overlay.visible = false

func _assign_cpu_textures() -> void:
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        _fog_system.get_or_create_fog(ch.chunk_pos, ch.map_width, ch.map_height)
        ch.create_fog_overlay_if_needed()
        var tex: ImageTexture = _fog_system.get_texture(ch.chunk_pos) as ImageTexture
        if tex:
            if ch.fog_overlay.texture != tex:
                ch.fog_overlay.texture = tex
            ch.fog_overlay.visible = true
        else:
            ch.fog_overlay.visible = false

func _hide_all_fog_overlays() -> void:
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        ch.create_fog_overlay_if_needed()
        ch.fog_overlay.visible = false

## Call this to register a projectile for dynamic lighting
func track_projectile(projectile: Node2D) -> void:
    if not _tracked_projectiles.has(projectile):
        _tracked_projectiles.append(projectile)
        _textures_dirty = true

## Call this to unregister a projectile
func untrack_projectile(projectile: Node2D) -> void:
    _tracked_projectiles.erase(projectile)
    _textures_dirty = true

## Call this when an explosion happens to create a temporary flash
func add_explosion_flash(world_pos: Vector2, radius: float = -1.0, duration: float = 0.5) -> void:
    if radius < 0:
        radius = EXPLOSION_LIGHT_RADIUS
    _explosion_flashes.append({
        "position": world_pos,
        "radius": radius,
        "intensity": EXPLOSION_LIGHT_INTENSITY,
        "time_left": duration,
    })
    _textures_dirty = true

## Set cursor world position for flashlight effect (e.g. in menu). Call each frame when over the view.
func set_cursor_light_position(world_pos: Vector2) -> void:
    _cursor_light_pos = world_pos
    _textures_dirty = true

## Disable cursor flashlight (e.g. when cursor leaves the preview area).
func clear_cursor_light() -> void:
    _cursor_light_pos = _CURSOR_LIGHT_INVALID
    _textures_dirty = true
