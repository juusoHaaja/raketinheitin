class_name GPUFogSystem
extends RefCounted

const FOG_SIZE: int = 16
const MAX_CHUNKS_PER_BATCH: int = 256
const MAX_LIGHTS: int = 64
const FLOOD_FILL_ITERATIONS: int = 8
const BLUR_ITERATIONS: int = 3

var rd: RenderingDevice
var shader: RID
var pipeline: RID

var _params_buffer: RID
var _lights_buffer: RID
var _explored_buffer: RID
var _visible_buffer: RID
var _temp_buffer: RID
var _temp_buffer_2: RID
var _output_buffer: RID
var _uniform_set: RID

var _initialized: bool = false
var _supported: bool = false

# Per-chunk data
# chunk_key -> { "explored": PackedFloat32Array, "texture": ImageTexture, "image": Image }
var _chunk_data: Dictionary = {}

# Current batch data
var _batch_chunks: Array[Vector2i] = []
var _batch_offsets: Dictionary = {}  # chunk_key -> buffer offset

func _init() -> void:
    pass

func initialize() -> bool:
    rd = RenderingServer.create_local_rendering_device()
    if rd == null:
        push_warning("GPUFogSystem: Failed to create rendering device")
        _supported = false
        return false

    var shader_file := load("res://shaders/fog_compute.glsl") as RDShaderFile
    if shader_file == null:
        push_error("GPUFogSystem: Failed to load fog shader")
        _supported = false
        return false

    var shader_spirv := shader_file.get_spirv()
    if shader_spirv == null:
        push_error("GPUFogSystem: Failed to get SPIRV")
        _supported = false
        return false

    shader = rd.shader_create_from_spirv(shader_spirv)
    if not shader.is_valid():
        push_error("GPUFogSystem: Failed to create shader")
        _supported = false
        return false

    pipeline = rd.compute_pipeline_create(shader)
    if not pipeline.is_valid():
        push_error("GPUFogSystem: Failed to create pipeline")
        _supported = false
        return false

    _create_buffers()

    _initialized = true
    _supported = true
    print("GPUFogSystem: Initialized successfully")
    return true

func is_supported() -> bool:
    return _supported

func cleanup() -> void:
    if rd == null:
        return

    # Free pipeline and shader only. Destroying the RenderingDevice with rd.free()
    # releases all buffers and uniform sets; skip _free_buffers() to avoid
    # "Attempted to free invalid ID" when the device/viewport is already torn down.
    if pipeline.is_valid():
        rd.free_rid(pipeline)
        pipeline = RID()
    if shader.is_valid():
        rd.free_rid(shader)
        shader = RID()

    rd.free()
    rd = null
    _initialized = false

func _create_buffers() -> void:
    var pixels_per_chunk: int = FOG_SIZE * FOG_SIZE
    var max_pixels: int = pixels_per_chunk * MAX_CHUNKS_PER_BATCH

    # Params buffer: 4 ints + 256 * ivec4 = 16 + 4096 = 4112 bytes
    var params_size: int = 16 + MAX_CHUNKS_PER_BATCH * 16
    _params_buffer = rd.storage_buffer_create(params_size)

    # Lights buffer: 64 * vec4 = 1024 bytes
    var lights_size: int = MAX_LIGHTS * 16
    _lights_buffer = rd.storage_buffer_create(lights_size)

    # Data buffers: float per pixel
    var data_size: int = max_pixels * 4
    _explored_buffer = rd.storage_buffer_create(data_size)
    _visible_buffer = rd.storage_buffer_create(data_size)
    _temp_buffer = rd.storage_buffer_create(data_size)
    _temp_buffer_2 = rd.storage_buffer_create(data_size)

    # Output buffer: uint32 (RGBA8) per pixel
    _output_buffer = rd.storage_buffer_create(max_pixels * 4)

func _free_buffers() -> void:
    var buffers: Array[RID] = [
        _params_buffer, _lights_buffer, _explored_buffer,
        _visible_buffer, _temp_buffer, _temp_buffer_2, _output_buffer
    ]

    for buf in buffers:
        if buf.is_valid():
            rd.free_rid(buf)

    if _uniform_set.is_valid():
        rd.free_rid(_uniform_set)

func _create_uniform_set() -> void:
    if _uniform_set.is_valid():
        rd.free_rid(_uniform_set)

    var uniforms: Array[RDUniform] = []

    var bindings: Array[RID] = [
        _params_buffer, _lights_buffer, _explored_buffer,
        _visible_buffer, _temp_buffer, _temp_buffer_2, _output_buffer
    ]

    for i in bindings.size():
        var uniform := RDUniform.new()
        uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        uniform.binding = i
        uniform.add_id(bindings[i])
        uniforms.append(uniform)

    _uniform_set = rd.uniform_set_create(uniforms, shader, 0)

func _chunk_key(pos: Vector2i) -> String:
    return "%d,%d" % [pos.x, pos.y]

func get_or_create_chunk(chunk_pos: Vector2i) -> Dictionary:
    var key := _chunk_key(chunk_pos)
    if _chunk_data.has(key):
        return _chunk_data[key]

    var explored := PackedFloat32Array()
    explored.resize(FOG_SIZE * FOG_SIZE)
    explored.fill(0.0)

    var img := Image.create(FOG_SIZE, FOG_SIZE, false, Image.FORMAT_RGBA8)
    img.fill(Color(0, 0, 0, 1))
    var tex := ImageTexture.create_from_image(img)

    _chunk_data[key] = {
        "explored": explored,
        "image": img,
        "texture": tex,
        "dirty": true
    }

    return _chunk_data[key]

func get_texture(chunk_pos: Vector2i) -> ImageTexture:
    var key := _chunk_key(chunk_pos)
    var data = _chunk_data.get(key)
    if data == null:
        return null
    return data.texture as ImageTexture

# Main update function - processes all visible chunks at once
func update_fog_batch(chunk_positions: Array[Vector2i], lights: Array[Dictionary]) -> void:
    if not _initialized or chunk_positions.is_empty():
        return

    var num_chunks: int = mini(chunk_positions.size(), MAX_CHUNKS_PER_BATCH)
    var num_lights: int = mini(lights.size(), MAX_LIGHTS)

    _batch_chunks.clear()
    _batch_offsets.clear()

    var pixels_per_chunk: int = FOG_SIZE * FOG_SIZE

    # Prepare chunk data and upload explored values
    var explored_data := PackedFloat32Array()
    explored_data.resize(num_chunks * pixels_per_chunk)

    var offset: int = 0
    for i in range(num_chunks):
        var cpos: Vector2i = chunk_positions[i]
        var key := _chunk_key(cpos)
        var data := get_or_create_chunk(cpos)

        _batch_chunks.append(cpos)
        _batch_offsets[key] = offset

        # Copy explored data
        var chunk_explored: PackedFloat32Array = data.explored
        for j in range(pixels_per_chunk):
            explored_data[offset + j] = chunk_explored[j]

        offset += pixels_per_chunk

    # Upload explored data
    var explored_bytes := explored_data.to_byte_array()
    rd.buffer_update(_explored_buffer, 0, explored_bytes.size(), explored_bytes)

    # Prepare params buffer (num_chunks, num_lights, pass_type, iteration at 0,4,8,12; chunk_info at 16+)
    var params_bytes := PackedByteArray()
    params_bytes.resize(16 + num_chunks * 16)
    params_bytes.encode_s32(0, num_chunks)
    params_bytes.encode_s32(4, num_lights)
    params_bytes.encode_s32(8, 0)  # pass_type (updated per pass)
    params_bytes.encode_s32(12, 0)  # iteration

    var idx: int = 16
    for i in range(num_chunks):
        var cpos: Vector2i = _batch_chunks[i]
        var buf_offset: int = i * pixels_per_chunk
        params_bytes.encode_s32(idx, cpos.x)
        params_bytes.encode_s32(idx + 4, cpos.y)
        params_bytes.encode_s32(idx + 8, buf_offset)
        params_bytes.encode_s32(idx + 12, 0)  # padding
        idx += 16

    rd.buffer_update(_params_buffer, 0, params_bytes.size(), params_bytes)

    # Prepare lights buffer
    var lights_bytes := PackedByteArray()
    lights_bytes.resize(MAX_LIGHTS * 16)
    lights_bytes.fill(0)

    for i in range(num_lights):
        var light: Dictionary = lights[i]
        var light_offset: int = i * 16
        var tile_pos: Vector2i = light.get("tile_pos", Vector2i.ZERO)
        var radius: float = light.get("radius", 48.0)
        var intensity: float = light.get("intensity", 1.0)

        lights_bytes.encode_float(light_offset, float(tile_pos.x))
        lights_bytes.encode_float(light_offset + 4, float(tile_pos.y))
        lights_bytes.encode_float(light_offset + 8, radius)
        lights_bytes.encode_float(light_offset + 12, intensity)

    rd.buffer_update(_lights_buffer, 0, lights_bytes.size(), lights_bytes)

    # Create uniform set
    _create_uniform_set()

    # Run passes
    _run_pass(0, 0, num_chunks)  # Stamp lights

    for i in range(FLOOD_FILL_ITERATIONS):
        _run_pass(1, i, num_chunks)  # Flood fill

    for i in range(BLUR_ITERATIONS):
        _run_pass(2, i, num_chunks)  # Blur (ping-pong via iteration)

    _run_pass(3, 0, num_chunks)  # Compose

    # Read results and update textures
    _read_results(num_chunks)

func _run_pass(pass_type: int, iteration: int, num_chunks: int) -> void:
    # Update pass_type and iteration in params (bytes 8-16)
    var params_update := PackedByteArray()
    params_update.resize(8)
    params_update.encode_s32(0, pass_type)
    params_update.encode_s32(4, iteration)
    rd.buffer_update(_params_buffer, 8, 8, params_update)

    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
    rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
    # Dispatch: 1 workgroup per chunk (16x16 threads), z = chunk index
    rd.compute_list_dispatch(compute_list, 1, 1, num_chunks)
    rd.compute_list_end()

    rd.submit()
    rd.sync()

func _read_results(num_chunks: int) -> void:
    var pixels_per_chunk: int = FOG_SIZE * FOG_SIZE
    var total_pixels: int = num_chunks * pixels_per_chunk

    # Read output RGBA data
    var output_bytes: PackedByteArray = rd.buffer_get_data(_output_buffer, 0, total_pixels * 4)

    # Read updated explored data
    var explored_bytes: PackedByteArray = rd.buffer_get_data(_explored_buffer, 0, total_pixels * 4)

    # Update each chunk's texture and explored data
    for i in range(num_chunks):
        var cpos: Vector2i = _batch_chunks[i]
        var key := _chunk_key(cpos)
        var data: Dictionary = _chunk_data[key]
        var buf_offset: int = i * pixels_per_chunk

        # Update explored array (4 bytes per float)
        var chunk_explored: PackedFloat32Array = data.explored
        for j in range(pixels_per_chunk):
            chunk_explored[j] = explored_bytes.decode_float((buf_offset + j) * 4)

        # Bulk update image from RGBA output (shader writes R,G,B,A per pixel; set_data avoids set_pixel loop)
        var img: Image = data.image
        var byte_offset: int = buf_offset * 4
        var chunk_bytes: PackedByteArray = output_bytes.slice(byte_offset, byte_offset + pixels_per_chunk * 4)
        img.set_data(FOG_SIZE, FOG_SIZE, false, Image.FORMAT_RGBA8, chunk_bytes)

        # Update texture
        var tex: ImageTexture = data.texture
        tex.update(img)
        data.dirty = false

func has_fog(chunk_pos: Vector2i) -> bool:
    return _chunk_data.has(_chunk_key(chunk_pos))
