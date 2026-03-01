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

    var main = get_parent()
    if main is Main:
        _player = main.player
        _chunk_parent = main.get_node_or_null("ChunkParent") as ChunkParent

func _exit_tree() -> void:
    if _gpu_fog_system:
        _gpu_fog_system.cleanup()
        _gpu_fog_system = null

func _process(delta: float) -> void:
    if _player == null or _chunk_parent == null:
        var main = get_parent()
        if main is Main:
            _player = main.player
            _chunk_parent = main.get_node_or_null("ChunkParent") as ChunkParent
        return

    # Decay explosion flashes
    var i := _explosion_flashes.size() - 1
    while i >= 0:
        _explosion_flashes[i]["time_left"] -= delta
        _explosion_flashes[i]["intensity"] *= (1.0 - delta * EXPLOSION_LIGHT_DECAY)
        if _explosion_flashes[i]["time_left"] <= 0.0 or _explosion_flashes[i]["intensity"] < 0.01:
            _explosion_flashes.remove_at(i)
        i -= 1

    # Clean up dead projectile references
    _tracked_projectiles = _tracked_projectiles.filter(func(p): return is_instance_valid(p))

    _update_timer -= delta
    if _update_timer > 0.0:
        _assign_textures_to_overlays()
        return

    if not fog_enabled:
        _assign_textures_to_overlays()
        return

    _update_timer = _UPDATE_INTERVAL

    if _gpu_available:
        _update_fog_gpu()
    else:
        _update_fog_cpu()

    _assign_textures_to_overlays()

func _update_fog_gpu() -> void:
    var player_tile: Vector2i = _chunk_parent.snap_global_to_grid(_player.global_position)
    var player_chunk: Vector2i = _chunk_parent.get_chunk_pos(player_tile)
    var w: int = _chunk_parent._chunk_width if _chunk_parent._chunk_width > 0 else 16
    var light_radius_tiles: float = float(FogTextureSystemScript.LIGHT_RADIUS_TILES)

    # Build lights array (player + projectiles + explosions)
    var lights: Array[Dictionary] = []
    lights.append({
        "tile_pos": player_tile,
        "radius": light_radius_tiles,
        "intensity": 1.0
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

    # Chunks that need visibility update (player light + extra lights)
    var light_chunks: int = int(ceil(light_radius_tiles / float(w))) + 1
    var min_cx: int = player_chunk.x - light_chunks
    var max_cx: int = player_chunk.x + light_chunks
    var min_cy: int = player_chunk.y - light_chunks
    var max_cy: int = player_chunk.y + light_chunks

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

    for proj in _tracked_projectiles:
        if is_instance_valid(proj):
            var proj_tile: Vector2i = _chunk_parent.snap_global_to_grid(proj.global_position)
            _fog_system.add_extra_light(proj_tile, PROJECTILE_LIGHT_RADIUS, PROJECTILE_LIGHT_INTENSITY)

    for flash in _explosion_flashes:
        var flash_tile: Vector2i = _chunk_parent.snap_global_to_grid(flash["position"])
        _fog_system.add_extra_light(flash_tile, flash["radius"], flash["intensity"])

    var player_tile: Vector2i = _chunk_parent.snap_global_to_grid(_player.global_position)
    var player_chunk: Vector2i = _chunk_parent.get_chunk_pos(player_tile)
    var w: int = _chunk_parent._chunk_width if _chunk_parent._chunk_width > 0 else 16

    var light_chunks: int = int(ceil(FogTextureSystemScript.LIGHT_RADIUS_TILES / float(w))) + 1
    var min_cx: int = player_chunk.x - light_chunks
    var max_cx: int = player_chunk.x + light_chunks
    var min_cy: int = player_chunk.y - light_chunks
    var max_cy: int = player_chunk.y + light_chunks

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
            var local_tx: int = player_tile.x - cx * w
            var local_ty: int = player_tile.y - cy * w
            _fog_system.update_fog(cpos, local_tx, local_ty, ch.map_width, ch.map_height)

    for cx in range(player_chunk.x - VIEW_CHUNK_RADIUS, player_chunk.x + VIEW_CHUNK_RADIUS + 1):
        for cy in range(player_chunk.y - VIEW_CHUNK_RADIUS, player_chunk.y + VIEW_CHUNK_RADIUS + 1):
            var cpos := Vector2i(cx, cy)
            var ch: Chunk = _chunk_parent.get_chunk_if_exists(cpos)
            if not ch:
                continue
            _fog_system.get_or_create_fog(cpos, ch.map_width, ch.map_height)

func _assign_textures_to_overlays() -> void:
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
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        ch.create_fog_overlay_if_needed()
        var tex: ImageTexture = _gpu_fog_system.get_texture(ch.chunk_pos)
        if tex:
            ch.fog_overlay.texture = tex
            ch.fog_overlay.visible = true
        else:
            ch.fog_overlay.visible = false

func _assign_cpu_textures() -> void:
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        _fog_system.get_or_create_fog(ch.chunk_pos, ch.map_width, ch.map_height)
    for ch in _chunk_parent.get_chunks():
        if not is_instance_valid(ch):
            continue
        ch.create_fog_overlay_if_needed()
        var tex: ImageTexture = _fog_system.get_texture(ch.chunk_pos) as ImageTexture
        if tex:
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

## Call this to unregister a projectile
func untrack_projectile(projectile: Node2D) -> void:
    _tracked_projectiles.erase(projectile)

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
