# world/tools/circle_tool.gd
class_name CircleTool
extends TileTool

var radius: float = 3.0
var radius_squared: float = radius * radius

var explosion_granularity: int = 8
var granularity_off:float = 0
var ray_segments := Array()

## Applies the circle (destroy or place). When destroying (material_index == 0), returns
## the list of destroyed tiles so the caller can spawn effects once (avoids double work).
func apply(center: Vector2i) -> Array[Dictionary]:
    if material_index == 0:
        initialize_granularity()

    # Ensure all chunks that could be affected by this circle are generated (fireballs, explosions, etc.)
    ChunkParent.instance.ensure_chunks_generated_in_radius(center, radius)

    var radius_int := int(ceil(radius))
    var destroyed_tiles: Array[Dictionary] = []
    var affected_chunks: Dictionary = {}  # chunk_pos -> Array of local_pos (Vector2i)
    var cp := ChunkParent.instance

    for dy in range(-radius_int, radius_int + 1):
        for dx in range(-radius_int, radius_int + 1):
            if dx * dx + dy * dy > radius_squared:
                continue
            var pos := center + Vector2i(dx, dy)

            if material_index == 0:  # Destroying: collect for batch
                var current_tile := cp.api_get_tile_pos(pos)
                if current_tile != 0:
                    var diff := pos - center
                    var g_index := diff_to_granularity_index(diff)
                    ray_segments[g_index] -= current_tile
                    if ray_segments[g_index] < 0:
                        continue
                    destroyed_tiles.append({"position": pos, "material": current_tile})
                    var chunk_pos := cp.get_chunk_pos(pos)
                    var local_pos := cp.pos_modulo_chunk(pos)
                    if not affected_chunks.has(chunk_pos):
                        affected_chunks[chunk_pos] = []
                    affected_chunks[chunk_pos].append(local_pos)
            else:  # Placing: one tile at a time
                set_tile(pos, material_index)

    for key in affected_chunks:
        var chunk_pos := key as Vector2i
        var chunk: Chunk = cp.get_chunk(chunk_pos)
        if chunk.generation_complete:
            chunk.destroy_tiles_batch(affected_chunks[chunk_pos])

    return destroyed_tiles

## Call after apply() when you want to spawn destruction effects (e.g. from editor tools).
## Projectiles use apply_global_return_destroyed() and call create_explosion once themselves.
func spawn_destruction_effects(center: Vector2i, destroyed_tiles: Array[Dictionary]) -> void:
    if DestructionManager.instance == null or destroyed_tiles.is_empty():
        return
    var tile_size: float = ChunkParent.instance.get_tile_size()
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

## Apply at world position and return destroyed tiles (for projectiles: single iteration, single create_explosion).
func apply_global_return_destroyed(global_pos: Vector2) -> Array[Dictionary]:
    var center: Vector2i = ChunkParent.instance.snap_global_to_grid(global_pos)
    return apply(center)

func _init(r: float = 3.0) -> void:
    set_radius(r)
    super._init()
