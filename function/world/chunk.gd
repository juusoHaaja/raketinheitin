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
var _material_counts: PackedInt32Array  # Reused in _get_dominant_neighbor_material (size 16)

# Cache for tileset coordinates to avoid repeated calculations
var _tileset_coords_cache: Array[Vector2i] = []

# Falling material lookup table for O(1) checks
var _falling_lookup: PackedByteArray = PackedByteArray()

# Neighbor chunk cache for cross-chunk operations
var _neighbor_cache: Array[Chunk] = []
var _neighbor_cache_valid: bool = false

# Batched tile updates (used by create_room etc.)
var _batch_mode: bool = false
var _pending_tile_positions: PackedInt32Array = PackedInt32Array()
var _pending_tile_values: PackedByteArray = PackedByteArray()

# Lazy TileMap updates: defer visual updates until flush
var _tilemap_dirty: bool = false
var _dirty_tile_indices: PackedInt32Array = PackedInt32Array()  # indices to refresh (duplicates OK; sorted+unique in flush)
const _DIRTY_FULL_REBUILD_THRESHOLD: int = 128  # Use update_cells() when more tiles changed

# Precomputed values
var _map_size: int = 0
var _chunk_world_offset_x: int = 0
var _chunk_world_offset_y: int = 0

# Reusable array for falling neighbor tracking (at most 8 neighbors; linear search beats dict)
var _fall_dirty_neighbor_list: Array[Chunk] = []

# Dirty column tracking: only process columns that were modified for fall simulation
var _dirty_columns: int = 0  # Bitmask for chunks up to 64 wide
var _dirty_columns_array: PackedByteArray = PackedByteArray()  # For wider chunks

# Island detection for converting small isolated falling blocks to particles
var _island_check_visited: PackedByteArray = PackedByteArray()
var _island_positions: Array[Vector2i] = []

# Fog of war: each chunk has its own overlay sprite (texture set by FogOfWar/FogTextureSystem)
var fog_overlay: Sprite2D = null

func _ready() -> void:
    tileset_count = tileset_width * tileset_height
    tile_pixel_size = int(scale.x * tile_set.tile_size.x)
    _map_size = map_width * map_height

    # Pre-allocate buffers once; reused in generate() with fill(0)
    _temp_solid = PackedByteArray()
    _temp_material = PackedByteArray()
    _smooth_buffer = PackedByteArray()
    _temp_solid.resize(_map_size)
    _temp_material.resize(_map_size)
    _smooth_buffer.resize(_map_size)

    # Pre-calculate tileset coordinates
    _tileset_coords_cache.resize(tileset_count)
    for idx: int in tileset_count:
        _tileset_coords_cache[idx] = Vector2i(idx % tileset_width, idx / tileset_width)

    _dirty_columns_array.resize(map_width)
    _dirty_columns_array.fill(0)

    _material_counts.resize(16)
    _material_counts.fill(0)

    _island_check_visited.resize(_map_size)

## Call from FogOfWar only for visible chunks; avoids creating overlay for off-screen chunks.
func create_fog_overlay_if_needed() -> void:
    if fog_overlay != null:
        return
    _create_fog_overlay()

func _create_fog_overlay() -> void:
    fog_overlay = Sprite2D.new()
    fog_overlay.name = "FogOverlay"
    fog_overlay.position = Vector2.ZERO
    fog_overlay.centered = false
    fog_overlay.z_index = 10
    # Scale so FOG_SIZE x FOG_SIZE texture covers the chunk in pixels
    var fog_size := 16
    var sx := float(map_width * tile_pixel_size) / float(fog_size)
    var sy := float(map_height * tile_pixel_size) / float(fog_size)
    fog_overlay.scale = Vector2(sx, sy)
    # Multiply blend so black = dark, white = visible
    var mat := CanvasItemMaterial.new()
    mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
    fog_overlay.material = mat
    # Hidden until FogOfWar assigns per-chunk texture (avoids visible pop from placeholder)
    fog_overlay.visible = false
    add_child(fog_overlay)

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

func mark_column_dirty(x: int) -> void:
    if map_width <= 64:
        _dirty_columns |= (1 << x)
    else:
        _dirty_columns_array[x] = 1
    needs_fall_update = true

func clear_dirty_columns() -> void:
    _dirty_columns = 0
    _dirty_columns_array.fill(0)

func is_column_dirty(x: int) -> bool:
    if map_width <= 64:
        return (_dirty_columns & (1 << x)) != 0
    return _dirty_columns_array[x] != 0

func _has_any_dirty_columns() -> bool:
    if map_width <= 64:
        return _dirty_columns != 0
    for i in map_width:
        if _dirty_columns_array[i] != 0:
            return true
    return false

func _update_world_offset() -> void:
    _chunk_world_offset_x = chunk_pos.x * map_width
    _chunk_world_offset_y = chunk_pos.y * map_height

func _invalidate_neighbor_cache() -> void:
    _neighbor_cache_valid = false

func _ensure_neighbor_cache() -> void:
    if _neighbor_cache_valid:
        return
    
    _neighbor_cache.resize(9)
    var idx: int = 0
    for i: int in 9:
        _neighbor_cache[i] = null
    
    if not chunk_parent:
        _neighbor_cache_valid = true
        return
    
    idx = 0
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
    set_tileset_tile_xy(index % map_width, index / map_width, val)

func global_to_grid(pos: Vector2) -> Vector2i:
    var tile_size: float = tile_set.tile_size.x
    return Vector2i(floori(pos.x / tile_size), floori(pos.y / tile_size))

func set_tileset_tile(pos: Vector2i, b: int) -> void:
    set_tileset_tile_xy(pos.x, pos.y, b)

func set_tileset_tile_xy(pos_x: int, pos_y: int, b: int) -> void:
    var idx: int = pos_x + pos_y * map_width
    if _batch_mode:
        _pending_tile_positions.append(idx)
        _pending_tile_values.append(b)
        return

    # Lazy update: record dirty, defer visual to flush
    _dirty_tile_indices.append(idx)
    if not _tilemap_dirty:
        _tilemap_dirty = true
        if chunk_parent:
            chunk_parent._register_chunk_for_tilemap_flush(self)

func destroy_tiles_batch(positions: Array) -> void:
    if positions.is_empty():
        return

    var w: int = map_width
    var any_changed: bool = false

    begin_batch_update()

    for pos in positions:
        var local_pos: Vector2i = pos as Vector2i
        var idx: int = local_pos.x + local_pos.y * w

        if cells[idx] != 0:
            cells[idx] = 0
            set_tileset_tile_xy(local_pos.x, local_pos.y, 0)
            mark_column_dirty(local_pos.x)
            if local_pos.x > 0:
                mark_column_dirty(local_pos.x - 1)
            if local_pos.x < w - 1:
                mark_column_dirty(local_pos.x + 1)
            any_changed = true

    end_batch_update()

    if any_changed and chunk_parent:
        chunk_parent._register_chunk_for_fall_update(self)
        var above: Chunk = chunk_parent._chunk_lookup.get(chunk_pos + Vector2i(0, -1))
        if above:
            above.needs_fall_update = true
            chunk_parent._register_chunk_for_fall_update(above)

func begin_batch_update() -> void:
    _batch_mode = true
    _pending_tile_positions.clear()
    _pending_tile_values.clear()

func end_batch_update() -> void:
    _batch_mode = false
    var count: int = _pending_tile_positions.size()
    var i: int = 0
    var idx: int
    while i < count:
        idx = _pending_tile_positions[i]
        _dirty_tile_indices.append(idx)
        i += 1
    _pending_tile_positions.clear()
    _pending_tile_values.clear()
    if not _tilemap_dirty:
        _tilemap_dirty = true
        if chunk_parent:
            chunk_parent._register_chunk_for_tilemap_flush(self)

func update_cells() -> void:
    clear()
    var w: int = map_width
    var i: int = 0
    var val: int
    while i < _map_size:
        val = cells[i]
        if val != 0:
            var ti: int = (val - 1) % tileset_count
            @warning_ignore("integer_division")
            set_cell(Vector2i(i % w, i / w), 0, _tileset_coords_cache[ti], 0)
        i += 1
    _dirty_tile_indices.clear()
    _tilemap_dirty = false

func flush_tilemap_visuals() -> void:
    if not _tilemap_dirty:
        return
    var dirty_count: int = _dirty_tile_indices.size()
    if dirty_count >= _DIRTY_FULL_REBUILD_THRESHOLD:
        update_cells()
        return
    var w: int = map_width
    var px: int
    var py: int
    var val: int
    var ti: int
    var idx: int
    var prev_idx: int = -1
    _dirty_tile_indices.sort()
    for i in _dirty_tile_indices.size():
        idx = _dirty_tile_indices[i]
        if idx == prev_idx:
            continue
        prev_idx = idx
        @warning_ignore("integer_division")
        px = idx % w
        @warning_ignore("integer_division")
        py = idx / w
        val = cells[idx]
        if val == 0:
            erase_cell(Vector2i(px, py))
        else:
            ti = (val - 1) % tileset_count
            set_cell(Vector2i(px, py), 0, _tileset_coords_cache[ti], 0)
    _dirty_tile_indices.clear()
    _tilemap_dirty = false

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

## Initialize chunk with pre-generated data from GPU
func init_from_gpu_data(pos: Vector2i, gpu_cells: PackedByteArray) -> void:
    chunk_pos = pos
    _update_world_offset()

    if tileset_count == 0:
        tileset_count = tileset_width * tileset_height
    if tile_pixel_size == 0:
        tile_pixel_size = int(scale.x * tile_set.tile_size.x)

    _map_size = map_width * map_height
    global_position = Vector2(pos * chunk_size * tile_pixel_size)

    cells = gpu_cells

    _init_falling_lookup()

    update_cells()

    generation_complete = true
    _invalidate_neighbor_cache()

func generate() -> void:
    generation_complete = false
    _temp_solid.fill(0)
    _temp_material.fill(0)
    _smooth_buffer.fill(0)

    _initialize_cave_map()

    var iteration: int = 0
    while iteration < smoothing_iterations:
        _smooth_map()
        iteration += 1

    _apply_cave_to_cells()
    generation_complete = true
    _invalidate_neighbor_cache()

func _initialize_cave_map() -> void:
    var threshold: float = (fill_percent - 50.0) / 50.0 * 0.5
    var noise: FastNoiseLite = chunk_parent.cave_noise
    var offset_x: int = _chunk_world_offset_x
    var offset_y: int = _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height
    
    var index: int = 0
    var y: int = 0
    var x: int
    var wy: int
    var wx: int
    var cave_val: float
    
    while y < h:
        wy = offset_y + y
        x = 0
        while x < w:
            wx = offset_x + x
            cave_val = noise.get_noise_2d(wx, wy)

            if cave_val > threshold:
                _temp_solid[index] = 1
                _temp_material[index] = chunk_parent._get_material_at_coords(wx, wy)
            else:
                _temp_solid[index] = 0
                _temp_material[index] = 0
            index += 1
            x += 1
        y += 1

func _smooth_map() -> void:
    var offset_x: int = _chunk_world_offset_x
    var offset_y: int = _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height

    var index: int = 0
    var y: int = 0
    var x: int
    var wy: int
    var wx: int
    var wall_count: int
    var current_solid: int
    
    while y < h:
        wy = offset_y + y
        x = 0
        while x < w:
            wx = offset_x + x
            wall_count = _count_neighbors_fast(x, y, wx, wy, w, h)
            current_solid = _temp_solid[index]

            if wall_count > 4:
                _smooth_buffer[index] = 1
                if current_solid == 0:
                    _temp_material[index] = _get_dominant_neighbor_material(x, y, wx, wy, w, h)
            elif wall_count < 4:
                _smooth_buffer[index] = 0
                _temp_material[index] = 0
            else:
                _smooth_buffer[index] = current_solid
            index += 1
            x += 1
        y += 1

    # Swap buffers
    var tmp: PackedByteArray = _temp_solid
    _temp_solid = _smooth_buffer
    _smooth_buffer = tmp

func _count_neighbors_fast(x: int, y: int, wx: int, wy: int, w: int, h: int) -> int:
    var count: int = 0
    var ny: int
    var nx: int
    var dy: int = -1
    while dy <= 1:
        ny = y + dy
        var dx: int = -1
        while dx <= 1:
            if dx == 0 and dy == 0:
                dx += 1
                continue
            nx = x + dx
            if nx >= 0 and nx < w and ny >= 0 and ny < h:
                count += _temp_solid[nx + ny * w]
            elif chunk_parent._is_solid_at_coords(wx + dx, wy + dy):
                count += 1
            dx += 1
        dy += 1
    return count

func _get_dominant_neighbor_material(x: int, y: int, wx: int, wy: int, w: int, h: int) -> int:
    var best_mat: int = 1
    var best_count: int = 0
    if _material_counts.size() < 16:
        _material_counts.resize(16)
    _material_counts.fill(0)

    var dx: int
    var dy: int
    var nx: int
    var ny: int
    var nwx: int
    var nwy: int
    var val: int
    var ni: int

    dy = -1
    while dy <= 1:
        ny = y + dy
        nwy = wy + dy
        dx = -1
        while dx <= 1:
            if dx == 0 and dy == 0:
                dx += 1
                continue
            
            nx = x + dx
            nwx = wx + dx
            val = 0

            if nx >= 0 and nx < w and ny >= 0 and ny < h:
                ni = nx + ny * w
                if _temp_solid[ni] != 0:
                    val = _temp_material[ni]
            else:
                if chunk_parent._is_solid_at_coords(nwx, nwy):
                    val = chunk_parent._get_material_at_coords(nwx, nwy)

            if val > 0 and val < 16:
                _material_counts[val] += 1
                if _material_counts[val] > best_count:
                    best_count = _material_counts[val]
                    best_mat = val
            dx += 1
        dy += 1

    return best_mat

func _apply_cave_to_cells() -> void:
    var i: int = 0
    while i < _map_size:
        if _temp_solid[i] != 0:
            cells[i] = _temp_material[i]
        else:
            cells[i] = 0
        i += 1

    update_cells()

func _get_world_cell(world_x: int, world_y: int) -> int:
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height
    
    if local_x >= 0 and local_x < w and local_y >= 0 and local_y < h:
        return cells[local_x + local_y * w]
    
    @warning_ignore("integer_division")
    var cx: int = world_x / w if world_x >= 0 else (world_x - w + 1) / w
    @warning_ignore("integer_division")
    var cy: int = world_y / h if world_y >= 0 else (world_y - h + 1) / h
    
    var lx: int = world_x - cx * w
    var ly: int = world_y - cy * h
    
    if not chunk_parent:
        return -1
    
    var target_chunk: Chunk = chunk_parent._chunk_lookup.get(Vector2i(cx, cy))
    if not target_chunk or not target_chunk.generation_complete:
        return -1
    
    return target_chunk.cells[lx + ly * w]

func _get_world_cell_cached(world_x: int, world_y: int) -> int:
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height
    
    if local_x >= 0 and local_x < w and local_y >= 0 and local_y < h:
        return cells[local_x + local_y * w]
    
    _ensure_neighbor_cache()
    
    var dx: int = 0
    var dy: int = 0
    
    if local_x < 0:
        dx = -1
        local_x += w
    elif local_x >= w:
        dx = 1
        local_x -= w
    
    if local_y < 0:
        dy = -1
        local_y += h
    elif local_y >= h:
        dy = 1
        local_y -= h
    
    var cache_idx: int = (dy + 1) * 3 + (dx + 1)
    var neighbor: Chunk = _neighbor_cache[cache_idx]
    
    if neighbor:
        return neighbor.cells[local_x + local_y * w]
    
    return -1

func _set_world_cell(world_x: int, world_y: int, val: int) -> Chunk:
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height
    
    if local_x >= 0 and local_x < w and local_y >= 0 and local_y < h:
        var idx: int = local_x + local_y * w
        cells[idx] = val
        set_tileset_tile_xy(local_x, local_y, val)
        return self
    
    @warning_ignore("integer_division")
    var cx: int = world_x / w if world_x >= 0 else (world_x - w + 1) / w
    @warning_ignore("integer_division")
    var cy: int = world_y / h if world_y >= 0 else (world_y - h + 1) / h
    
    var lx: int = world_x - cx * w
    var ly: int = world_y - cy * h
    
    if not chunk_parent:
        return null
    
    var target_chunk: Chunk = chunk_parent._chunk_lookup.get(Vector2i(cx, cy))
    if not target_chunk or not target_chunk.generation_complete:
        return null
    
    var target_idx: int = lx + ly * w
    target_chunk.cells[target_idx] = val
    target_chunk.set_tileset_tile_xy(lx, ly, val)
    return target_chunk

func _set_world_cell_cached(world_x: int, world_y: int, val: int) -> Chunk:
    var local_x: int = world_x - _chunk_world_offset_x
    var local_y: int = world_y - _chunk_world_offset_y
    var w: int = map_width
    var h: int = map_height
    
    if local_x >= 0 and local_x < w and local_y >= 0 and local_y < h:
        var idx: int = local_x + local_y * w
        cells[idx] = val
        set_tileset_tile_xy(local_x, local_y, val)
        return self
    
    _ensure_neighbor_cache()
    
    var dx: int = 0
    var dy: int = 0
    var adj_local_x: int = local_x
    var adj_local_y: int = local_y
    
    if local_x < 0:
        dx = -1
        adj_local_x += w
    elif local_x >= w:
        dx = 1
        adj_local_x -= w
    
    if local_y < 0:
        dy = -1
        adj_local_y += h
    elif local_y >= h:
        dy = 1
        adj_local_y -= h
    
    var cache_idx: int = (dy + 1) * 3 + (dx + 1)
    var neighbor: Chunk = _neighbor_cache[cache_idx]
    
    if neighbor:
        var idx: int = adj_local_x + adj_local_y * w
        neighbor.cells[idx] = val
        neighbor.set_tileset_tile_xy(adj_local_x, adj_local_y, val)
        return neighbor
    
    return null

func update_falling_materials(_falling_mats_unused: Array[int], fall_speed: int = 1, diagonal: bool = false) -> void:
    _fall_dirty = false
    _ensure_neighbor_cache()
    _fall_dirty_neighbor_list.clear()
    
    var world_offset_x: int = _chunk_world_offset_x
    var world_offset_y: int = _chunk_world_offset_y
    var lookup_size: int = _falling_lookup.size()
    var w: int = map_width
    var h: int = map_height
    
    var step: int
    var y: int
    var x: int
    var idx: int
    var current_mat: int
    var wx: int
    var wy: int
    var below_val: int
    var dest_chunk: Chunk
    var moved_this_step: bool
    
    step = 0
    while step < fall_speed:
        moved_this_step = false
        
        y = h - 1
        while y >= 0:
            x = 0
            while x < w:
                idx = x + y * w
                current_mat = cells[idx]
                
                if current_mat == 0 or current_mat >= lookup_size or _falling_lookup[current_mat] == 0:
                    x += 1
                    continue
                
                wx = world_offset_x + x
                wy = world_offset_y + y
                below_val = _get_world_cell_cached(wx, wy + 1)
                
                if below_val == 0:
                    cells[idx] = 0
                    set_tileset_tile_xy(x, y, 0)
                    
                    dest_chunk = _set_world_cell_cached(wx, wy + 1, current_mat)
                    if dest_chunk and dest_chunk != self and dest_chunk not in _fall_dirty_neighbor_list:
                        _fall_dirty_neighbor_list.append(dest_chunk)
                    
                    moved_this_step = true
                elif diagonal and below_val > 0:
                    if _try_diagonal_fall(wx, wy, x, y, idx, current_mat):
                        moved_this_step = true
                
                x += 1
            y -= 1
        
        if not moved_this_step:
            break
        _fall_dirty = true
        step += 1
    
    if _fall_dirty and chunk_parent:
        var above_chunk: Chunk = chunk_parent._chunk_lookup.get(chunk_pos + Vector2i(0, -1))
        if above_chunk and above_chunk.generation_complete:
            above_chunk.needs_fall_update = true
            chunk_parent._register_chunk_for_fall_update(above_chunk)
        chunk_parent._register_chunk_for_fall_update(self)
    
    for c: Chunk in _fall_dirty_neighbor_list:
        c.needs_fall_update = true
        c._fall_dirty = true
        chunk_parent._register_chunk_for_fall_update(c)
    
    needs_fall_update = _fall_dirty

func update_falling_materials_optimized(_falling_mats: Array[int], fall_speed: int = 1, diagonal: bool = false) -> void:
    if _dirty_columns == 0 and not _has_any_dirty_columns():
        if not needs_fall_update:
            return
        # needs_fall_update set without dirty columns (e.g. create_room); mark all columns for one run
        for x in map_width:
            mark_column_dirty(x)

    _fall_dirty = false
    _ensure_neighbor_cache()
    _fall_dirty_neighbor_list.clear()

    var world_offset_x: int = _chunk_world_offset_x
    var world_offset_y: int = _chunk_world_offset_y
    var lookup_size: int = _falling_lookup.size()
    var w: int = map_width
    var h: int = map_height

    for step in fall_speed:
        var moved_this_step: bool = false

        for y in range(h - 1, -1, -1):
            for x in w:
                if not is_column_dirty(x):
                    continue

                var idx: int = x + y * w
                var current_mat: int = cells[idx]

                if current_mat == 0 or current_mat >= lookup_size or _falling_lookup[current_mat] == 0:
                    continue

                var wx: int = world_offset_x + x
                var wy: int = world_offset_y + y
                var below_val: int = _get_world_cell_cached(wx, wy + 1)

                if below_val == 0:
                    cells[idx] = 0
                    set_tileset_tile_xy(x, y, 0)

                    var dest_chunk: Chunk = _set_world_cell_cached(wx, wy + 1, current_mat)
                    if dest_chunk:
                        if dest_chunk != self:
                            var dest_local_x: int = wx - dest_chunk._chunk_world_offset_x
                            dest_chunk.mark_column_dirty(dest_local_x)
                            if dest_chunk not in _fall_dirty_neighbor_list:
                                _fall_dirty_neighbor_list.append(dest_chunk)
                        else:
                            mark_column_dirty(x)

                    moved_this_step = true
                elif diagonal and below_val > 0:
                    if _try_diagonal_fall_optimized(wx, wy, x, y, idx, current_mat):
                        moved_this_step = true

        if not moved_this_step:
            break
        _fall_dirty = true

    if _fall_dirty:
        _check_for_isolated_islands()

    if _fall_dirty and chunk_parent:
        var above_chunk: Chunk = chunk_parent._chunk_lookup.get(chunk_pos + Vector2i(0, -1))
        if above_chunk and above_chunk.generation_complete:
            for x in w:
                if is_column_dirty(x):
                    above_chunk.mark_column_dirty(x)
            above_chunk.needs_fall_update = true
            chunk_parent._register_chunk_for_fall_update(above_chunk)
        chunk_parent._register_chunk_for_fall_update(self)

    for c in _fall_dirty_neighbor_list:
        c.needs_fall_update = true
        c._fall_dirty = true
        if chunk_parent:
            chunk_parent._register_chunk_for_fall_update(c)

    if not _fall_dirty:
        clear_dirty_columns()

    needs_fall_update = _fall_dirty

func _check_for_isolated_islands() -> void:
    if not chunk_parent or not chunk_parent.particle_scene:
        return
    var lookup_size: int = _falling_lookup.size()
    var w: int = map_width
    var h: int = map_height
    _island_check_visited.fill(0)
    for y in h:
        for x in w:
            if not is_column_dirty(x):
                continue
            var idx: int = x + y * w
            if _island_check_visited[idx] != 0:
                continue
            var mat: int = cells[idx]
            if mat == 0 or mat >= lookup_size or _falling_lookup[mat] == 0:
                continue
            var wx: int = _chunk_world_offset_x + x
            var wy: int = _chunk_world_offset_y + y
            var below: int = _get_world_cell_cached(wx, wy + 1)
            if below != 0:
                continue
            _island_positions.clear()
            var island_size: int = _flood_fill_island(x, y, mat)
            if island_size >= chunk_parent.min_island_size_for_particles and island_size <= chunk_parent.max_island_size_for_particles:
                _convert_island_to_particles()

func _flood_fill_island(start_x: int, start_y: int, target_mat: int) -> int:
    var w: int = map_width
    var h: int = map_height
    var queue: Array[Vector2i] = [Vector2i(start_x, start_y)]
    var count: int = 0
    var max_count: int = chunk_parent.max_island_size_for_particles + 1 if chunk_parent else 999
    while queue.size() > 0 and count <= max_count:
        var pos: Vector2i = queue.pop_back()
        var idx: int = pos.x + pos.y * w
        if pos.x < 0 or pos.x >= w or pos.y < 0 or pos.y >= h:
            continue
        if _island_check_visited[idx] != 0:
            continue
        if cells[idx] != target_mat:
            continue
        _island_check_visited[idx] = 1
        _island_positions.append(pos)
        count += 1
        queue.append(Vector2i(pos.x + 1, pos.y))
        queue.append(Vector2i(pos.x - 1, pos.y))
        queue.append(Vector2i(pos.x, pos.y + 1))
        queue.append(Vector2i(pos.x, pos.y - 1))
    return count

func _convert_island_to_particles() -> void:
    if _island_positions.is_empty():
        return
    var w: int = map_width
    var mat_type: int = cells[_island_positions[0].x + _island_positions[0].y * w]
    for local_pos in _island_positions:
        var idx: int = local_pos.x + local_pos.y * w
        cells[idx] = 0
        set_tileset_tile_xy(local_pos.x, local_pos.y, 0)
        var world_pos: Vector2i = Vector2i(_chunk_world_offset_x + local_pos.x, _chunk_world_offset_y + local_pos.y)
        chunk_parent.spawn_falling_particle(world_pos, mat_type)
    _island_positions.clear()

func _try_diagonal_fall_optimized(wx: int, wy: int, local_x: int, local_y: int, idx: int, mat_type: int) -> bool:
    var first_dir: int = -1 if randf() > 0.5 else 1
    var target_wy: int = wy + 1

    var target_wx: int = wx + first_dir
    if _get_world_cell_cached(target_wx, target_wy) == 0 and _get_world_cell_cached(target_wx, wy) == 0:
        cells[idx] = 0
        set_tileset_tile_xy(local_x, local_y, 0)
        var dest_chunk: Chunk = _set_world_cell_cached(target_wx, target_wy, mat_type)
        if dest_chunk:
            var dest_local_x: int = target_wx - dest_chunk._chunk_world_offset_x
            dest_chunk.mark_column_dirty(dest_local_x)
            if dest_chunk != self and dest_chunk not in _fall_dirty_neighbor_list:
                _fall_dirty_neighbor_list.append(dest_chunk)
        return true

    target_wx = wx - first_dir
    if _get_world_cell_cached(target_wx, target_wy) == 0 and _get_world_cell_cached(target_wx, wy) == 0:
        cells[idx] = 0
        set_tileset_tile_xy(local_x, local_y, 0)
        var dest_chunk: Chunk = _set_world_cell_cached(target_wx, target_wy, mat_type)
        if dest_chunk:
            var dest_local_x: int = target_wx - dest_chunk._chunk_world_offset_x
            dest_chunk.mark_column_dirty(dest_local_x)
            if dest_chunk != self and dest_chunk not in _fall_dirty_neighbor_list:
                _fall_dirty_neighbor_list.append(dest_chunk)
        return true

    return false

func _try_diagonal_fall(wx: int, wy: int, local_x: int, local_y: int, idx: int, mat_type: int) -> bool:
    var first_dir: int = -1 if randf() > 0.5 else 1
    var target_wy: int = wy + 1
    var target_wx: int
    var dest_chunk: Chunk
    
    # Try first direction
    target_wx = wx + first_dir
    if _get_world_cell_cached(target_wx, target_wy) == 0 and _get_world_cell_cached(target_wx, wy) == 0:
        cells[idx] = 0
        set_tileset_tile_xy(local_x, local_y, 0)
        dest_chunk = _set_world_cell_cached(target_wx, target_wy, mat_type)
        if dest_chunk and dest_chunk != self and dest_chunk not in _fall_dirty_neighbor_list:
            _fall_dirty_neighbor_list.append(dest_chunk)
        return true
    
    # Try second direction
    target_wx = wx - first_dir
    if _get_world_cell_cached(target_wx, target_wy) == 0 and _get_world_cell_cached(target_wx, wy) == 0:
        cells[idx] = 0
        set_tileset_tile_xy(local_x, local_y, 0)
        dest_chunk = _set_world_cell_cached(target_wx, target_wy, mat_type)
        if dest_chunk and dest_chunk != self and dest_chunk not in _fall_dirty_neighbor_list:
            _fall_dirty_neighbor_list.append(dest_chunk)
        return true
    
    return false

func create_room(center: Vector2i, radius: int) -> void:
    var r_sq: int = radius * radius
    var w: int = map_width
    var h: int = map_height
    
    begin_batch_update()

    var x: int
    var y: int
    var lx: int
    var ly: int
    var index: int
    var col_min: int = maxi(0, center.x - radius)
    var col_max: int = mini(w - 1, center.x + radius)

    y = -radius
    while y <= radius:
        x = -radius
        while x <= radius:
            lx = center.x + x
            ly = center.y + y
            if lx >= 0 and lx < w and ly >= 0 and ly < h:
                if x * x + y * y <= r_sq:
                    index = lx + ly * w
                    cells[index] = 0
                    set_tileset_tile_xy(lx, ly, 0)
            x += 1
        y += 1

    end_batch_update()
    for col in range(col_min, col_max + 1):
        mark_column_dirty(col)
    needs_fall_update = true
    if chunk_parent:
        chunk_parent._register_chunk_for_fall_update(self)

func reset_for_reuse() -> void:
    generation_complete = false
    needs_fall_update = false
    _fall_dirty = false
    _neighbor_cache_valid = false
    _dirty_columns = 0
    if _dirty_columns_array.size() > 0:
        _dirty_columns_array.fill(0)
    cells.clear()
    _pending_tile_positions.clear()
    _pending_tile_values.clear()
    _fall_dirty_neighbor_list.clear()
    _tilemap_dirty = false
    _dirty_tile_indices.clear()
