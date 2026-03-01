extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
@export var world_seed: int = 69420
@export var fill_percent: int = 48
@export var smoothing_iterations: int = 8

@export var generation_radius: int = 64
@export var border_threshold: int = 256
@export var view_radius: int = 12

@export var max_chunks_per_frame: int = 4
@export var max_chunks_per_frame_urgent: int = 16
@export var max_tilemap_flushes_per_frame: int = 8

# GPU Generation
@export var use_gpu_generation: bool = true
@export var gpu_chunks_per_frame: int = 8

@export var initial_sync_radius: int = 12
@export var emergency_radius: int = 8
## When set (e.g. by menu preview), initial terrain is generated around this world position instead of (0,0).
@export var optional_initial_center: Vector2 = Vector2.ZERO

@export var falling_materials: PackedInt32Array = PackedInt32Array([1])
@export var fall_update_interval: float = 0.02
@export var fall_speed: int = 2
@export var enable_diagonal_falling: bool = true

# Falling particle system (isolated islands → physics particles)
@export var particle_scene: PackedScene  # Assign a scene with FallingParticle script
@export var min_island_size_for_particles: int = 1  # Islands with size >= this can become particles
@export var max_island_size_for_particles: int = 8  # Islands with size > this don't become particles
@export var particle_lifetime: float = 5.0  # How long particles live before despawning

var _chunk_lookup: Dictionary = {}
var _particle_container: Node2D = null

var _generation_queue: Array[Vector2i] = []
var _generation_set: Dictionary = {}  # pos -> true for O(1) membership
var _priority_queue: Array[Vector2i] = []
var _priority_set: Dictionary = {}

var _fall_timer: float = 0.0

var cave_noise: FastNoiseLite
var material_noises: Array[FastNoiseLite] = []
var _material_thresholds: PackedFloat32Array
var _material_weights: PackedFloat32Array
var _material_count: int = 0

var player: Node2D = null
var _last_player_chunk: Vector2i = Vector2i(-999, -999)

var _chunk_width: int = 0
var _initial_generation_complete: bool = false
var _last_ground_check_chunk: Vector2i = Vector2i(-999999, -999999)
var _tile_size_cached: float = 0.0
var _chunks_with_falling: Array[Chunk] = []

# Chunk pooling
var _chunk_pool: Array[Chunk] = []
var _max_pool_size: int = 32

# Lazy TileMap updates: chunks with deferred visual flushes
var _tilemap_dirty_chunks: Array[Chunk] = []
var _tilemap_dirty_set: Dictionary = {}  # chunk -> true for O(1) membership
@export var max_dirty_tiles_per_frame: int = 0  # 0 = no limit; caps total set_cell/erase_cell per frame

# Chunk lookup cache: avoid repeated dict lookups for same (cx, cy) during smoothing / world queries
const _CHUNK_CACHE_SIZE: int = 8
var _chunk_cache_cx: PackedInt32Array = PackedInt32Array()
var _chunk_cache_cy: PackedInt32Array = PackedInt32Array()
var _chunk_cache_chunks: Array[Chunk] = []
var _chunk_cache_next: int = 0

# Precomputed values
var _emergency_radius_sq: int = 0
var _cave_threshold: float = 0.0

# Cached falling materials array
var _fall_mats_array: Array[int] = []

# GPU Generator
var _gpu_generator: GPUChunkGenerator
var _gpu_available: bool = false

signal initial_chunks_ready

func _enter_tree() -> void:
    instance = self

func _exit_tree() -> void:
    if _gpu_generator:
        _gpu_generator.cleanup()
        _gpu_generator = null

func _ready() -> void:
    _emergency_radius_sq = emergency_radius * emergency_radius
    _cave_threshold = (fill_percent - 50.0) / 50.0 * 0.5
    _setup_noise()
    _setup_falling_materials()

    _particle_container = Node2D.new()
    _particle_container.name = "FallingParticles"
    add_child(_particle_container)

    _chunk_cache_cx.resize(_CHUNK_CACHE_SIZE)
    _chunk_cache_cy.resize(_CHUNK_CACHE_SIZE)
    _chunk_cache_chunks.resize(_CHUNK_CACHE_SIZE)
    for i in _CHUNK_CACHE_SIZE:
        _chunk_cache_cx[i] = 0x7FFFFFFF  # invalid sentinel
        _chunk_cache_chunks[i] = null

    # Generate first chunk on CPU to get dimensions, then init GPU
    var initial_chunk: Chunk = _force_generate_immediate_cpu(Vector2i.ZERO)
    _chunk_width = initial_chunk.map_width
    _tile_size_cached = initial_chunk.tile_set.tile_size.x

    _init_gpu_generator()

    var sync_center: Vector2i = Vector2i.ZERO
    if optional_initial_center != Vector2.ZERO:
        sync_center = get_chunk_pos(snap_global_to_grid(optional_initial_center))

    _force_generate_area(sync_center, initial_sync_radius)
    _initial_generation_complete = true

    api_init(sync_center)
    generate_chunks_around(sync_center, view_radius)

    emit_signal("initial_chunks_ready")
    call_deferred("_find_player")

func _setup_falling_materials() -> void:
    _fall_mats_array.clear()
    for mat: int in falling_materials:
        _fall_mats_array.append(mat)

func _force_generate_area(center: Vector2i, radius: int) -> void:
    _force_generate_immediate(center)
    var r: int = 1
    var x: int
    var y: int
    while r <= radius:
        x = -r
        while x <= r:
            y = -r
            while y <= r:
                if abs(x) == r or abs(y) == r:
                    _force_generate_immediate(center + Vector2i(x, y))
                y += 1
            x += 1
        r += 1

func _find_player() -> void:
    var players: Array[Node] = get_tree().get_nodes_in_group("player")
    if players.size() > 0:
        player = players[0] as Node2D
        _ensure_player_has_ground()
    else:
        player = get_tree().get_first_node_in_group("Player")
        if player:
            _ensure_player_has_ground()

func _setup_noise() -> void:
    cave_noise = FastNoiseLite.new()
    cave_noise.seed = world_seed
    cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    cave_noise.frequency = 0.01
    cave_noise.fractal_octaves = 4

    const MATERIAL_COUNT: int = 5
    material_noises.resize(MATERIAL_COUNT)
    _material_thresholds.resize(MATERIAL_COUNT)
    _material_weights.resize(MATERIAL_COUNT)
    _material_count = MATERIAL_COUNT

    var material_freqs: PackedFloat32Array = PackedFloat32Array([0.02, 0.04, 0.04, 0.04, 0.15])
    var material_octaves: PackedInt32Array = PackedInt32Array([3, 2, 2, 2, 1])
    var thresholds: PackedFloat32Array = PackedFloat32Array([0.3, 0.0, 0.0, 0.0, 0.95])
    var weights: PackedFloat32Array = PackedFloat32Array([1.0, 1.2, 1.2, 0.0, 1.0])

    var i: int = 0
    while i < MATERIAL_COUNT:
        var noise: FastNoiseLite = FastNoiseLite.new()
        noise.seed = world_seed + (i + 1) * 12345
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.frequency = material_freqs[i]
        noise.fractal_octaves = material_octaves[i]
        material_noises[i] = noise
        _material_thresholds[i] = thresholds[i]
        _material_weights[i] = weights[i]
        i += 1

func _init_gpu_generator() -> void:
    if not use_gpu_generation:
        print("[ChunkParent] GPU generation disabled by setting")
        return

    _gpu_generator = GPUChunkGenerator.new()

    if not _gpu_generator.initialize(_chunk_width, _chunk_width):
        push_warning("[ChunkParent] GPU generation not available, using CPU fallback")
        _gpu_generator = null
        _gpu_available = false
        return

    # Set up material parameters for GPU
    var material_freqs: PackedFloat32Array = PackedFloat32Array([0.02, 0.04, 0.04, 0.04, 0.15])
    var material_octaves: PackedInt32Array = PackedInt32Array([3, 2, 2, 2, 1])
    var thresholds: PackedFloat32Array = PackedFloat32Array([0.3, 0.0, 0.0, 0.0, 0.95])
    var weights: PackedFloat32Array = PackedFloat32Array([1.0, 1.2, 1.2, 0.0, 1.0])

    var gpu_materials: Array[Vector4] = []
    var i: int = 0
    while i < _material_count:
        gpu_materials.append(Vector4(
            thresholds[i],
            weights[i],
            material_freqs[i],
            float(material_octaves[i])
        ))
        i += 1

    _gpu_generator.set_generation_params(
        world_seed,
        _cave_threshold,
        smoothing_iterations,
        gpu_materials
    )

    _gpu_available = true
    print("[ChunkParent] GPU chunk generation enabled")

func _remove_from_queues(pos: Vector2i) -> void:
    if _generation_set.has(pos):
        var idx: int = _generation_queue.find(pos)
        if idx >= 0:
            _generation_queue.remove_at(idx)
        _generation_set.erase(pos)
    if _priority_set.has(pos):
        var idx: int = _priority_queue.find(pos)
        if idx >= 0:
            _priority_queue.remove_at(idx)
        _priority_set.erase(pos)

func generate_chunk(pos: Vector2i) -> void:
    if _chunk_lookup.has(pos):
        return
    if _generation_set.has(pos) or _priority_set.has(pos):
        return
    _generation_queue.append(pos)
    _generation_set[pos] = true

func generate_chunk_priority(pos: Vector2i) -> void:
    if _chunk_lookup.has(pos):
        return
    if _generation_set.has(pos):
        var idx: int = _generation_queue.find(pos)
        if idx >= 0:
            _generation_queue.remove_at(idx)
        _generation_set.erase(pos)
    if not _priority_set.has(pos):
        _priority_queue.append(pos)
        _priority_set[pos] = true

func _get_pooled_chunk() -> Chunk:
    if _chunk_pool.is_empty():
        return chunk_scene.instantiate() as Chunk
    var chunk: Chunk = _chunk_pool.pop_back()
    chunk.reset_for_reuse()
    return chunk

func _return_to_pool(chunk: Chunk) -> void:
    if _chunk_pool.size() >= _max_pool_size:
        chunk.queue_free()
        return
    if chunk in _chunks_with_falling:
        _chunks_with_falling.erase(chunk)
    if _tilemap_dirty_set.get(chunk, false):
        _tilemap_dirty_chunks.erase(chunk)
        _tilemap_dirty_set.erase(chunk)
    chunk.reset_for_reuse()
    remove_child(chunk)
    _chunk_pool.append(chunk)

func _force_generate_immediate(pos: Vector2i) -> Chunk:
    var existing: Chunk = _chunk_lookup.get(pos)
    if existing:
        return existing

    _remove_from_queues(pos)

    if _gpu_available:
        return _generate_chunk_gpu(pos)

    return _force_generate_immediate_cpu(pos)

func _generate_chunk_gpu(pos: Vector2i) -> Chunk:
    var cells: PackedByteArray = _gpu_generator.generate_chunk(pos)

    if cells.is_empty():
        return _force_generate_immediate_cpu(pos)

    var chunk: Chunk = _get_pooled_chunk()
    chunk.world_seed = world_seed
    chunk.fill_percent = fill_percent
    chunk.smoothing_iterations = smoothing_iterations
    chunk.chunk_parent = self

    _chunk_lookup[pos] = chunk
    add_child(chunk)
    chunk.init_from_gpu_data(pos, cells)

    _invalidate_neighbor_caches_around(pos)

    return chunk

func _force_generate_immediate_cpu(pos: Vector2i) -> Chunk:
    return _instantiate_chunk(pos)

func _instantiate_chunk(pos: Vector2i) -> Chunk:
    var c: Chunk = _get_pooled_chunk()
    c.world_seed = world_seed
    c.fill_percent = fill_percent
    c.smoothing_iterations = smoothing_iterations
    c.chunk_parent = self

    _chunk_lookup[pos] = c
    add_child(c)
    c.gen_init(pos)
    
    _invalidate_neighbor_caches_around(pos)
    
    return c

func _invalidate_neighbor_caches_around(pos: Vector2i) -> void:
    var dy: int = -1
    var dx: int
    var neighbor: Chunk
    while dy <= 1:
        dx = -1
        while dx <= 1:
            if dx != 0 or dy != 0:
                neighbor = _chunk_lookup.get(pos + Vector2i(dx, dy))
                if neighbor:
                    neighbor._invalidate_neighbor_cache()
            dx += 1
        dy += 1

func is_generated(pos: Vector2i) -> bool:
    return _chunk_lookup.has(pos)

func force_generate(pos: Vector2i) -> Chunk:
    return _force_generate_immediate(pos)

## Ensures all chunks that could be touched by a circle (e.g. explosion) are generated.
## Call before applying destruction in a radius so ungenerated chunks are not skipped.
func ensure_chunks_generated_in_radius(center_tile: Vector2i, radius_tiles: float) -> void:
    var radius_i: int = ceili(radius_tiles)
    var min_tile: Vector2i = center_tile - Vector2i(radius_i, radius_i)
    var max_tile: Vector2i = center_tile + Vector2i(radius_i, radius_i)
    var min_chunk: Vector2i = get_chunk_pos(min_tile)
    var max_chunk: Vector2i = get_chunk_pos(max_tile)
    var cx: int = min_chunk.x
    var cy: int
    while cx <= max_chunk.x:
        cy = min_chunk.y
        while cy <= max_chunk.y:
            force_generate(Vector2i(cx, cy))
            cy += 1
        cx += 1

func get_chunk(pos: Vector2i) -> Chunk:
    var existing: Chunk = _chunk_lookup.get(pos)
    if existing:
        return existing
    return _force_generate_immediate(pos)

func get_chunk_if_exists(pos: Vector2i) -> Chunk:
    return _chunk_lookup.get(pos)

func get_chunks() -> Array:
    return _chunk_lookup.values()

func get_cave_value_at_world_pos(world_pos: Vector2i) -> float:
    return cave_noise.get_noise_2d(world_pos.x, world_pos.y)

func get_material_at_world_pos(world_pos: Vector2i) -> int:
    return _get_material_at_coords(world_pos.x, world_pos.y)

# Fast version used internally to avoid Vector2i creation
func _get_material_at_coords(wx: int, wy: int) -> int:
    var best_material: int = 1
    var best_value: float = -999.0
    var weight: float
    var noise_val: float
    var adjusted: float
    
    var i: int = 0
    while i < _material_count:
        weight = _material_weights[i]
        if weight > 0.0:
            noise_val = material_noises[i].get_noise_2d(wx, wy)
            adjusted = (noise_val - _material_thresholds[i]) * weight
            
            if adjusted > best_value:
                best_value = adjusted
                best_material = i + 1
        i += 1

    return best_material

func is_solid_at_world_pos(world_pos: Vector2i) -> bool:
    return _is_solid_at_coords(world_pos.x, world_pos.y)

# Cached chunk lookup to avoid repeated dict + Vector2i for same (cx, cy)
func _get_chunk_cached(cx: int, cy: int) -> Chunk:
    var i: int = 0
    while i < _CHUNK_CACHE_SIZE:
        if _chunk_cache_cx[i] == cx and _chunk_cache_cy[i] == cy:
            return _chunk_cache_chunks[i]
        i += 1
    var chunk: Chunk = _chunk_lookup.get(Vector2i(cx, cy))
    var slot: int = _chunk_cache_next % _CHUNK_CACHE_SIZE
    _chunk_cache_next += 1
    _chunk_cache_cx[slot] = cx
    _chunk_cache_cy[slot] = cy
    _chunk_cache_chunks[slot] = chunk
    return chunk

# Fast version used internally
func _is_solid_at_coords(wx: int, wy: int) -> bool:
    var w: int = _chunk_width if _chunk_width > 0 else 16
    
    @warning_ignore("integer_division")
    var cx: int = wx / w if wx >= 0 else (wx - w + 1) / w
    @warning_ignore("integer_division")
    var cy: int = wy / w if wy >= 0 else (wy - w + 1) / w
    
    var chunk: Chunk = _get_chunk_cached(cx, cy)
    if chunk and chunk.generation_complete:
        var lx: int = wx - cx * w
        var ly: int = wy - cy * w
        return chunk.cells[lx + ly * w] != 0
    
    var noise_val: float = cave_noise.get_noise_2d(wx, wy)
    return noise_val > _cave_threshold

func _process(delta: float) -> void:
    _ensure_player_has_ground()
    _process_generation_queue()
    _check_player_chunk_proximity()
    _process_falling_dirt(delta)
    _process_lazy_tilemap_updates()

func _ensure_player_has_ground() -> void:
    if not is_instance_valid(player):
        return
    
    var player_tile: Vector2i = snap_global_to_grid(player.global_position)
    var player_chunk: Vector2i = get_chunk_pos(player_tile)
    if player_chunk == _last_ground_check_chunk:
        return
    _last_ground_check_chunk = player_chunk
    
    var er: int = emergency_radius
    var er_sq: int = _emergency_radius_sq
    var dy: int = -er
    var dx: int
    var check_pos: Vector2i
    
    while dy <= er:
        dx = -er
        while dx <= er:
            if dx * dx + dy * dy <= er_sq:
                check_pos = player_chunk + Vector2i(dx, dy)
                if not _chunk_lookup.has(check_pos):
                    _force_generate_immediate(check_pos)
            dx += 1
        dy += 1

func spawn_falling_particle(world_pos: Vector2i, material_type: int) -> void:
    if not particle_scene:
        return
    var particle: Node = particle_scene.instantiate()
    if not particle.has_method("setup"):
        particle.queue_free()
        return
    _particle_container.add_child(particle)
    var pixel_pos: Vector2 = Vector2(world_pos) * _tile_size_cached
    particle.global_position = pixel_pos
    particle.setup(material_type, particle_lifetime, _tile_size_cached)

func _register_chunk_for_fall_update(chunk: Chunk) -> void:
    if chunk and chunk not in _chunks_with_falling:
        _chunks_with_falling.append(chunk)

func _register_chunk_for_tilemap_flush(chunk: Chunk) -> void:
    if chunk and not _tilemap_dirty_set.get(chunk, false):
        _tilemap_dirty_chunks.append(chunk)
        _tilemap_dirty_set[chunk] = true

func _process_lazy_tilemap_updates() -> void:
    var flushed: int = 0
    var max_flush: int = max_tilemap_flushes_per_frame
    var tiles_updated: int = 0
    var max_tiles: int = max_dirty_tiles_per_frame
    var i: int = 0
    while i < _tilemap_dirty_chunks.size() and flushed < max_flush:
        if max_tiles > 0 and tiles_updated >= max_tiles:
            break
        var chunk: Chunk = _tilemap_dirty_chunks[i]
        if not is_instance_valid(chunk):
            _tilemap_dirty_chunks.remove_at(i)
            _tilemap_dirty_set.erase(chunk)
            continue
        if chunk._tilemap_dirty:
            var count: int = chunk.flush_tilemap_visuals()
            tiles_updated += count
            flushed += 1
        _tilemap_dirty_set.erase(chunk)
        _tilemap_dirty_chunks.remove_at(i)

## Flush all pending tilemap visuals immediately (e.g. for menu preview so map is fully visible at once).
func flush_all_pending_tilemap_visuals() -> void:
    while _tilemap_dirty_chunks.size() > 0:
        var chunk: Chunk = _tilemap_dirty_chunks[0]
        _tilemap_dirty_set.erase(chunk)
        _tilemap_dirty_chunks.remove_at(0)
        if is_instance_valid(chunk) and chunk._tilemap_dirty:
            chunk.flush_tilemap_visuals()

func _process_falling_dirt(delta: float) -> void:
    if _chunks_with_falling.is_empty():
        return
    _fall_timer += delta
    if _fall_timer < fall_update_interval:
        return
    _fall_timer = 0.0
    
    var i: int = _chunks_with_falling.size() - 1
    while i >= 0:
        var chunk: Chunk = _chunks_with_falling[i]
        if not is_instance_valid(chunk):
            _chunks_with_falling.remove_at(i)
            i -= 1
            continue
        if chunk.generation_complete and chunk.needs_fall_update:
            chunk.update_falling_materials_optimized(_fall_mats_array, fall_speed, enable_diagonal_falling)
            if not chunk.needs_fall_update:
                _chunks_with_falling.remove_at(i)
        i -= 1

func _process_generation_queue() -> void:
    var is_urgent: bool = _priority_queue.size() > 0
    var max_this_frame: int
    if _gpu_available:
        max_this_frame = gpu_chunks_per_frame
    else:
        max_this_frame = max_chunks_per_frame_urgent if is_urgent else max_chunks_per_frame

    var generated: int = 0
    var pos: Vector2i

    if _priority_queue.size() > 0:
        _sort_queue_by_player_distance(_priority_queue)

        while _priority_queue.size() > 0 and generated < max_this_frame:
            pos = _priority_queue.pop_front()
            _priority_set.erase(pos)
            if not _chunk_lookup.has(pos):
                _force_generate_immediate(pos)
                generated += 1

    if generated < max_this_frame and _generation_queue.size() > 0:
        if Engine.get_process_frames() % 10 == 0:
            _sort_queue_by_player_distance(_generation_queue)

        while _generation_queue.size() > 0 and generated < max_this_frame:
            pos = _generation_queue.pop_front()
            _generation_set.erase(pos)
            if not _chunk_lookup.has(pos):
                _force_generate_immediate(pos)
                generated += 1

func _sort_queue_by_player_distance(queue: Array[Vector2i]) -> void:
    var size: int = queue.size()
    if size <= 1:
        return
    
    var px: int = _last_player_chunk.x
    var py: int = _last_player_chunk.y
    
    if size > 20:
        queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
            var dist_a: int = abs(a.x - px) + abs(a.y - py)
            var dist_b: int = abs(b.x - px) + abs(b.y - py)
            return dist_a < dist_b
        )
    else:
        # Insertion sort for small queues
        var i: int = 1
        var key: Vector2i
        var key_dist: int
        var j: int
        var compare_dist: int
        
        while i < size:
            key = queue[i]
            key_dist = abs(key.x - px) + abs(key.y - py)
            j = i - 1
            while j >= 0:
                compare_dist = abs(queue[j].x - px) + abs(queue[j].y - py)
                if compare_dist <= key_dist:
                    break
                queue[j + 1] = queue[j]
                j -= 1
            queue[j + 1] = key
            i += 1

func _check_player_chunk_proximity() -> void:
    if not is_instance_valid(player):
        _find_player()
        return

    var player_tile_pos: Vector2i = snap_global_to_grid(player.global_position)
    var player_chunk_pos: Vector2i = get_chunk_pos(player_tile_pos)

    _ensure_generation_around(player_chunk_pos)

    if player_chunk_pos != _last_player_chunk:
        _last_player_chunk = player_chunk_pos
        generate_chunks_around_prioritized(player_chunk_pos, view_radius)
        return

    var local_pos: Vector2i = pos_modulo_chunk(player_tile_pos)
    var bt: int = border_threshold
    var cw: int = _chunk_width

    var directions: int = 0
    if local_pos.x < bt:
        directions |= 1
    if local_pos.x >= cw - bt:
        directions |= 2
    if local_pos.y < bt:
        directions |= 4
    if local_pos.y >= cw - bt:
        directions |= 8

    if directions & 1:
        _queue_direction_priority(player_chunk_pos, Vector2i(-1, 0))
    if directions & 2:
        _queue_direction_priority(player_chunk_pos, Vector2i(1, 0))
    if directions & 4:
        _queue_direction_priority(player_chunk_pos, Vector2i(0, -1))
    if directions & 8:
        _queue_direction_priority(player_chunk_pos, Vector2i(0, 1))
    
    if (directions & 5) == 5:
        _queue_direction_priority(player_chunk_pos, Vector2i(-1, -1))
    if (directions & 6) == 6:
        _queue_direction_priority(player_chunk_pos, Vector2i(1, -1))
    if (directions & 9) == 9:
        _queue_direction_priority(player_chunk_pos, Vector2i(-1, 1))
    if (directions & 10) == 10:
        _queue_direction_priority(player_chunk_pos, Vector2i(1, 1))

func _queue_direction_priority(from_chunk: Vector2i, direction: Vector2i) -> void:
    var i: int = 1
    var pos: Vector2i
    while i <= generation_radius:
        pos = from_chunk + direction * i
        if i <= 2:
            generate_chunk_priority(pos)
        else:
            generate_chunk(pos)
        i += 1

func generate_chunks_around(center_chunk: Vector2i, radius: int = -1) -> void:
    if radius < 0:
        radius = generation_radius
    
    var r: int = 1
    var x: int
    var y: int
    
    while r <= radius:
        x = -r
        while x <= r:
            y = -r
            while y <= r:
                if abs(x) == r or abs(y) == r:
                    generate_chunk(center_chunk + Vector2i(x, y))
                y += 1
            x += 1
        r += 1

func _ensure_generation_around(center: Vector2i) -> void:
    var force_radius: int = 3
    var priority_radius: int = 10
    var normal_radius: int = view_radius
    var force_radius_sq: int = force_radius * force_radius
    var normal_radius_sq: int = normal_radius * normal_radius
    
    var dy: int
    var dx: int
    var dist_sq: int
    var pos: Vector2i
    
    dy = -force_radius
    while dy <= force_radius:
        dx = -force_radius
        while dx <= force_radius:
            dist_sq = dx * dx + dy * dy
            if dist_sq <= force_radius_sq:
                pos = center + Vector2i(dx, dy)
                if not _chunk_lookup.has(pos):
                    _force_generate_immediate(pos)
            dx += 1
        dy += 1
    
    var r: int = force_radius + 1
    while r <= normal_radius:
        dy = -r
        while dy <= r:
            dx = -r
            while dx <= r:
                if abs(dx) == r or abs(dy) == r:
                    dist_sq = dx * dx + dy * dy
                    if dist_sq <= normal_radius_sq:
                        pos = center + Vector2i(dx, dy)
                        if not _chunk_lookup.has(pos):
                            if r <= priority_radius:
                                generate_chunk_priority(pos)
                            else:
                                generate_chunk(pos)
                dx += 1
            dy += 1
        r += 1

func generate_chunks_around_prioritized(center_chunk: Vector2i, radius: int = -1) -> void:
    if radius < 0:
        radius = generation_radius
    
    var priority_rings: int = 4
    var radius_sq: int = radius * radius
    
    var r: int = 1
    var x: int
    var y: int
    var dist_sq: int
    var pos: Vector2i
    
    while r <= radius:
        x = -r
        while x <= r:
            y = -r
            while y <= r:
                if abs(x) == r or abs(y) == r:
                    dist_sq = x * x + y * y
                    if dist_sq <= radius_sq:
                        pos = center_chunk + Vector2i(x, y)
                        if r <= priority_rings:
                            generate_chunk_priority(pos)
                        else:
                            generate_chunk(pos)
                y += 1
            x += 1
        r += 1

func create_room_at_world_pos(world_tile_pos: Vector2i, radius: int) -> void:
    var min_chunk: Vector2i = get_chunk_pos(world_tile_pos - Vector2i(radius, radius))
    var max_chunk: Vector2i = get_chunk_pos(world_tile_pos + Vector2i(radius, radius))

    var cx: int = min_chunk.x
    var cy: int
    var chunk_p: Vector2i
    var chunk: Chunk
    var local_center: Vector2i
    
    while cx <= max_chunk.x:
        cy = min_chunk.y
        while cy <= max_chunk.y:
            chunk_p = Vector2i(cx, cy)
            chunk = get_chunk(chunk_p)
            local_center = world_tile_pos - (chunk_p * _chunk_width)
            chunk.create_room(local_center, radius)
            cy += 1
        cx += 1

# API
var current_chunk: Chunk
var current_chunk_pos: Vector2i

func api_init(center_chunk: Vector2i = Vector2i.ZERO) -> void:
    var c: Chunk = _chunk_lookup.get(center_chunk)
    if c:
        set_api_chunk(c)

func set_api_chunk(chunk: Chunk) -> void:
    current_chunk = chunk
    current_chunk_pos = chunk.chunk_pos

func check_chunk(pos: Vector2i) -> void:
    if current_chunk_pos != pos:
        set_api_chunk(get_chunk(pos))

func api_get_tile_pos(pos: Vector2i) -> int:
    check_chunk(get_chunk_pos(pos))
    return current_chunk.api_get_tile_pos(pos_modulo_chunk(pos))

func api_set_tile_pos(tile_pos: Vector2i, val: int) -> void:
    var c_pos: Vector2i = get_chunk_pos(tile_pos)
    check_chunk(c_pos)
    var local_pos: Vector2i = pos_modulo_chunk(tile_pos)
    var w: int = _chunk_width
    var idx: int = local_pos.x + local_pos.y * w
    
    var old_val: int = current_chunk.cells[idx]
    current_chunk.cells[idx] = val
    current_chunk.set_tileset_tile(local_pos, val)
    
    if old_val != 0 and val == 0:
        current_chunk.mark_column_dirty(local_pos.x)
        if local_pos.x > 0:
            current_chunk.mark_column_dirty(local_pos.x - 1)
        if local_pos.x < w - 1:
            current_chunk.mark_column_dirty(local_pos.x + 1)
        current_chunk.needs_fall_update = true
        _register_chunk_for_fall_update(current_chunk)
        var above_chunk: Chunk = _chunk_lookup.get(Vector2i(c_pos.x, c_pos.y - 1))
        if above_chunk:
            above_chunk.needs_fall_update = true
            _register_chunk_for_fall_update(above_chunk)

func snap_global_to_grid(pos: Vector2) -> Vector2i:
    return Vector2i(floori(pos.x / _tile_size_cached), floori(pos.y / _tile_size_cached))

func get_tile_size() -> float:
    return _tile_size_cached

func get_chunk_pos(pos: Vector2i) -> Vector2i:
    var w: int = _chunk_width if _chunk_width > 0 else 16
    
    @warning_ignore("integer_division")
    var cx: int = pos.x / w if pos.x >= 0 else (pos.x - w + 1) / w
    @warning_ignore("integer_division")
    var cy: int = pos.y / w if pos.y >= 0 else (pos.y - w + 1) / w
    return Vector2i(cx, cy)

func pos_modulo_chunk(pos: Vector2i) -> Vector2i:
    var w: int = _chunk_width
    var lx: int = pos.x % w
    var ly: int = pos.y % w
    if lx < 0:
        lx += w
    if ly < 0:
        ly += w
    return Vector2i(lx, ly)

func regenerate_chunk(pos: Vector2i) -> void:
    var chunk: Chunk = get_chunk(pos)
    chunk.create_cells()
    chunk.generate()

func get_stats() -> Dictionary:
    return {
        "chunks_loaded": _chunk_lookup.size(),
        "queue_size": _generation_queue.size(),
        "priority_queue_size": _priority_queue.size(),
        "player_chunk": _last_player_chunk,
        "initial_ready": _initial_generation_complete,
        "pool_size": _chunk_pool.size(),
        "tilemap_dirty_chunks": _tilemap_dirty_chunks.size(),
        "gpu_enabled": _gpu_available
    }

func is_area_generated(center: Vector2i, radius: int) -> bool:
    var x: int = -radius
    var y: int
    while x <= radius:
        y = -radius
        while y <= radius:
            if not _chunk_lookup.has(center + Vector2i(x, y)):
                return false
            y += 1
        x += 1
    return true

func cleanup_distant_chunks(center: Vector2i, max_distance: int) -> void:
    var to_remove: Array[Vector2i] = []
    var max_dist_sq: int = max_distance * max_distance
    var dx: int
    var dy: int
    
    for pos: Vector2i in _chunk_lookup:
        dx = pos.x - center.x
        dy = pos.y - center.y
        if dx * dx + dy * dy > max_dist_sq:
            to_remove.append(pos)
    
    for pos: Vector2i in to_remove:
        var chunk: Chunk = _chunk_lookup[pos]
        _chunk_lookup.erase(pos)
        if chunk in _chunks_with_falling:
            _chunks_with_falling.erase(chunk)
        _return_to_pool(chunk)
