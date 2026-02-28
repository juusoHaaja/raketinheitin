extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
@export var world_seed: int = 69420
@export var fill_percent: int = 48
@export var smoothing_iterations: int = 8

@export var generation_radius: int = 16
@export var border_threshold: int = 128
@export var view_radius: int = 12

@export var max_chunks_per_frame: int = 4
@export var max_chunks_per_frame_urgent: int = 16

@export var initial_sync_radius: int = 12
@export var emergency_radius: int = 8

@export var falling_materials: PackedInt32Array = PackedInt32Array([1])
@export var fall_update_interval: float = 0.02
@export var fall_speed: int = 2
@export var enable_diagonal_falling: bool = true

var chunks: Array[Chunk] = []
var _chunk_lookup: Dictionary = {}  # Vector2i -> Chunk

var _generation_queue: Array[Vector2i] = []
var _priority_queue: Array[Vector2i] = []

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

# Chunk pooling
var _chunk_pool: Array[Chunk] = []
var _max_pool_size: int = 32

# Distance cache for sorting
var _distance_cache: Dictionary = {}
var _distance_cache_player_chunk: Vector2i = Vector2i(-999, -999)

# Precomputed values
var _emergency_radius_sq: int = 0

signal initial_chunks_ready

func _enter_tree() -> void:
    instance = self

func _ready() -> void:
    _emergency_radius_sq = emergency_radius * emergency_radius
    _setup_noise()
    
    var initial_chunk: Chunk = _force_generate_immediate(Vector2i.ZERO)
    _chunk_width = initial_chunk.map_width
    
    _force_generate_area(Vector2i.ZERO, initial_sync_radius)
    _initial_generation_complete = true
    
    api_init()
    generate_chunks_around(Vector2i.ZERO, view_radius)
    
    emit_signal("initial_chunks_ready")
    call_deferred("_find_player")

func _force_generate_area(center: Vector2i, radius: int) -> void:
    _force_generate_immediate(center)
    for r: int in range(1, radius + 1):
        for x: int in range(-r, r + 1):
            for y: int in range(-r, r + 1):
                if abs(x) == r or abs(y) == r:
                    _force_generate_immediate(center + Vector2i(x, y))

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

    for i: int in MATERIAL_COUNT:
        var noise: FastNoiseLite = FastNoiseLite.new()
        noise.seed = world_seed + (i + 1) * 12345
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.frequency = material_freqs[i]
        noise.fractal_octaves = material_octaves[i]
        material_noises[i] = noise
        _material_thresholds[i] = thresholds[i]
        _material_weights[i] = weights[i]

func generate_chunk(pos: Vector2i) -> void:
    if pos in _chunk_lookup:
        return
    if pos in _generation_queue or pos in _priority_queue:
        return
    _generation_queue.append(pos)

func generate_chunk_priority(pos: Vector2i) -> void:
    if pos in _chunk_lookup:
        return
    
    var idx: int = _generation_queue.find(pos)
    if idx >= 0:
        _generation_queue.remove_at(idx)
    if pos not in _priority_queue:
        _priority_queue.append(pos)

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
    
    chunk.reset_for_reuse()
    remove_child(chunk)
    _chunk_pool.append(chunk)

func _force_generate_immediate(pos: Vector2i) -> Chunk:
    var existing: Chunk = _chunk_lookup.get(pos)
    if existing:
        return existing
    
    var idx: int = _generation_queue.find(pos)
    if idx >= 0:
        _generation_queue.remove_at(idx)
    idx = _priority_queue.find(pos)
    if idx >= 0:
        _priority_queue.remove_at(idx)
    
    return _instantiate_chunk(pos)

func _instantiate_chunk(pos: Vector2i) -> Chunk:
    var c: Chunk = _get_pooled_chunk()
    c.world_seed = world_seed
    c.fill_percent = fill_percent
    c.smoothing_iterations = smoothing_iterations
    c.chunk_parent = self

    chunks.append(c)
    _chunk_lookup[pos] = c
    add_child(c)
    c.gen_init(pos)
    
    # Invalidate neighbor caches of adjacent chunks
    _invalidate_neighbor_caches_around(pos)
    
    return c

func _invalidate_neighbor_caches_around(pos: Vector2i) -> void:
    for dy: int in range(-1, 2):
        for dx: int in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
            var neighbor_pos: Vector2i = pos + Vector2i(dx, dy)
            var neighbor: Chunk = _chunk_lookup.get(neighbor_pos)
            if neighbor:
                neighbor._invalidate_neighbor_cache()

func is_generated(pos: Vector2i) -> bool:
    return pos in _chunk_lookup

func force_generate(pos: Vector2i) -> Chunk:
    return _force_generate_immediate(pos)

func get_chunk(pos: Vector2i) -> Chunk:
    var existing: Chunk = _chunk_lookup.get(pos)
    if existing:
        return existing
    return _force_generate_immediate(pos)

func get_chunk_if_exists(pos: Vector2i) -> Chunk:
    return _chunk_lookup.get(pos)

func get_cave_value_at_world_pos(world_pos: Vector2i) -> float:
    return cave_noise.get_noise_2d(world_pos.x, world_pos.y)

func get_material_at_world_pos(world_pos: Vector2i) -> int:
    var best_material: int = 1
    var best_value: float = -999.0

    for i: int in _material_count:
        var weight: float = _material_weights[i]
        if weight <= 0.0:
            continue
        
        var noise_val: float = material_noises[i].get_noise_2d(world_pos.x, world_pos.y)
        var adjusted: float = (noise_val - _material_thresholds[i]) * weight
        
        if adjusted > best_value:
            best_value = adjusted
            best_material = i + 1

    return best_material

func is_solid_at_world_pos(world_pos: Vector2i) -> bool:
    var c_pos: Vector2i = get_chunk_pos(world_pos)
    
    var chunk: Chunk = _chunk_lookup.get(c_pos)
    if chunk and chunk.generation_complete:
        var local_pos: Vector2i = pos_modulo_chunk(world_pos)
        return chunk.api_get_tile_pos(local_pos) != 0
    
    var noise_val: float = cave_noise.get_noise_2d(world_pos.x, world_pos.y)
    var threshold: float = (fill_percent - 50.0) / 50.0 * 0.5
    return noise_val > threshold

func _process(delta: float) -> void:
    _ensure_player_has_ground()
    _process_generation_queue()
    _check_player_chunk_proximity()
    _process_falling_dirt(delta)

func _ensure_player_has_ground() -> void:
    if not is_instance_valid(player):
        return
    
    var player_tile: Vector2i = snap_global_to_grid(player.global_position)
    var player_chunk: Vector2i = get_chunk_pos(player_tile)
    
    for dy: int in range(-emergency_radius, emergency_radius + 1):
        for dx: int in range(-emergency_radius, emergency_radius + 1):
            if dx * dx + dy * dy > _emergency_radius_sq:
                continue
            var check_pos: Vector2i = player_chunk + Vector2i(dx, dy)
            if check_pos not in _chunk_lookup:
                _force_generate_immediate(check_pos)
                
func _process_falling_dirt(delta: float) -> void:
    if falling_materials.is_empty():
        return
    
    _fall_timer += delta
    if _fall_timer < fall_update_interval:
        return
    _fall_timer = 0.0
    
    # Convert PackedInt32Array to Array[int] for compatibility
    var fall_mats: Array[int] = []
    for mat: int in falling_materials:
        fall_mats.append(mat)
    
    var chunk_count: int = chunks.size()
    for i: int in chunk_count:
        var chunk: Chunk = chunks[i]
        if chunk.generation_complete and chunk.needs_fall_update:
            chunk.update_falling_materials(fall_mats, fall_speed, enable_diagonal_falling)

func _process_generation_queue() -> void:
    var is_urgent: bool = _priority_queue.size() > 0
    var max_this_frame: int = max_chunks_per_frame_urgent if is_urgent else max_chunks_per_frame
    
    var generated: int = 0
    
    if _priority_queue.size() > 0:
        _sort_queue_by_player_distance(_priority_queue)
        
        while _priority_queue.size() > 0 and generated < max_this_frame:
            var pos: Vector2i = _priority_queue.pop_front()
            if pos not in _chunk_lookup:
                _instantiate_chunk(pos)
                generated += 1
    
    if generated < max_this_frame and _generation_queue.size() > 0:
        if Engine.get_process_frames() % 10 == 0:
            _sort_queue_by_player_distance(_generation_queue)
        
        while _generation_queue.size() > 0 and generated < max_this_frame:
            var pos: Vector2i = _generation_queue.pop_front()
            if pos not in _chunk_lookup:
                _instantiate_chunk(pos)
                generated += 1

func _sort_queue_by_player_distance(queue: Array[Vector2i]) -> void:
    if queue.size() <= 1:
        return
    
    var player_chunk: Vector2i = _last_player_chunk
    
    # Invalidate cache if player moved
    if player_chunk != _distance_cache_player_chunk:
        _distance_cache.clear()
        _distance_cache_player_chunk = player_chunk
    
    # Limit cache size
    if _distance_cache.size() > 500:
        _distance_cache.clear()
    
    # Cache distances
    for pos: Vector2i in queue:
        if pos not in _distance_cache:
            _distance_cache[pos] = _manhattan_distance(pos, player_chunk)
    
    if queue.size() > 20:
        queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
            return _distance_cache[a] < _distance_cache[b]
        )
    else:
        # Insertion sort for small queues
        for i: int in range(1, queue.size()):
            var key: Vector2i = queue[i]
            var key_dist: int = _distance_cache[key]
            var j: int = i - 1
            while j >= 0:
                if _distance_cache[queue[j]] <= key_dist:
                    break
                queue[j + 1] = queue[j]
                j -= 1
            queue[j + 1] = key

func _manhattan_distance(a: Vector2i, b: Vector2i) -> int:
    return abs(a.x - b.x) + abs(a.y - b.y)

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

    var directions: int = 0
    if local_pos.x < bt:
        directions |= 1
    if local_pos.x >= _chunk_width - bt:
        directions |= 2
    if local_pos.y < bt:
        directions |= 4
    if local_pos.y >= _chunk_width - bt:
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
    for i: int in range(1, generation_radius + 1):
        var pos: Vector2i = from_chunk + direction * i
        if i <= 2:
            generate_chunk_priority(pos)
        else:
            generate_chunk(pos)

func generate_chunks_around(center_chunk: Vector2i, radius: int = -1) -> void:
    if radius < 0:
        radius = generation_radius
    
    for r: int in range(1, radius + 1):
        for x: int in range(-r, r + 1):
            for y: int in range(-r, r + 1):
                if abs(x) == r or abs(y) == r:
                    generate_chunk(center_chunk + Vector2i(x, y))

func _ensure_generation_around(center: Vector2i) -> void:
    var force_radius: int = 3
    var priority_radius: int = 10
    var normal_radius: int = view_radius
    var force_radius_sq: int = force_radius * force_radius
    var normal_radius_sq: int = normal_radius * normal_radius
    
    for dy: int in range(-force_radius, force_radius + 1):
        for dx: int in range(-force_radius, force_radius + 1):
            if dx * dx + dy * dy > force_radius_sq:
                continue
            var pos: Vector2i = center + Vector2i(dx, dy)
            if pos not in _chunk_lookup:
                _force_generate_immediate(pos)
    
    for r: int in range(force_radius + 1, normal_radius + 1):
        for dy: int in range(-r, r + 1):
            for dx: int in range(-r, r + 1):
                if abs(dx) != r and abs(dy) != r:
                    continue
                if dx * dx + dy * dy > normal_radius_sq:
                    continue
                    
                var pos: Vector2i = center + Vector2i(dx, dy)
                if pos in _chunk_lookup:
                    continue
                    
                if r <= priority_radius:
                    generate_chunk_priority(pos)
                else:
                    generate_chunk(pos)

func generate_chunks_around_prioritized(center_chunk: Vector2i, radius: int = -1) -> void:
    if radius < 0:
        radius = generation_radius
    
    var priority_rings: int = 4
    var radius_sq: int = radius * radius
    
    for r: int in range(1, radius + 1):
        for x: int in range(-r, r + 1):
            for y: int in range(-r, r + 1):
                if abs(x) == r or abs(y) == r:
                    if x * x + y * y > radius_sq:
                        continue
                    var pos: Vector2i = center_chunk + Vector2i(x, y)
                    if r <= priority_rings:
                        generate_chunk_priority(pos)
                    else:
                        generate_chunk(pos)
                        
func create_room_at_world_pos(world_tile_pos: Vector2i, radius: int) -> void:
    var min_chunk: Vector2i = get_chunk_pos(world_tile_pos - Vector2i(radius, radius))
    var max_chunk: Vector2i = get_chunk_pos(world_tile_pos + Vector2i(radius, radius))

    for cx: int in range(min_chunk.x, max_chunk.x + 1):
        for cy: int in range(min_chunk.y, max_chunk.y + 1):
            var chunk_p: Vector2i = Vector2i(cx, cy)
            var chunk: Chunk = get_chunk(chunk_p)
            var local_center: Vector2i = world_tile_pos - (chunk_p * _chunk_width)
            chunk.create_room(local_center, radius)

# API
var current_chunk: Chunk
var current_chunk_pos: Vector2i

func api_init() -> void:
    set_api_chunk(chunks[0])

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
    
    var old_val: int = current_chunk.api_get_tile_pos(local_pos)
    current_chunk.api_set_tile_pos(local_pos, val)
    
    if old_val != 0 and val == 0:
        current_chunk.needs_fall_update = true
        var above_pos: Vector2i = c_pos + Vector2i(0, -1)
        var above_chunk: Chunk = _chunk_lookup.get(above_pos)
        if above_chunk:
            above_chunk.needs_fall_update = true

func snap_global_to_grid(pos: Vector2) -> Vector2i:
    var tile_size: float = chunks[0].tile_set.tile_size.x
    return Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size))

func get_chunk_pos(pos: Vector2i) -> Vector2i:
    var width: int = _chunk_width if _chunk_width > 0 else 16
    
    @warning_ignore("integer_division")
    var cx: int = pos.x / width if pos.x >= 0 else (pos.x - width + 1) / width
    @warning_ignore("integer_division")
    var cy: int = pos.y / width if pos.y >= 0 else (pos.y - width + 1) / width
    return Vector2i(cx, cy)
    
func pos_modulo_chunk(pos: Vector2i) -> Vector2i:
    var lx: int = pos.x % _chunk_width
    var ly: int = pos.y % _chunk_width
    if lx < 0:
        lx += _chunk_width
    if ly < 0:
        ly += _chunk_width
    return Vector2i(lx, ly)

func regenerate_chunk(pos: Vector2i) -> void:
    var chunk: Chunk = get_chunk(pos)
    chunk.create_cells()
    chunk.generate()

func get_stats() -> Dictionary:
    return {
        "chunks_loaded": chunks.size(),
        "queue_size": _generation_queue.size(),
        "priority_queue_size": _priority_queue.size(),
        "player_chunk": _last_player_chunk,
        "initial_ready": _initial_generation_complete,
        "pool_size": _chunk_pool.size()
    }

func is_area_generated(center: Vector2i, radius: int) -> bool:
    for x: int in range(-radius, radius + 1):
        for y: int in range(-radius, radius + 1):
            if center + Vector2i(x, y) not in _chunk_lookup:
                return false
    return true

# Cleanup unused chunks (call periodically if needed)
func cleanup_distant_chunks(center: Vector2i, max_distance: int) -> void:
    var to_remove: Array[Vector2i] = []
    var max_dist_sq: int = max_distance * max_distance
    
    for pos: Vector2i in _chunk_lookup:
        var dx: int = pos.x - center.x
        var dy: int = pos.y - center.y
        if dx * dx + dy * dy > max_dist_sq:
            to_remove.append(pos)
    
    for pos: Vector2i in to_remove:
        var chunk: Chunk = _chunk_lookup[pos]
        _chunk_lookup.erase(pos)
        chunks.erase(chunk)
        _return_to_pool(chunk)
