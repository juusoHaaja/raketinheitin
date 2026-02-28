# world/chunk_parent.gd
extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
@export var world_seed := 1
@export var fill_percent := 48
@export var smoothing_iterations := 12

@export var generation_radius := 5
@export var border_threshold := 50
@export var view_radius := 10

# Maximum chunks to generate per frame (spreads load across frames)
@export var max_chunks_per_frame := 2  # Increased from 1

var chunks = Array()
var _chunk_lookup: Dictionary = {}  # Vector2i -> Chunk

# Pending chunk generation queue
var _generation_queue: Array[Vector2i] = []

# Noise generators for materials
var cave_noise: FastNoiseLite
var material_noises: Array[FastNoiseLite] = []
var _material_thresholds: PackedFloat32Array
var _material_weights: PackedFloat32Array
var _material_count: int = 0

var player: Node2D = null
var _last_player_chunk: Vector2i = Vector2i(-999, -999) # Track player's last chunk

func _enter_tree() -> void:
    instance = self

func _ready() -> void:
    _setup_noise()
    # Generate initial chunk immediately (not queued)
    _force_generate_immediate(Vector2i(0, 0))
    api_init()
    
    # Generate initial chunks around spawn
    generate_chunks_around(Vector2i(0, 0), view_radius)

    await get_tree().process_frame
    _find_player()

func _find_player() -> void:
    var players = get_tree().get_nodes_in_group("player")
    if players.size() > 0:
        player = players[0] as Node2D
        print("Player found: ", player.name)
    else:
        # Fallback: try to find by common names
        player = get_tree().get_first_node_in_group("Player")
        if player == null:
            var root = get_tree().current_scene
            for child in root.get_children():
                if child.name.to_lower().contains("player") and child is Node2D:
                    player = child
                    break

func _setup_noise() -> void:
    # Cave structure noise
    cave_noise = FastNoiseLite.new()
    cave_noise.seed = world_seed
    cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    cave_noise.frequency = 0.02
    cave_noise.fractal_octaves = 4

    var material_configs = [
        {"freq": 0.02, "octaves": 3},
        {"freq": 0.04, "octaves": 2},
        {"freq": 0.04, "octaves": 2},
        {"freq": 0.04, "octaves": 2},
        {"freq": 0.15, "octaves": 1},
    ]

    var thresholds = [0.3, 0.0, 0.0, 0.0, 0.95]
    var weights = [1.0, 1.2, 1.2, 0.0, 1.0]

    _material_thresholds.resize(material_configs.size())
    _material_weights.resize(material_configs.size())
    _material_count = material_configs.size()

    for i in range(material_configs.size()):
        var noise = FastNoiseLite.new()
        noise.seed = world_seed + (i + 1) * 12345
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.frequency = material_configs[i]["freq"]
        noise.fractal_octaves = material_configs[i]["octaves"]
        material_noises.append(noise)
        _material_thresholds[i] = thresholds[i]
        _material_weights[i] = weights[i]

func generate_chunk(pos: Vector2i):
    if _chunk_lookup.has(pos):
        return
    if pos not in _generation_queue:
        _generation_queue.append(pos)

func _force_generate_immediate(pos: Vector2i) -> Chunk:
    if _chunk_lookup.has(pos):
        return _chunk_lookup[pos]
    return _instantiate_chunk(pos)

func _instantiate_chunk(pos: Vector2i) -> Chunk:
    var c = chunk_scene.instantiate() as Chunk
    c.world_seed = world_seed
    c.fill_percent = fill_percent
    c.smoothing_iterations = smoothing_iterations
    c.chunk_parent = self

    chunks.push_back(c)
    _chunk_lookup[pos] = c
    add_child(c)
    c.gen_init(pos)
    return c

func is_generated(pos: Vector2i) -> bool:
    return _chunk_lookup.has(pos)

func force_generate(pos: Vector2i) -> Chunk:
    return _force_generate_immediate(pos)

func get_chunk(pos: Vector2i) -> Chunk:
    var c = _chunk_lookup.get(pos)
    if c != null:
        return c
    return _force_generate_immediate(pos)

func get_chunk_if_exists(pos: Vector2i) -> Chunk:
    return _chunk_lookup.get(pos)

func get_cave_value_at_world_pos(world_pos: Vector2i) -> float:
    return cave_noise.get_noise_2d(world_pos.x, world_pos.y)

func get_material_at_world_pos(world_pos: Vector2i) -> int:
    var best_material := 1
    var best_value := -999.0

    for i in range(_material_count):
        if _material_weights[i] <= 0.0:
            continue
        var noise_val = material_noises[i].get_noise_2d(world_pos.x, world_pos.y)
        var adjusted = (noise_val - _material_thresholds[i]) * _material_weights[i]
        if adjusted > best_value:
            best_value = adjusted
            best_material = i + 1

    return best_material

# Check if position should be solid (for cross-chunk lookups during smoothing)
func is_solid_at_world_pos(world_pos: Vector2i) -> bool:
    var chunk_pos = get_chunk_pos(world_pos)
    var chunk = _chunk_lookup.get(chunk_pos)

    if chunk != null and chunk.generation_complete:
        var local_pos = pos_modulo_chunk(world_pos)
        return chunk.api_get_tile_pos(local_pos) != 0
    else:
        var noise_val = cave_noise.get_noise_2d(world_pos.x, world_pos.y)
        var threshold = (fill_percent - 50.0) / 50.0 * 0.5
        return noise_val > threshold

func _process(delta: float) -> void:
    _process_generation_queue()
    _check_player_chunk_proximity()

func _process_generation_queue() -> void:
    var generated := 0
    while _generation_queue.size() > 0 and generated < max_chunks_per_frame:
        var pos = _generation_queue.pop_front()
        if not _chunk_lookup.has(pos):
            _instantiate_chunk(pos)
            generated += 1

func _check_player_chunk_proximity() -> void:
    if player == null:
        _find_player()
        return
    
    if not is_instance_valid(player):
        player = null
        return

    var player_tile_pos: Vector2i = snap_global_to_grid(player.global_position)
    var player_chunk_pos: Vector2i = get_chunk_pos(player_tile_pos)

    # If player moved to a new chunk, generate all chunks around them
    if player_chunk_pos != _last_player_chunk:
        _last_player_chunk = player_chunk_pos
        generate_chunks_around(player_chunk_pos, view_radius)
        return

    # Also check border proximity for preloading further chunks
    var local_pos: Vector2i = pos_modulo_chunk(player_tile_pos)
    var chunk_w: int = chunks[0].map_width
    var bt: int = border_threshold

    var lx: int = local_pos.x
    var ly: int = local_pos.y
    var near_left: bool = lx < bt
    var near_right: bool = lx >= chunk_w - bt
    var near_top: bool = ly < bt
    var near_bottom: bool = ly >= chunk_w - bt

    if near_left:
        _queue_direction(player_chunk_pos, Vector2i(-1, 0))
    if near_right:
        _queue_direction(player_chunk_pos, Vector2i(1, 0))
    if near_top:
        _queue_direction(player_chunk_pos, Vector2i(0, -1))
    if near_bottom:
        _queue_direction(player_chunk_pos, Vector2i(0, 1))
    if near_left and near_top:
        _queue_direction(player_chunk_pos, Vector2i(-1, -1))
    if near_right and near_top:
        _queue_direction(player_chunk_pos, Vector2i(1, -1))
    if near_left and near_bottom:
        _queue_direction(player_chunk_pos, Vector2i(-1, 1))
    if near_right and near_bottom:
        _queue_direction(player_chunk_pos, Vector2i(1, 1))
        
func _queue_direction(from_chunk: Vector2i, direction: Vector2i) -> void:
    for i in range(1, generation_radius + 1):
        var new_pos = from_chunk + direction * i
        generate_chunk(new_pos)

func generate_chunks_around(center_chunk: Vector2i, radius: int = -1) -> void:
    if radius < 0:
        radius = generation_radius
    
    # Generate in spiral order (closest first)
    var positions: Array[Vector2i] = []
    for r in range(0, radius + 1):
        for x in range(-r, r + 1):
            for y in range(-r, r + 1):
                if abs(x) == r or abs(y) == r:  # Only edge of current ring
                    positions.append(center_chunk + Vector2i(x, y))
    
    for pos in positions:
        generate_chunk(pos)

func create_room_at_world_pos(world_tile_pos: Vector2i, radius: int) -> void:
    var min_chunk = get_chunk_pos(world_tile_pos - Vector2i(radius, radius))
    var max_chunk = get_chunk_pos(world_tile_pos + Vector2i(radius, radius))

    for cx in range(min_chunk.x, max_chunk.x + 1):
        for cy in range(min_chunk.y, max_chunk.y + 1):
            var chunk_p = Vector2i(cx, cy)
            var chunk = get_chunk(chunk_p)
            var local_center = world_tile_pos - (chunk_p * chunk.map_width)
            chunk.create_room(local_center, radius)

# API
var current_chunk: Chunk
var current_chunk_pos: Vector2i

func api_init():
    set_api_chunk(chunks[0])

func set_api_chunk(chunk: Chunk):
    current_chunk = chunk
    current_chunk_pos = current_chunk.chunk_pos

func check_chunk(pos: Vector2i):
    if current_chunk_pos == pos:
        return
    set_api_chunk(get_chunk(pos))

func api_get_tile_pos(pos: Vector2i) -> int:
    var c_pos = get_chunk_pos(pos)
    check_chunk(c_pos)
    pos = pos_modulo_chunk(pos)
    return current_chunk.api_get_tile_pos(pos)

func api_set_tile_pos(tile_pos: Vector2i, val: int):
    var c_pos = get_chunk_pos(tile_pos)
    check_chunk(c_pos)
    tile_pos = pos_modulo_chunk(tile_pos)
    current_chunk.api_set_tile_pos(tile_pos, val)

func snap_global_to_grid(pos: Vector2) -> Vector2i:
    pos = floor(pos / chunks[0].tile_set.tile_size.x)
    return pos as Vector2i

func get_chunk_pos(pos: Vector2i) -> Vector2i:
    var chunk_w = chunks[0].map_width
    return Vector2i(
        floori(float(pos.x) / chunk_w),
        floori(float(pos.y) / chunk_w)
    )

func pos_modulo_chunk(pos: Vector2i) -> Vector2i:
    var chunk_w = chunks[0].map_width
    return Vector2i(
        posmod(pos.x, chunk_w),
        posmod(pos.y, chunk_w)
    )

func regenerate_chunk(pos: Vector2i) -> void:
    var chunk = get_chunk(pos)
    chunk.create_cells()
    chunk.generate()

# Debug: Get generation stats
func get_stats() -> Dictionary:
    return {
        "chunks_loaded": chunks.size(),
        "queue_size": _generation_queue.size(),
        "player_chunk": _last_player_chunk
    }
