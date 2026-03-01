# world/lighting/fog_texture_system.gd
# FogTextureSystem: per-chunk fog images and textures.
# Each chunk has one fog Image (e.g. 16x16, one pixel per tile) and one ImageTexture.
# Separates "explored" (permanently revealed) from "visible" (currently lit).
# Explored areas surrounded on all sides auto-discover interior tiles.
#
# Performance: all per-pixel work uses PackedByteArray bulk operations and
# single-pass loops to minimise GDScript overhead. The fog Image is written
# via a single set_data() call instead of per-pixel set_pixel().
class_name FogTextureSystem
extends RefCounted

const FOG_SIZE := 16
const FOG_PIXEL_COUNT := FOG_SIZE * FOG_SIZE  # 256

# Light/visibility radii in tile units
const LIGHT_RADIUS_TILES := 48
const LIGHT_INNER_RADIUS_TILES := 4
const LIGHT_FULL_BRIGHT_RADIUS := 2

# How bright explored-but-not-visible areas appear (0 = black, 1 = full).
const EXPLORED_BRIGHTNESS := 1.0
# How bright the falloff edge of explored areas gets
const EXPLORED_EDGE_BRIGHTNESS := 0.30
# Number of blur passes for explored-area edge falloff
const EXPLORED_FALLOFF_TILES := 3

# Flood-fill: how many neighbor tiles must be explored to auto-discover a tile
const FLOOD_FILL_NEIGHBOR_THRESHOLD := 4  # out of 8 neighbors

# chunk_pos Vector2i -> Dictionary { "image", "texture", "explored", "visible" }
var _chunk_fog: Dictionary = {}

# Precomputed light stamp – packed into a flat array for fast lookup
var _light_stamp: PackedFloat32Array
var _light_stamp_size: int

# -- Extra lights (projectiles, explosions, etc.) --
var _extra_lights: Array[Dictionary] = []

# Reusable scratch buffer for falloff computation (avoids alloc each frame)
var _falloff_scratch: PackedFloat32Array

# Reusable byte buffer for image composition (RGBA, 4 bytes per pixel)
var _compose_bytes: PackedByteArray

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
    # Pre-allocate scratch buffers
    _falloff_scratch = PackedFloat32Array()
    _falloff_scratch.resize(FOG_PIXEL_COUNT)
    _compose_bytes = PackedByteArray()
    _compose_bytes.resize(FOG_PIXEL_COUNT * 4)

# -- Light stamp creation with smooth hermite falloff --

func _create_light_stamp() -> void:
    _light_stamp_size = LIGHT_RADIUS_TILES * 2 + 1
    var total := _light_stamp_size * _light_stamp_size
    _light_stamp = PackedFloat32Array()
    _light_stamp.resize(total)
    var center := float(LIGHT_RADIUS_TILES)
    var inv_inner := 1.0 / float(LIGHT_INNER_RADIUS_TILES - LIGHT_FULL_BRIGHT_RADIUS) if LIGHT_INNER_RADIUS_TILES > LIGHT_FULL_BRIGHT_RADIUS else 1.0
    var inv_outer := 1.0 / float(LIGHT_RADIUS_TILES - LIGHT_INNER_RADIUS_TILES) if LIGHT_RADIUS_TILES > LIGHT_INNER_RADIUS_TILES else 1.0
    var fbr2 := float(LIGHT_FULL_BRIGHT_RADIUS * LIGHT_FULL_BRIGHT_RADIUS)
    var lrt2 := float(LIGHT_RADIUS_TILES * LIGHT_RADIUS_TILES)
    for y in _light_stamp_size:
        var dy := float(y) - center
        var dy2 := dy * dy
        var row := y * _light_stamp_size
        for x in _light_stamp_size:
            var dx := float(x) - center
            var d2 := dx * dx + dy2
            var value: float
            if d2 <= fbr2:
                value = 1.0
            elif d2 >= lrt2:
                value = 0.0
            else:
                var d := sqrt(d2)
                if d <= LIGHT_INNER_RADIUS_TILES:
                    var t := (d - LIGHT_FULL_BRIGHT_RADIUS) * inv_inner
                    t = clampf(t, 0.0, 1.0)
                    t = t * t * (3.0 - 2.0 * t)  # smoothstep inline
                    value = lerpf(1.0, 0.92, t)
                else:
                    var t := (d - LIGHT_INNER_RADIUS_TILES) * inv_outer
                    t = clampf(t, 0.0, 1.0)
                    t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0)  # smootherstep inline
                    value = lerpf(0.92, 0.0, t)
            _light_stamp[row + x] = value

# -- Create / access fog data --

func get_or_create_fog(chunk_pos: Vector2i, _map_width: int, _map_height: int) -> Dictionary:
    if _chunk_fog.has(chunk_pos):
        return _chunk_fog[chunk_pos]
    var img := Image.create(FOG_SIZE, FOG_SIZE, false, Image.FORMAT_RGBA8)
    img.fill(Color(0, 0, 0, 1))
    var tex := ImageTexture.create_from_image(img)
    var explored := PackedFloat32Array()
    explored.resize(FOG_PIXEL_COUNT)
    explored.fill(0.0)
    var visible := PackedFloat32Array()
    visible.resize(FOG_PIXEL_COUNT)
    visible.fill(0.0)
    var data := {
        "image": img,
        "texture": tex,
        "explored": explored,
        "visible": visible,
    }
    _chunk_fog[chunk_pos] = data
    return data

# -- Main update: stamp visibility, update explored, flood-fill, compose final image --

func update_fog(chunk_pos: Vector2i, local_tile_x: int, local_tile_y: int, map_width: int, map_height: int) -> void:
    var data := get_or_create_fog(chunk_pos, map_width, map_height)
    var visible: PackedFloat32Array = data["visible"]
    var explored: PackedFloat32Array = data["explored"]

    # 1) Clear current visibility
    visible.fill(0.0)

    # 2) Stamp the player light onto visibility
    #    Only iterate over the intersection of the stamp with the FOG_SIZE grid
    var ox := local_tile_x - LIGHT_RADIUS_TILES
    var oy := local_tile_y - LIGHT_RADIUS_TILES

    var ly_start := 0 if oy >= 0 else -oy
    var ly_end := _light_stamp_size if (oy + _light_stamp_size) <= FOG_SIZE else (FOG_SIZE - oy)
    var lx_start := 0 if ox >= 0 else -ox
    var lx_end := _light_stamp_size if (ox + _light_stamp_size) <= FOG_SIZE else (FOG_SIZE - ox)

    if ly_start < ly_end and lx_start < lx_end:
        for ly in range(ly_start, ly_end):
            var fog_row := (oy + ly) * FOG_SIZE
            var light_row := ly * _light_stamp_size
            for lx in range(lx_start, lx_end):
                var idx := fog_row + (ox + lx)
                var stamp_val := _light_stamp[light_row + lx]
                if stamp_val > visible[idx]:
                    visible[idx] = stamp_val

    # 2b) Stamp extra lights (projectiles, explosions)
    if not _extra_lights.is_empty():
        var chunk_origin_x := chunk_pos.x * FOG_SIZE
        var chunk_origin_y := chunk_pos.y * FOG_SIZE
        for light in _extra_lights:
            var lt: Vector2i = light["tile_pos"]
            var lr: float = light["radius"]
            var li: float = light["intensity"]
            _stamp_extra_light_fast(visible, lt.x - chunk_origin_x, lt.y - chunk_origin_y, lr, li)

    # 3) Update explored: explored = max(explored, visible) — single pass
    for i in FOG_PIXEL_COUNT:
        var v := visible[i]
        if v > explored[i]:
            explored[i] = v

    # 4) Flood-fill discovery (single pass is usually sufficient for 16x16)
    _flood_fill_enclosed_fast(explored)

    # 5+6) Apply explored falloff and compose final fog image in combined step
    _apply_falloff_and_compose(data["image"], visible, explored)

    # 7) Upload to GPU
    data["texture"].update(data["image"])

func _stamp_extra_light_fast(visible: PackedFloat32Array, local_x: int, local_y: int, radius: float, intensity: float) -> void:
    var r_int := int(ceil(radius))
    var radius_sq := radius * radius
    var inv_radius := 1.0 / radius if radius > 0.0 else 1.0

    var y_start := maxi(0, local_y - r_int)
    var y_end := mini(FOG_SIZE, local_y + r_int + 1)
    var x_start := maxi(0, local_x - r_int)
    var x_end := mini(FOG_SIZE, local_x + r_int + 1)

    for fy in range(y_start, y_end):
        var dy := fy - local_y
        var dy2 := dy * dy
        var fog_row := fy * FOG_SIZE
        for fx in range(x_start, x_end):
            var dx := fx - local_x
            var d2 := dx * dx + dy2
            if d2 > radius_sq:
                continue
            var t := sqrt(float(d2)) * inv_radius
            # smootherstep inline
            t = clampf(t, 0.0, 1.0)
            t = t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
            var val := lerpf(intensity, 0.0, t)
            var idx := fog_row + fx
            if val > visible[idx]:
                visible[idx] = val

# -- Flood-fill: discover tiles enclosed by explored tiles (single pass, skip edges) --

func _flood_fill_enclosed_fast(explored: PackedFloat32Array) -> void:
    # Single pass is usually enough for 16x16; run 2 passes max for safety
    for _pass in 2:
        var changed := false
        for y in range(1, FOG_SIZE - 1):
            var row := y * FOG_SIZE
            var row_above := row - FOG_SIZE
            var row_below := row + FOG_SIZE
            for x in range(1, FOG_SIZE - 1):
                var idx := row + x
                if explored[idx] >= EXPLORED_BRIGHTNESS:
                    continue
                # Count explored neighbors (8-connected) — unrolled
                var count := 0
                var neighbor_sum := 0.0
                var n: float

                n = explored[row_above + x - 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row_above + x]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row_above + x + 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row + x - 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row + x + 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row_below + x - 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row_below + x]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n
                n = explored[row_below + x + 1]
                if n >= EXPLORED_BRIGHTNESS:
                    count += 1; neighbor_sum += n

                if count >= FLOOD_FILL_NEIGHBOR_THRESHOLD:
                    var new_val := minf(neighbor_sum / float(count), EXPLORED_BRIGHTNESS)
                    if new_val > explored[idx]:
                        explored[idx] = new_val
                        changed = true
        if not changed:
            break

# -- Combined falloff + image composition (avoids extra array allocations) --

func _apply_falloff_and_compose(img: Image, visible: PackedFloat32Array, explored: PackedFloat32Array) -> void:
    # Work on the scratch buffer for falloff
    var result := _falloff_scratch

    # Copy explored into result
    for i in FOG_PIXEL_COUNT:
        result[i] = explored[i]

    # Blur passes to soften explored edges
    # Use a simple separable-ish max-spread with weights
    for _pass_i in EXPLORED_FALLOFF_TILES:
        var prev := result.duplicate()
        for y in FOG_SIZE:
            var row := y * FOG_SIZE
            for x in FOG_SIZE:
                var idx := row + x
                if prev[idx] >= EXPLORED_BRIGHTNESS:
                    continue
                # Find max weighted neighbor
                var max_n := 0.0

                # Cardinal neighbors (weight 0.75)
                if y > 0:
                    var nv := prev[idx - FOG_SIZE] * 0.75
                    if nv > max_n: max_n = nv
                if y < FOG_SIZE - 1:
                    var nv := prev[idx + FOG_SIZE] * 0.75
                    if nv > max_n: max_n = nv
                if x > 0:
                    var nv := prev[idx - 1] * 0.75
                    if nv > max_n: max_n = nv
                if x < FOG_SIZE - 1:
                    var nv := prev[idx + 1] * 0.75
                    if nv > max_n: max_n = nv

                # Diagonal neighbors (weight 0.6)
                if y > 0 and x > 0:
                    var nv := prev[idx - FOG_SIZE - 1] * 0.6
                    if nv > max_n: max_n = nv
                if y > 0 and x < FOG_SIZE - 1:
                    var nv := prev[idx - FOG_SIZE + 1] * 0.6
                    if nv > max_n: max_n = nv
                if y < FOG_SIZE - 1 and x > 0:
                    var nv := prev[idx + FOG_SIZE - 1] * 0.6
                    if nv > max_n: max_n = nv
                if y < FOG_SIZE - 1 and x < FOG_SIZE - 1:
                    var nv := prev[idx + FOG_SIZE + 1] * 0.6
                    if nv > max_n: max_n = nv

                var threshold := EXPLORED_EDGE_BRIGHTNESS * 0.3
                if max_n > result[idx] and max_n > threshold:
                    result[idx] = minf(max_n, EXPLORED_BRIGHTNESS)

    # Compose final RGBA bytes in one pass
    var bytes := _compose_bytes
    var eb := EXPLORED_BRIGHTNESS
    var eb_threshold := eb * 0.9
    var inv_eb_threshold := 1.0 / eb_threshold if eb_threshold > 0.0 else 1.0
    for i in FOG_PIXEL_COUNT:
        var vis := visible[i]
        var exp_val := result[i]

        var brightness: float
        if vis > 0.0:
            var explored_contrib := exp_val * eb
            brightness = vis if vis > explored_contrib else explored_contrib
        else:
            brightness = exp_val * eb
            if brightness > 0.0 and brightness < eb_threshold:
                var t := brightness * inv_eb_threshold
                t = t * t * (3.0 - 2.0 * t)  # smoothstep inline
                brightness = t * eb_threshold

        # Clamp and convert to byte
        var b: int
        if brightness <= 0.0:
            b = 0
        elif brightness >= 1.0:
            b = 255
        else:
            b = int(brightness * 255.0)

        var off := i * 4
        bytes[off] = b
        bytes[off + 1] = b
        bytes[off + 2] = b
        bytes[off + 3] = 255

    # Single bulk image update
    var new_img := Image.create_from_data(FOG_SIZE, FOG_SIZE, false, Image.FORMAT_RGBA8, bytes)
    img.copy_from(new_img)

func get_texture(chunk_pos: Vector2i) -> ImageTexture:
    var data = _chunk_fog.get(chunk_pos)
    if data == null:
        return null
    return data["texture"] as ImageTexture

func has_fog(chunk_pos: Vector2i) -> bool:
    return _chunk_fog.has(chunk_pos)
