extends TileMapLayer
class_name Chunk

static var chunk_size: int = 16
var chunk_pos: Vector2i = Vector2i.ZERO
var chunk_parent: ChunkParent

@export var tileset_width: int = 8
@export var tileset_height: int = 8
var tileset_count: int = 64

@export var map_width: int = 16
@export var map_height: int = 16

var tile_pixel_size: int = 1

var cells: PackedByteArray = PackedByteArray()

@export var fill_percent: int = 48
@export var smoothing_iterations: int = 12
@export_range(0, 999999) var world_seed: int = 1

var generation_complete: bool = false

var needs_fall_update: bool = false
var _fall_dirty: bool = false

# Pre-allocated buffers
var _temp_solid: PackedByteArray
var _temp_material: PackedByteArray
var _smooth_buffer: PackedByteArray

# Cache for tileset coordinates to avoid repeated calculations
var _tileset_coords_cache: Array[Vector2i] = []

# Falling material lookup table for O(1) checks
var _falling_lookup: PackedByteArray = PackedByteArray()

# Neighbor chunk cache for cross-chunk operations
var _neighbor_cache: Array[Chunk] = []
var _neighbor_cache_valid: bool = false

# Batched tile updates
var _batch_mode: bool = false
var _pending_tile_positions: PackedInt32Array = PackedInt32Array()
var _pending_tile_values: PackedByteArray = PackedByteArray()

# Precomputed values
var _map_size: int = 0
var _chunk_world_offset_x: int = 0
var _chunk_world_offset_y: int = 0

func _ready() -> void:
    tileset_count = tileset_width * tileset_height
    tile_pixel_size = int(scale.x * tile_set.tile_size.x)
    _map_size = map_width * map_height
    
    # Pre-calculate tileset coordinates
    _tileset_coords_cache.resize(tileset_count)
    for i: int in tileset_count:
        _tileset_coords_cache[i] = Vector2i(i % tileset_width, i / tileset_width)

func _init_falling_lookup() -> void:
    if not chunk_parent:
        return
    
    var max_mat: int = 0
    for mat: int in chunk_parent.falling_materials:
        if mat > max_mat:
            max_mat = mat
    
    _falling_lookup.resize(max_mat + 1)
    _falling_lookup.fill(0)
    for mat: int in chunk_parent.falling_materials:
        _falling_lookup[mat] = 1

func _update_world_offset() -> void:
    _chunk_world_offset_x = chunk_pos.x * map_width
    _chunk_world_offset_y = chunk_pos.y * map_height

func _invalidate_neighbor_cache() -> void:
    _neighbor_cache_valid = false

func _ensure_neighbor_cache() -> void:
    if _neighbor_cache_valid:
        return
    
    _neighbor_cache.resize(9)
    for i: int in 9:
        _neighbor_cache[i] = null
    
    if not chunk_parent:
        _neighbor_cache_valid = true
        return
    
    var idx: int = 0
    for dy: int in range(-1, 2):
        for dx: int in range(-1, 2):
            var npos: Vector2i = chunk_pos + Vector2i(dx, dy)
            var nchunk: Chunk = chunk_parent._chunk_lookup.get(npos)
            if nchunk and nchunk.generation_complete:
                _neighbor_cache[idx] = nchunk
            idx += 1
    
    _neighbor_cache_valid = true

func _get_neighbor_cache_index(dx: int, dy: int) -> int:
    return (dy + 1) * 3 + (dx + 1)

func clear_cells() -> void:
    cells.clear()

func create_cells() -> void:
    _map_size = map_width * map_height
    cells.resize(_map_size)
    cells.fill(1)

func pos_to_cell_index(pos: Vector2i) -> int:
    return pos.x + pos.y * map_width

func cell_index_to_pos(index: int) -> Vector2i:
    @warning_ignore("integer_division")
    return Vector2i(index % map_width, index / map_width)

func local_to_world_pos(local_pos: Vector2i) -> Vector2i:
    return local_pos + chunk_pos * map_width

func world_to_local_pos(world_pos: Vector2i) -> Vector2i:
    return world_pos - chunk_pos * map_width

func api_get_tile_pos(pos: Vector2i) -> int:
    return cells[pos.x + pos.y * map_width]

func api_set_tile_pos(pos: Vector2i, val: int) -> void:
    var index: int = pos.x + pos.y * map_width
    cells[index] = val
    set_tileset_tile(pos, val)

func api_get_tile(index: int) -> int:
    return cells[index]

func api_set_tile(index: int, val: int) -> void:
    cells[index] = val
    @warning_ignore("integer_division")
    set_tileset_tile(cell_index_to_pos(index), val)

func global_to_grid(pos: Vector2) -> Vector2i:
    var tile_size: float = tile_set.tile_size.x
    return Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size))

func set_tileset_tile(pos: Vector2i, b: int) -> void:
    if _batch_mode:
        _pending_tile_positions.append(pos.x + pos.y * map_width)
        _pending_tile_values.append(b)
        return
    
    if b == 0:
        erase_cell(pos)
    else:
        var i: int = (b - 1) % tileset_count
        set_cell(pos, 0, _tileset_coords_cache[i], 0)

func begin_batch_update() -> void:
    _batch_mode = true
    _pending_tile_positions.clear()
    _pending_tile_values.clear()

func end_batch_update() -> void:
    _batch_mode = false
    var count: int = _pending_tile_positions.size()
    
    for i: int in count:
        var idx: int = _pending_tile_positions[i]
        var val: int = _pending_tile_values[i]
        @warning_ignore("integer_division")
        var pos: Vector2i = Vector2i(idx % map_width, idx / map_width)
        
        if val == 0:
            erase_cell(pos)
        else:
            var ti: int = (val - 1) % tileset_count
            set_cell(pos, 0, _tileset_coords_cache[ti], 0)
    
    _pending_tile_positions.clear()
    _pending_tile_values.clear()

func update_cells() -> void:
    begin_batch_update()
    
    for i: int in _map_size:
        var val: int = cells[i]
        @warning_ignore("integer_division")
        var pos: Vector2i = Vector2i(i % map_width, i / map_width)
        set_tileset_tile(pos, val)
    
    end_batch_update()

func gen_init(pos: Vector2i) -> void:
    chunk_pos = pos
    _update_world_offset()
    
    if tileset_count == 0:
        tileset_count = tileset_width * tileset_height
    if tile_pixel_size == 0:
        tile_pixel_size = int(scale.x * tile_set.tile_size.x)
    
    global_position = Vector2(pos * chunk_size * tile_pixel_size)
    create_cells()
    _init_falling_lookup()
    generate()

func generate() -> void:
    generation_complete = false
    
    _temp_solid.resize(_map_size)
    _temp_material.resize(_map_size)
    _smooth_buffer.resize(_map_size)

    _initialize_cave_map()

    for _iteration: int in smoothing_iterations:
        _smooth_map()

    _apply_cave_to_cells()
    generation_complete = true
    _invalidate_neighbor_cache()
    
func _initialize_cave_map() -> void:
    var threshold: float = (fill_percent - 50.0) / 50.0 * 0.5
    var cave_noise: FastNoiseLite = chunk_parent.cave_noise
    var chunk_offset_x: int = _chunk_world_offset_x
    var chunk_offset_y: int = _chunk_world_offset_y

    var index: int = 0
    for y: int in map_height:
        var wy: int = chunk_offset_y + y
        for x: int in map_width:
            var wx: int = chunk_offset_x + x
            var cave_val: float = cave_noise.get_noise_2d(wx, wy)

            if cave_val > threshold:
                _temp_solid[index] = 1
                _temp_material[index] = chunk_parent.get_material_at_world_pos(Vector2i(wx, wy))
            else:
                _temp_solid[index] = 0
                _temp_material[index] = 0
            index += 1
            
func _smooth_map() -> void:
    var chunk_offset_x: int = _chunk_world_offset_x
    var chunk_offset_y: int = _chunk_world_offset_y

    var index: int = 0
    for y: int in map_height:
        for x: int in map_width:
            var wall_count: int = _count_neighbors_unrolled(x, y, chunk_offset_x, chunk_offset_y)
            var current_solid: int = _temp_solid[index]

            if wall_count > 4:
                _smooth_buffer[index] = 1
                if current_solid == 0:
                    _temp_material[index] = _get_dominant_neighbor_material_fast(x, y, chunk_offset_x, chunk_offset_y)
            elif wall_count < 4:
                _smooth_buffer[index] = 0
                _temp_material[index] = 0
            else:
                _smooth_buffer[index] = current_solid
            index += 1

    # Swap buffers
    var tmp: PackedByteArray = _temp_solid
    _temp_solid = _smooth_buffer
    _smooth_buffer = tmp

func _count_neighbors_unrolled(x: int, y: int, chunk_offset_x: int, chunk_offset_y: int) -> int:
    var count: int = 0
    var w: int = map_width
    var h: int = map_height
    
    # Top row (y - 1)
    if y > 0:
        var idx_top: int = (y - 1) * w
        if x > 0:
            if _temp_solid[idx_top + x - 1] != 0:
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x - 1, chunk_offset_y + y - 1)):
                count += 1
        
        if _temp_solid[idx_top + x] != 0:
            count += 1
        
        if x < w - 1:
            if _temp_solid[idx_top + x + 1] != 0:
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + w, chunk_offset_y + y - 1)):
                count += 1
    else:
        # y == 0, check chunk above
        var wy: int = chunk_offset_y - 1
        if x > 0:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x - 1, wy)):
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x - 1, wy)):
                count += 1
        
        if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x, wy)):
            count += 1
        
        if x < w - 1:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x + 1, wy)):
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + w, wy)):
                count += 1
    
    # Middle row (y) - only left and right
    var idx_mid: int = y * w
    if x > 0:
        if _temp_solid[idx_mid + x - 1] != 0:
            count += 1
    else:
        if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x - 1, chunk_offset_y + y)):
            count += 1
    
    if x < w - 1:
        if _temp_solid[idx_mid + x + 1] != 0:
            count += 1
    else:
        if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + w, chunk_offset_y + y)):
            count += 1
    
    # Bottom row (y + 1)
    if y < h - 1:
        var idx_bot: int = (y + 1) * w
        if x > 0:
            if _temp_solid[idx_bot + x - 1] != 0:
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x - 1, chunk_offset_y + y + 1)):
                count += 1
        
        if _temp_solid[idx_bot + x] != 0:
            count += 1
        
        if x < w - 1:
            if _temp_solid[idx_bot + x + 1] != 0:
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + w, chunk_offset_y + y + 1)):
                count += 1
    else:
        # y == h - 1, check chunk below
        var wy: int = chunk_offset_y + h
        if x > 0:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x - 1, wy)):
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x - 1, wy)):
                count += 1
        
        if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x, wy)):
            count += 1
        
        if x < w - 1:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + x + 1, wy)):
                count += 1
        else:
            if chunk_parent.is_solid_at_world_pos(Vector2i(chunk_offset_x + w, wy)):
                count += 1
    
    return count

func _get_dominant_neighbor_material_fast(x: int, y: int, chunk_offset_x: int, chunk_offset_y: int) -> int:
    var best_mat: int = 1
    var best_count: int = 0
    var counts: PackedInt32Array = PackedInt32Array()
    counts.resize(16)  # Support up to 16 materials
    counts.fill(0)
    
    var w: int = map_width
    var h: int = map_height

    for dy: int in range(-1, 2):
        var ny: int = y + dy
        for dx: int in range(-1, 2):
            if dx == 0 and dy == 0:
                continue
            var nx: int = x + dx
            var val: int = 0

            if nx >= 0 and nx < w and ny >= 0 and ny < h:
                var ni: int = nx + ny * w
                if _temp_solid[ni] != 0:
                    val = _temp_material[ni]
            else:
                var wx: int = chunk_offset_x + nx
                var wy: int = chunk_offset_y + ny
                if chunk_parent.is_solid_at_world_pos(Vector2i(wx, wy)):
                    val = chunk_parent.get_material_at_world_pos(Vector2i(wx, wy))

            if val > 0 and val < 16:
                counts[val] += 1
                if counts[val] > best_count:
                    best_count = counts[val]
                    best_mat = val

    return best_mat

func _apply_cave_to_cells() -> void:
    for i: int in _map_size:
        cells[i] = _temp_material[i] if _temp_solid[i] != 0 else 0

    update_cells()

    # Clear temp buffers
    _temp_solid = PackedByteArray()
    _temp_material = PackedByteArray()
    _smooth_buffer = PackedByteArray()

# Optimized world cell access with local chunk fast path
func _get_world_cell(world_x: int, world_y: int) -> int:
    # Fast path: check if in this chunk first (avoid division)
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    
    if local_x >= 0 and local_x < map_width and local_y >= 0 and local_y < map_height:
        return cells[local_x + local_y * map_width]
    
    # Slow path: calculate which chunk and get from there
    @warning_ignore("integer_division")
    var cx: int = world_x / map_width if world_x >= 0 else (world_x - map_width + 1) / map_width
    @warning_ignore("integer_division")
    var cy: int = world_y / map_height if world_y >= 0 else (world_y - map_height + 1) / map_height
    
    var lx: int = world_x - cx * map_width
    var ly: int = world_y - cy * map_height
    
    var target_chunk_pos: Vector2i = Vector2i(cx, cy)
    
    if not chunk_parent:
        return -1
    
    var target_chunk: Chunk = chunk_parent._chunk_lookup.get(target_chunk_pos)
    if not target_chunk or not target_chunk.generation_complete:
        return -1
    
    return target_chunk.cells[lx + ly * map_width]

func _get_world_cell_cached(world_x: int, world_y: int) -> int:
    # Fast path: check if in this chunk first
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    
    if local_x >= 0 and local_x < map_width and local_y >= 0 and local_y < map_height:
        return cells[local_x + local_y * map_width]
    
    # Use neighbor cache for adjacent chunks
    _ensure_neighbor_cache()
    
    var dx: int = 0
    var dy: int = 0
    
    if local_x < 0:
        dx = -1
        local_x += map_width
    elif local_x >= map_width:
        dx = 1
        local_x -= map_width
    
    if local_y < 0:
        dy = -1
        local_y += map_height
    elif local_y >= map_height:
        dy = 1
        local_y -= map_height
    
    var cache_idx: int = _get_neighbor_cache_index(dx, dy)
    var neighbor: Chunk = _neighbor_cache[cache_idx]
    
    if neighbor:
        return neighbor.cells[local_x + local_y * map_width]
    
    return -1
    
func _set_world_cell(world_x: int, world_y: int, val: int) -> Chunk:
    # Fast path: check if in this chunk first
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    
    if local_x >= 0 and local_x < map_width and local_y >= 0 and local_y < map_height:
        var idx: int = local_x + local_y * map_width
        cells[idx] = val
        set_tileset_tile(Vector2i(local_x, local_y), val)
        return self
    
    # Slow path
    @warning_ignore("integer_division")
    var cx: int = world_x / map_width if world_x >= 0 else (world_x - map_width + 1) / map_width
    @warning_ignore("integer_division")
    var cy: int = world_y / map_height if world_y >= 0 else (world_y - map_height + 1) / map_height
    
    var lx: int = world_x - cx * map_width
    var ly: int = world_y - cy * map_height
    
    var target_chunk_pos: Vector2i = Vector2i(cx, cy)
    
    if not chunk_parent:
        return null
    
    var target_chunk: Chunk = chunk_parent._chunk_lookup.get(target_chunk_pos)
    if not target_chunk or not target_chunk.generation_complete:
        return null
    
    var idx: int = lx + ly * map_width
    target_chunk.cells[idx] = val
    target_chunk.set_tileset_tile(Vector2i(lx, ly), val)
    return target_chunk

func _set_world_cell_cached(world_x: int, world_y: int, val: int) -> Chunk:
    # Fast path: check if in this chunk first
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    
    if local_x >= 0 and local_x < map_width and local_y >= 0 and local_y < map_height:
        var idx: int = local_x + local_y * map_width
        cells[idx] = val
        set_tileset_tile(Vector2i(local_x, local_y), val)
        return self
    
    # Use neighbor cache
    _ensure_neighbor_cache()
    
    var dx: int = 0
    var dy: int = 0
    var adj_local_x: int = local_x
    var adj_local_y: int = local_y
    
    if local_x < 0:
        dx = -1
        adj_local_x += map_width
    elif local_x >= map_width:
        dx = 1
        adj_local_x -= map_width
    
    if local_y < 0:
        dy = -1
        adj_local_y += map_height
    elif local_y >= map_height:
        dy = 1
        adj_local_y -= map_height
    
    var cache_idx: int = _get_neighbor_cache_index(dx, dy)
    var neighbor: Chunk = _neighbor_cache[cache_idx]
    
    if neighbor:
        var idx: int = adj_local_x + adj_local_y * map_width
        neighbor.cells[idx] = val
        neighbor.set_tileset_tile(Vector2i(adj_local_x, adj_local_y), val)
        return neighbor
    
    return null
    
func update_falling_materials(falling_mats_unused: Array[int], fall_speed: int = 1, diagonal: bool = false) -> void:
    _fall_dirty = false
    _ensure_neighbor_cache()
    
    var dirty_neighbors: Dictionary = {}
    var world_offset_x: int = _chunk_world_offset_x
    var world_offset_y: int = _chunk_world_offset_y
    var lookup_size: int = _falling_lookup.size()
    
    for _step: int in fall_speed:
        var moved_this_step: bool = false
        
        for y: int in range(map_height - 1, -1, -1):
            for x: int in map_width:
                var idx: int = x + y * map_width
                var current_mat: int = cells[idx]
                
                # Fast lookup table check
                if current_mat == 0 or current_mat >= lookup_size or _falling_lookup[current_mat] == 0:
                    continue
                
                var wx: int = world_offset_x + x
                var wy: int = world_offset_y + y
                var below_val: int = _get_world_cell_cached(wx, wy + 1)
                
                if below_val == 0:
                    cells[idx] = 0
                    set_tileset_tile(Vector2i(x, y), 0)
                    
                    var dest_chunk: Chunk = _set_world_cell_cached(wx, wy + 1, current_mat)
                    if dest_chunk and dest_chunk != self:
                        dirty_neighbors[dest_chunk.chunk_pos] = dest_chunk
                    
                    moved_this_step = true
                elif diagonal and below_val > 0:
                    if _try_diagonal_fall_cached(wx, wy, x, y, idx, current_mat, dirty_neighbors):
                        moved_this_step = true
        
        if not moved_this_step:
            break
        _fall_dirty = true
    
    if _fall_dirty and chunk_parent:
        var above_chunk: Chunk = chunk_parent._chunk_lookup.get(chunk_pos + Vector2i(0, -1))
        if above_chunk and above_chunk.generation_complete:
            above_chunk.needs_fall_update = true
    
    for cpos: Vector2i in dirty_neighbors:
        var c: Chunk = dirty_neighbors[cpos]
        c.needs_fall_update = true
        c._fall_dirty = true
    
    needs_fall_update = _fall_dirty

func _try_diagonal_fall_cached(wx: int, wy: int, local_x: int, local_y: int, idx: int, mat_type: int, dirty_neighbors: Dictionary) -> bool:
    var first_dir: int = -1 if randf() > 0.5 else 1
    var second_dir: int = -first_dir
    
    for i: int in 2:
        var dx: int = first_dir if i == 0 else second_dir
        var target_wx: int = wx + dx
        var target_wy: int = wy + 1
        
        if _get_world_cell_cached(target_wx, target_wy) != 0:
            continue
        
        if _get_world_cell_cached(target_wx, wy) != 0:
            continue
        
        cells[idx] = 0
        set_tileset_tile(Vector2i(local_x, local_y), 0)
        
        var dest_chunk: Chunk = _set_world_cell_cached(target_wx, target_wy, mat_type)
        if dest_chunk and dest_chunk != self:
            dirty_neighbors[dest_chunk.chunk_pos] = dest_chunk
        
        return true
    
    return false
    
func create_room(center: Vector2i, radius: int) -> void:
    var r_sq: int = radius * radius
    
    begin_batch_update()
    
    for x: int in range(-radius, radius + 1):
        for y: int in range(-radius, radius + 1):
            var local_pos: Vector2i = Vector2i(center.x + x, center.y + y)
            if local_pos.x >= 0 and local_pos.x < map_width and \
               local_pos.y >= 0 and local_pos.y < map_height:
                if x * x + y * y <= r_sq:
                    var index: int = pos_to_cell_index(local_pos)
                    cells[index] = 0
                    set_tileset_tile(local_pos, 0)
    
    end_batch_update()
    needs_fall_update = true

func reset_for_reuse() -> void:
    generation_complete = false
    needs_fall_update = false
    _fall_dirty = false
    _neighbor_cache_valid = false
    cells.clear()
    _pending_tile_positions.clear()
    _pending_tile_values.clear()
