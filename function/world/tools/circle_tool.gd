# world/tools/circle_tool.gd
class_name CircleTool
extends TileTool

var radius: float = 3.0
var radius_squared: float = radius * radius

var explosion_granularity: int = 8
var granularity_off:float = 0
var ray_segments := Array()

func apply(center: Vector2i):
    if material_index == 0:
        initialize_granularity()

    var radius_int := int(ceil(radius))
    var destroyed_tiles: Array[Dictionary] = []
    
    for y in range(radius_int*2 + 1):
        for x in range(radius_int*2 + 1):
            if x > radius_int:
                x = radius_int-x
            if y > radius_int:
                y = radius_int-y
            var pos := Vector2i(x, y)+center


            var distance := Vector2(center).distance_squared_to(Vector2(pos))
            if distance > radius_squared:
                continue
            
            var dont_destroy = false

            # Track what we're destroying for particles
            if material_index == 0:  # Only when destroying
            
                var current_tile := ChunkParent.instance.api_get_tile_pos(pos)



                if current_tile != 0:
                    var diff = pos-center
                    var g_index = diff_to_granularity_index(diff)
                    ray_segments[g_index] -= current_tile
                    
                    if ray_segments[g_index] < 0:
                        dont_destroy = true
                    if not dont_destroy:
                        destroyed_tiles.append({
                            "position": pos,
                            "material": current_tile
                        })
            if not dont_destroy:
                set_tile(pos, material_index)
    
    # Spawn particles if we destroyed tiles
    if destroyed_tiles.size() > 0:
        _spawn_destruction_particles(center, destroyed_tiles)

func _spawn_destruction_particles(center: Vector2i, destroyed_tiles: Array[Dictionary]) -> void:
    if DestructionManager.instance == null:
        return
    
    # Convert tile position to world position
    var tile_size: float = ChunkParent.instance.chunks[0].tile_set.tile_size.x
    var world_pos := Vector2(center) * tile_size + Vector2(tile_size / 2.0, tile_size / 2.0)
    
    DestructionManager.instance.create_explosion(world_pos, destroyed_tiles, radius * tile_size)

func diff_to_granularity_index(diff: Vector2i) -> int:
    var difff := diff as Vector2
    var angle = difff.angle()+granularity_off
    if angle < 0:
        angle += TAU
    var n = floor(angle / TAU * explosion_granularity)
    return n

func initialize_granularity():
    ray_segments.clear()
    granularity_off = (randf()-0.5)*TAU
    for i in range(explosion_granularity):
        ray_segments.push_back(radius_squared/3)

func set_radius(r: float):
    radius = r
    radius_squared = r * r

func _init(r: float = 3.0) -> void:
    set_radius(r)
    super._init()
