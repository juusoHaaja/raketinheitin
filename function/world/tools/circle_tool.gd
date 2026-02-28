# world/tools/circle_tool.gd
class_name CircleTool
extends TileTool

var radius: float = 3.0
var radius_squared: float = radius * radius

func apply(center: Vector2i):
    var radius_int := int(ceil(radius))
    var destroyed_tiles: Array[Dictionary] = []
    
    for y in range(center.y - radius_int, center.y + radius_int + 1):
        for x in range(center.x - radius_int, center.x + radius_int + 1):
            var pos := Vector2i(x, y)
            
            var distance := Vector2(center).distance_squared_to(Vector2(pos))
            if distance > radius_squared:
                continue
            
            # Track what we're destroying for particles
            if material_index == 0:  # Only when destroying
                var current_tile := ChunkParent.instance.api_get_tile_pos(pos)
                if current_tile != 0:
                    destroyed_tiles.append({
                        "position": pos,
                        "material": current_tile
                    })
            
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

func set_radius(r: float):
    radius = r
    radius_squared = r * r

func _init(r: float = 3.0) -> void:
    set_radius(r)
    super._init()
