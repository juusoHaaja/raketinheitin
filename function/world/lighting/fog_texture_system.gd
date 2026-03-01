# world/lighting/fog_texture_system.gd
# FogTextureSystem: per-chunk fog images and textures.
# Each chunk has one fog Image (e.g. 8x8, one pixel per tile) and one ImageTexture.
# Separates "explored" (permanently revealed) from "visible" (currently lit).
# Explored areas surrounded on all sides auto-discover interior tiles.
# API: get_or_create_fog(), update_fog(), get_texture().
class_name FogTextureSystem
extends RefCounted

const FOG_SIZE := 16

# Light/visibility radii in tile units
const LIGHT_RADIUS_TILES := 48
const LIGHT_INNER_RADIUS_TILES := 4
const LIGHT_FULL_BRIGHT_RADIUS := 2

# How bright explored-but-not-visible areas appear (0 = black, 1 = full)
const EXPLORED_BRIGHTNESS := 0.55
# How bright the falloff edge of explored areas gets
const EXPLORED_EDGE_BRIGHTNESS := 0.30
# Number of tiles for the explored-area edge falloff
const EXPLORED_FALLOFF_TILES := 3

# Flood-fill: how many neighbor tiles must be explored to auto-discover a tile
const FLOOD_FILL_NEIGHBOR_THRESHOLD := 4  # out of 8 neighbors

# chunk_pos key -> { "image": Image, "texture": ImageTexture, "explored": PackedFloat32Array, "visible": PackedFloat32Array }
var _chunk_fog: Dictionary = {}

# Precomputed light stamp
var _light_stamp: PackedFloat32Array
var _light_stamp_size: int

# -- Extra lights (projectiles, explosions, etc.) --

var _extra_lights: Array[Dictionary] = []

func clear_extra_lights() -> void:
    _extra_lights.clear()

func add_extra_light(tile_pos: Vector2i, radius_tiles: float, intensity: float) -> void:
    _extra_lights.append({
        "tile_pos": tile_pos,
        "radius": radius_tiles,
        "intensity": intensity,
    })

func get_extra_lights() -> Array[Dictionary]:
    return _extra_lights

func _init() -> void:
    _create_light_stamp()

# -- Light stamp creation with smooth hermite falloff --

func _create_light_stamp() -> void:
    _light_stamp_size = LIGHT_RADIUS_TILES * 2 + 1
    _light_stamp = PackedFloat32Array()
    _light_stamp.resize(_light_stamp_size * _light_stamp_size)
    var center := float(LIGHT_RADIUS_TILES)
    for y in _light_stamp_size:
        for x in _light_stamp_size:
            var d := Vector2(x, y).distance_to(Vector2(center, center))
            var value: float
            if d <= LIGHT_FULL_BRIGHT_RADIUS:
                value = 1.0
            elif d <= LIGHT_INNER_RADIUS_TILES:
                # Gentle falloff from full bright to main light level
                var t := (d - LIGHT_FULL_BRIGHT_RADIUS) / float(LIGHT_INNER_RADIUS_TILES - LIGHT_FULL_BRIGHT_RADIUS)
                t = _smoothstep(t)
                value = lerpf(1.0, 0.92, t)
            elif d >= LIGHT_RADIUS_TILES:
                value = 0.0
            else:
                # Smooth falloff from light to nothing
                var t := (d - LIGHT_INNER_RADIUS_TILES) / float(LIGHT_RADIUS_TILES - LIGHT_INNER_RADIUS_TILES)
                t = _smootherstep(t)
                value = lerpf(0.92, 0.0, t)
            _light_stamp[y * _light_stamp_size + x] = value

## Attempt at Ken Perlin's smootherstep (6t^5 - 15t^4 + 10t^3)
func _smootherstep(t: float) -> float:
    t = clampf(t, 0.0, 1.0)
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

func _smoothstep(t: float) -> float:
    t = clampf(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)

# -- Chunk key helper --

func _chunk_key(pos: Vector2i) -> String:
    return "%d,%d" % [pos.x, pos.y]

# -- Create / access fog data --

func get_or_create_fog(chunk_pos: Vector2i, _map_width: int, _map_height: int) -> Dictionary:
    var key := _chunk_key(chunk_pos)
    if _chunk_fog.has(key):
        return _chunk_fog[key]
    var img := Image.create(FOG_SIZE, FOG_SIZE, false, Image.FORMAT_RGBA8)
    img.fill(Color(0, 0, 0, 1))
    var tex := ImageTexture.create_from_image(img)
    var explored := PackedFloat32Array()
    explored.resize(FOG_SIZE * FOG_SIZE)
    explored.fill(0.0)
    var visible := PackedFloat32Array()
    visible.resize(FOG_SIZE * FOG_SIZE)
    visible.fill(0.0)
    _chunk_fog[key] = {
        "image": img,
        "texture": tex,
        "explored": explored,
        "visible": visible,
    }
    return _chunk_fog[key]

# -- Main update: stamp visibility, update explored, flood-fill, compose final image --

func update_fog(chunk_pos: Vector2i, local_tile_x: int, local_tile_y: int, map_width: int, map_height: int) -> void:
    var data := get_or_create_fog(chunk_pos, map_width, map_height)
    var visible: PackedFloat32Array = data.visible
    var explored: PackedFloat32Array = data.explored

    # 1) Clear current visibility
    visible.fill(0.0)

    # 2) Stamp the player light onto visibility
    var ox := local_tile_x - LIGHT_RADIUS_TILES
    var oy := local_tile_y - LIGHT_RADIUS_TILES
    for ly in _light_stamp_size:
        var fy := oy + ly
        if fy < 0 or fy >= FOG_SIZE:
            continue
        var fog_row := fy * FOG_SIZE
        var light_row := ly * _light_stamp_size
        for lx in _light_stamp_size:
            var fx := ox + lx
            if fx < 0 or fx >= FOG_SIZE:
                continue
            var idx := fog_row + fx
            var stamp_val := _light_stamp[light_row + lx]
            if stamp_val > visible[idx]:
                visible[idx] = stamp_val

    # 2b) Stamp extra lights (projectiles, explosions)
    for light in _extra_lights:
        _stamp_extra_light(chunk_pos, visible, light["tile_pos"], light["radius"], light["intensity"])

    # 3) Update explored: explored = max(explored, visible)
    for i in FOG_SIZE * FOG_SIZE:
        if visible[i] > explored[i]:
            explored[i] = visible[i]

    # 4) Flood-fill discovery
    _flood_fill_enclosed(explored)

    # 5) Apply explored falloff
    var explored_with_falloff := _apply_explored_falloff(explored)

    # 6) Compose final fog image
    _compose_fog_image(data.image, visible, explored_with_falloff)

    # 7) Upload to GPU
    data.texture.update(data.image)

func _stamp_extra_light(chunk_pos: Vector2i, visible: PackedFloat32Array, light_tile: Vector2i, radius: float, intensity: float) -> void:
    # Convert global tile position to local tile coordinates relative to this chunk
    var chunk_origin_tile := Vector2i(chunk_pos.x * FOG_SIZE, chunk_pos.y * FOG_SIZE)
    var local_x := light_tile.x - chunk_origin_tile.x
    var local_y := light_tile.y - chunk_origin_tile.y

    var r_int := int(ceil(radius))
    for dy in range(-r_int, r_int + 1):
        var fy := local_y + dy
        if fy < 0 or fy >= FOG_SIZE:
            continue
        for dx in range(-r_int, r_int + 1):
            var fx := local_x + dx
            if fx < 0 or fx >= FOG_SIZE:
                continue
            var dist := sqrt(float(dx * dx + dy * dy))
            if dist > radius:
                continue
            var t := dist / radius
            t = _smootherstep(t)
            var val := lerpf(intensity, 0.0, t)
            var idx := fy * FOG_SIZE + fx
            if val > visible[idx]:
                visible[idx] = val

# -- Flood-fill: discover tiles that are enclosed by explored tiles --

func _flood_fill_enclosed(explored: PackedFloat32Array) -> void:
    # Mark tiles as explored if enough neighbors are explored.
    # Run multiple passes until stable.
    var changed := true
    var max_passes := 4
    var pass_count := 0
    while changed and pass_count < max_passes:
        changed = false
        pass_count += 1
        for y in range(1, FOG_SIZE - 1):
            var row := y * FOG_SIZE
            for x in range(1, FOG_SIZE - 1):
                var idx := row + x
                if explored[idx] >= EXPLORED_BRIGHTNESS:
                    continue
                # Count explored neighbors (8-connected)
                var count := 0
                var neighbor_sum := 0.0
                for dy in range(-1, 2):
                    for dx in range(-1, 2):
                        if dx == 0 and dy == 0:
                            continue
                        var ni := (y + dy) * FOG_SIZE + (x + dx)
                        var nv := explored[ni]
                        if nv >= EXPLORED_BRIGHTNESS:
                            count += 1
                            neighbor_sum += nv
                if count >= FLOOD_FILL_NEIGHBOR_THRESHOLD:
                    # Auto-discover with the average brightness of neighbors
                    var avg := neighbor_sum / float(count)
                    var new_val := minf(avg, EXPLORED_BRIGHTNESS)
                    if new_val > explored[idx]:
                        explored[idx] = new_val
                        changed = true

# -- Explored falloff: create a smoothed version of explored for edge softening --

func _apply_explored_falloff(explored: PackedFloat32Array) -> PackedFloat32Array:
    # We create a distance-based falloff from explored edges.
    # First compute a distance field from unexplored to explored,
    # then use it to create soft edges.
    var result := explored.duplicate()

    # Multiple blur passes to soften edges
    for pass_i in EXPLORED_FALLOFF_TILES:
        var temp := result.duplicate()
        for y in FOG_SIZE:
            var row := y * FOG_SIZE
            for x in FOG_SIZE:
                var idx := row + x
                if result[idx] >= EXPLORED_BRIGHTNESS:
                    continue
                # Sample neighbors and spread explored values with falloff
                var max_neighbor := 0.0
                for dy in range(-1, 2):
                    var ny := y + dy
                    if ny < 0 or ny >= FOG_SIZE:
                        continue
                    for dx in range(-1, 2):
                        if dx == 0 and dy == 0:
                            continue
                        var nx := x + dx
                        if nx < 0 or nx >= FOG_SIZE:
                            continue
                        var nv := result[ny * FOG_SIZE + nx]
                        # Diagonal neighbors contribute less
                        var weight: float
                        if dx != 0 and dy != 0:
                            weight = 0.6
                        else:
                            weight = 0.75
                        var contributed := nv * weight
                        if contributed > max_neighbor:
                            max_neighbor = contributed
                # Only spread if neighbor value would give us meaningful brightness
                if max_neighbor > temp[idx] and max_neighbor > EXPLORED_EDGE_BRIGHTNESS * 0.3:
                    temp[idx] = max_neighbor
                # Clamp falloff so it doesn't exceed explored brightness
                if temp[idx] > EXPLORED_BRIGHTNESS:
                    temp[idx] = EXPLORED_BRIGHTNESS
        result = temp

    return result

# -- Compose final fog image from visibility and explored data --

func _compose_fog_image(img: Image, visible: PackedFloat32Array, explored_falloff: PackedFloat32Array) -> void:
    for y in FOG_SIZE:
        var row := y * FOG_SIZE
        for x in FOG_SIZE:
            var idx := row + x
            var vis := visible[idx]
            var exp_val := explored_falloff[idx]

            # Final brightness: max of current visibility and explored level
            # Visible areas are fully bright, explored areas are dimmer
            var brightness: float
            if vis > 0.0:
                # Currently visible: use visibility value directly
                # But ensure explored areas at least show at explored brightness
                var explored_contrib := exp_val * EXPLORED_BRIGHTNESS
                brightness = maxf(vis, explored_contrib)
            else:
                # Not visible: show explored areas at reduced brightness with falloff
                brightness = exp_val * EXPLORED_BRIGHTNESS
                # Apply additional smoothstep to make the transition cleaner
                if brightness > 0.0 and brightness < EXPLORED_BRIGHTNESS * 0.9:
                    var t := brightness / (EXPLORED_BRIGHTNESS * 0.9)
                    t = _smoothstep(t)
                    brightness = t * EXPLORED_BRIGHTNESS * 0.9

            brightness = clampf(brightness, 0.0, 1.0)
            img.set_pixel(x, y, Color(brightness, brightness, brightness, 1.0))

func get_texture(chunk_pos: Vector2i) -> ImageTexture:
    var key := _chunk_key(chunk_pos)
    var data = _chunk_fog.get(key)
    if data == null:
        return null
    return data.texture as ImageTexture

func has_fog(chunk_pos: Vector2i) -> bool:
    return _chunk_fog.has(_chunk_key(chunk_pos))
