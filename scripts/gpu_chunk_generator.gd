class_name GPUChunkGenerator
extends RefCounted

var rd: RenderingDevice
var shader: RID
var pipeline: RID

var _chunk_width: int = 16
var _chunk_height: int = 16
var _map_size: int = 256

var _initialized: bool = false
var _supported: bool = false

# Generation parameters
var world_seed: int = 69420
var cave_threshold: float = 0.0
var smoothing_iterations: int = 8
var material_params: Array[Vector4] = []

# Reusable buffers for batch generation
var _params_buffer: RID
var _cells_a_buffer: RID
var _cells_b_buffer: RID
var _material_buffer: RID
var _output_buffer: RID
var _uniform_set: RID

# Workgroup size must match shader
const WORKGROUP_SIZE: int = 16

func _init() -> void:
    pass

func initialize(chunk_width: int, chunk_height: int) -> bool:
    _chunk_width = chunk_width
    _chunk_height = chunk_height
    _map_size = chunk_width * chunk_height

    # Create local rendering device
    rd = RenderingServer.create_local_rendering_device()
    if rd == null:
        push_warning("GPUChunkGenerator: Failed to create rendering device. Compute shaders not supported.")
        _supported = false
        return false

    # Load and compile shader
    var shader_file := load("res://shaders/chunk_generation.glsl") as RDShaderFile
    if shader_file == null:
        push_error("GPUChunkGenerator: Failed to load shader file")
        _supported = false
        return false

    var shader_spirv := shader_file.get_spirv()
    if shader_spirv == null:
        push_error("GPUChunkGenerator: Failed to get SPIRV from shader")
        _supported = false
        return false

    shader = rd.shader_create_from_spirv(shader_spirv)
    if not shader.is_valid():
        push_error("GPUChunkGenerator: Failed to create shader from SPIRV")
        _supported = false
        return false

    pipeline = rd.compute_pipeline_create(shader)
    if not pipeline.is_valid():
        push_error("GPUChunkGenerator: Failed to create compute pipeline")
        _supported = false
        return false

    # Create persistent buffers
    _create_buffers()

    _initialized = true
    _supported = true
    print("GPUChunkGenerator: Initialized successfully (%dx%d chunks)" % [chunk_width, chunk_height])
    return true

func is_supported() -> bool:
    return _supported

func cleanup() -> void:
    if rd == null:
        return

    _free_buffers()

    if pipeline.is_valid():
        rd.free_rid(pipeline)
    if shader.is_valid():
        rd.free_rid(shader)

    rd.free()
    rd = null
    _initialized = false

func _create_buffers() -> void:
    # Params buffer (will be updated per-chunk)
    # Size: 8 ints + 8 vec4s = 32 + 128 = 160 bytes, align to 16 = 160
    var params_size: int = 160
    _params_buffer = rd.storage_buffer_create(params_size)

    # Cell buffers (int per cell for atomicity)
    var cells_size: int = _map_size * 4  # 4 bytes per int
    _cells_a_buffer = rd.storage_buffer_create(cells_size)
    _cells_b_buffer = rd.storage_buffer_create(cells_size)
    _material_buffer = rd.storage_buffer_create(cells_size)
    _output_buffer = rd.storage_buffer_create(cells_size)

func _free_buffers() -> void:
    if _params_buffer.is_valid():
        rd.free_rid(_params_buffer)
    if _cells_a_buffer.is_valid():
        rd.free_rid(_cells_a_buffer)
    if _cells_b_buffer.is_valid():
        rd.free_rid(_cells_b_buffer)
    if _material_buffer.is_valid():
        rd.free_rid(_material_buffer)
    if _output_buffer.is_valid():
        rd.free_rid(_output_buffer)
    if _uniform_set.is_valid():
        rd.free_rid(_uniform_set)

func set_generation_params(seed_val: int, threshold: float, iterations: int, materials: Array[Vector4]) -> void:
    world_seed = seed_val
    cave_threshold = threshold
    smoothing_iterations = iterations
    material_params = materials

func _create_params_bytes(offset_x: int, offset_y: int) -> PackedByteArray:
    var buffer := PackedByteArray()
    buffer.resize(160)

    var idx: int = 0

    # Int params (4 bytes each)
    buffer.encode_s32(idx, offset_x)
    idx += 4
    buffer.encode_s32(idx, offset_y)
    idx += 4
    buffer.encode_s32(idx, _chunk_width)
    idx += 4
    buffer.encode_s32(idx, _chunk_height)
    idx += 4
    buffer.encode_s32(idx, world_seed)
    idx += 4
    buffer.encode_float(idx, cave_threshold)
    idx += 4
    buffer.encode_s32(idx, smoothing_iterations)
    idx += 4
    buffer.encode_s32(idx, material_params.size())
    idx += 4

    # Material params (8 x vec4 = 8 x 16 bytes)
    for i in 8:
        if i < material_params.size():
            var mp: Vector4 = material_params[i]
            buffer.encode_float(idx, mp.x)      # threshold
            buffer.encode_float(idx + 4, mp.y)  # weight
            buffer.encode_float(idx + 8, mp.z)  # frequency
            buffer.encode_float(idx + 12, mp.w) # octaves
        else:
            buffer.encode_float(idx, 0.0)
            buffer.encode_float(idx + 4, 0.0)
            buffer.encode_float(idx + 8, 0.0)
            buffer.encode_float(idx + 12, 0.0)
        idx += 16

    return buffer

func _create_uniform_set() -> void:
    if _uniform_set.is_valid():
        rd.free_rid(_uniform_set)

    var uniforms: Array[RDUniform] = []

    # Binding 0: Params
    var u_params := RDUniform.new()
    u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    u_params.binding = 0
    u_params.add_id(_params_buffer)
    uniforms.append(u_params)

    # Binding 1: Cells A
    var u_cells_a := RDUniform.new()
    u_cells_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    u_cells_a.binding = 1
    u_cells_a.add_id(_cells_a_buffer)
    uniforms.append(u_cells_a)

    # Binding 2: Cells B
    var u_cells_b := RDUniform.new()
    u_cells_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    u_cells_b.binding = 2
    u_cells_b.add_id(_cells_b_buffer)
    uniforms.append(u_cells_b)

    # Binding 3: Materials
    var u_materials := RDUniform.new()
    u_materials.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    u_materials.binding = 3
    u_materials.add_id(_material_buffer)
    uniforms.append(u_materials)

    # Binding 4: Output
    var u_output := RDUniform.new()
    u_output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    u_output.binding = 4
    u_output.add_id(_output_buffer)
    uniforms.append(u_output)

    _uniform_set = rd.uniform_set_create(uniforms, shader, 0)

func generate_chunk(pos: Vector2i) -> PackedByteArray:
    if not _initialized or not _supported:
        return PackedByteArray()

    var offset_x: int = pos.x * _chunk_width
    var offset_y: int = pos.y * _chunk_height

    # Update params buffer
    var params_bytes := _create_params_bytes(offset_x, offset_y)
    rd.buffer_update(_params_buffer, 0, params_bytes.size(), params_bytes)

    # Recreate uniform set (needed after buffer update)
    _create_uniform_set()

    var workgroups_x: int = ceili(float(_chunk_width) / WORKGROUP_SIZE)
    var workgroups_y: int = ceili(float(_chunk_height) / WORKGROUP_SIZE)

    # Pass 0: Initialize
    _dispatch_pass(0, 0, workgroups_x, workgroups_y)

    # Smoothing passes (ping-pong between buffers)
    for i in smoothing_iterations:
        var pass_type: int = 1 if (i % 2 == 0) else 2
        _dispatch_pass(pass_type, i, workgroups_x, workgroups_y)

    # Pass 3: Finalize
    _dispatch_pass(3, smoothing_iterations, workgroups_x, workgroups_y)

    # Read results
    var result_bytes := rd.buffer_get_data(_output_buffer)

    # Convert int32 array to byte array (material values are 0-255)
    var cells := PackedByteArray()
    cells.resize(_map_size)

    for i in _map_size:
        var val: int = result_bytes.decode_s32(i * 4)
        cells[i] = clampi(val, 0, 255)

    return cells

func _dispatch_pass(pass_type: int, iteration: int, workgroups_x: int, workgroups_y: int) -> void:
    # Create push constants (16 bytes required by pipeline alignment)
    var push_constants := PackedByteArray()
    push_constants.resize(16)
    push_constants.encode_s32(0, pass_type)
    push_constants.encode_s32(4, iteration)

    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
    rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
    rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
    rd.compute_list_dispatch(compute_list, workgroups_x, workgroups_y, 1)
    rd.compute_list_end()

    rd.submit()
    rd.sync()

# Batch generation for multiple chunks
func generate_chunks_batch(positions: Array[Vector2i]) -> Dictionary:
    var results: Dictionary = {}

    for pos in positions:
        results[pos] = generate_chunk(pos)

    return results
