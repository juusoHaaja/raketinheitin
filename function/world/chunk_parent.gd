# world/chunk_parent.gd
extends Node2D
class_name ChunkParent

static var instance: ChunkParent

@export var chunk_scene: PackedScene
@export var world_seed := 1
@export var fill_percent := 48
@export var smoothing_iterations := 12

var chunks = Array()

# Noise generators for materials
var cave_noise: FastNoiseLite
var material_noises: Array[FastNoiseLite] = []

func _enter_tree() -> void:
    instance = self

func _ready() -> void:
    _setup_noise()
    generate_chunk(Vector2i(0, 0))
    api_init()

func _setup_noise() -> void:
    # Cave structure noise
    cave_noise = FastNoiseLite.new()
    cave_noise.seed = world_seed
    cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    cave_noise.frequency = 0.05
    cave_noise.fractal_octaves = 4
    
    # Material distribution noises (one per material type)
    # Material 0 = dirt, 1-3 = stone variants, 4 = diamond
    var material_configs = [
        {"freq": 0.02, "octaves": 3},   # Dirt - large patches
        {"freq": 0.04, "octaves": 2},   # Stone 1
        {"freq": 0.04, "octaves": 2},   # Stone 2
        {"freq": 0.04, "octaves": 2},   # Stone 3 (disabled)
        {"freq": 0.15, "octaves": 1},   # Diamond - tiny veins
    ]
    
    for i in range(material_configs.size()):
        var noise = FastNoiseLite.new()
        noise.seed = world_seed + (i + 1) * 12345
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.frequency = material_configs[i]["freq"]
        noise.fractal_octaves = material_configs[i]["octaves"]
        material_noises.append(noise)

func generate_chunk(pos: Vector2i):
    if is_generated(pos):
        return
    force_generate(pos)

func is_generated(pos: Vector2i) -> bool:
    for c: Chunk in chunks:
        if c.chunk_pos == pos:
            return true
    return false

func force_generate(pos: Vector2i) -> Chunk:
    var c = chunk_scene.instantiate() as Chunk
    
    # Pass generation parameters to chunk
    c.world_seed = world_seed
    c.fill_percent = fill_percent
    c.smoothing_iterations = smoothing_iterations
    c.chunk_parent = self
    
    chunks.push_back(c)
    add_child(c)
    c.gen_init(pos)
    return c

func get_chunk(pos: Vector2i) -> Chunk:
    for c: Chunk in chunks:
        if c.chunk_pos == pos:
            return c
    return force_generate(pos)

func get_chunk_if_exists(pos: Vector2i) -> Chunk:
    for c: Chunk in chunks:
        if c.chunk_pos == pos:
            return c
    return null

# Get cave value at world position (used for cross-chunk generation)
func get_cave_value_at_world_pos(world_pos: Vector2i) -> float:
    return cave_noise.get_noise_2d(world_pos.x, world_pos.y)

# Get material at world position based on noise
func get_material_at_world_pos(world_pos: Vector2i) -> int:
    # Sample all material noises and pick the dominant one
    var best_material := 1  # Default to first stone type
    var best_value := -999.0
    
    # Material thresholds - higher = rarer
    # Material 3 (index 3) disabled with weight 0
    # Diamond (index 4) very rare with high threshold and low weight
    var thresholds = [0.3, 0.0, 0.0, 0.0, 0.5]
    var weights = [1.0, 1.2, 1.2, 0.0, 0.1]
    
    for i in range(material_noises.size()):
        # Skip disabled materials
        if weights[i] <= 0.0:
            continue
            
        var noise_val = material_noises[i].get_noise_2d(world_pos.x, world_pos.y)
        var adjusted = (noise_val - thresholds[i]) * weights[i]
        
        if adjusted > best_value:
            best_value = adjusted
            best_material = i + 1  # Materials are 1-indexed
    
    return best_material

# Check if position should be solid (for cross-chunk lookups during smoothing)
func is_solid_at_world_pos(world_pos: Vector2i) -> bool:
    var chunk_pos = get_chunk_pos(world_pos)
    var chunk = get_chunk_if_exists(chunk_pos)
    
    if chunk != null and chunk.generation_complete:
        # Use actual generated data
        var local_pos = pos_modulo_chunk(world_pos)
        return chunk.api_get_tile_pos(local_pos) != 0
    else:
        # Use noise to predict (for chunks not yet generated)
        var noise_val = cave_noise.get_noise_2d(world_pos.x, world_pos.y)
        # Convert fill_percent to threshold
        var threshold = (fill_percent - 50.0) / 50.0 * 0.5
        return noise_val > threshold

func _process(delta: float) -> void:
    pass

# World-space room creation (spans chunks if needed)
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
