extends RigidBody2D
class_name Player

@onready var ground_raycast: RayCast2D = $GroundRaycast
@onready var line_holder = $Lines
@onready var collider = $CollisionShape2D
@onready var health: HealthComponent = $Health
@onready var boom_sfx: SoundEffect = $sfx/Explosions
@onready var pickup_sfx: SoundEffect = $sfx/Pickup
@onready var hit_sfx: SoundEffect = $sfx/Hit
@onready var sprite = $Sprite2D

var local_collisions: PackedVector2Array
var jump_timer: Timer = Timer.new()

var dir := false

var jump_on_cooldown = false

var grappling_line_force: float = 100000.0
var max_grappling_hooks: int = 5

## Passive health regeneration per second (only when below max)
@export var health_regen_per_second: float = 0.25

var _waiting_for_chunks := true

func _ready() -> void:
    add_to_group("player")
    freeze = true
    freeze_mode = RigidBody2D.FREEZE_MODE_STATIC

    add_child(jump_timer)
    jump_timer.one_shot = true
    jump_timer.connect("timeout", jump_timer_timeout)

    health.died.connect(_on_health_died)
    health.damage_taken.connect(_on_damage_taken)

    _wait_for_initial_chunks()

func _wait_for_initial_chunks() -> void:
    # Wait for ChunkParent to exist and finish its own init
    while not ChunkParent.instance or not ChunkParent.instance._initial_generation_complete:
        await get_tree().process_frame

    # Now force generate chunks around our actual position
    var player_tile: Vector2i = ChunkParent.instance.snap_global_to_grid(global_position)
    var player_chunk: Vector2i = ChunkParent.instance.get_chunk_pos(player_tile)
    ChunkParent.instance._force_generate_area(player_chunk, 3)

    # Verify everything is solid
    while not _chunks_ready():
        # Keep requesting generation each frame in case something was missed
        player_tile = ChunkParent.instance.snap_global_to_grid(global_position)
        player_chunk = ChunkParent.instance.get_chunk_pos(player_tile)
        ChunkParent.instance._force_generate_area(player_chunk, 2)
        await get_tree().process_frame

    print("Chunks ready around player at chunk ", player_chunk, ", unfreezing")
    _waiting_for_chunks = false
    freeze = false

func _chunks_ready() -> bool:
    if not ChunkParent.instance:
        return false
    if ChunkParent.instance.get_chunks().is_empty():
        return false

    var player_tile: Vector2i = ChunkParent.instance.snap_global_to_grid(global_position)
    var player_chunk: Vector2i = ChunkParent.instance.get_chunk_pos(player_tile)

    for dy in range(-2, 3):
        for dx in range(-2, 3):
            var check_pos: Vector2i = player_chunk + Vector2i(dx, dy)
            if not ChunkParent.instance.is_generated(check_pos):
                return false
            var chunk: Chunk = ChunkParent.instance.get_chunk_if_exists(check_pos)
            if not chunk or not chunk.generation_complete:
                return false

    return true

func jump() -> void:
    if !jump_on_cooldown:
        apply_central_force(Vector2.UP * 30000)
        jump_on_cooldown = true
        jump_timer.start(0.4)

func jump_timer_timeout() -> void:
    jump_on_cooldown = false


func _on_health_died() -> void:
    # Main scene will show game over overlay via its connection to health.died
    pass

func _on_damage_taken(_amount: float) -> void:
    if hit_sfx:
        hit_sfx.play_random()

func _process(delta: float) -> void:
    if wish_dir.x < 0:
        dir = true
    if wish_dir.x > 0:
        dir = false
    sprite.flip_h = dir

    # Passive regeneration when below max health
    if health and health.current_health < health.max_health:
        health.heal(health_regen_per_second * delta)

var wish_dir = Vector2.ZERO

func _physics_process(delta: float) -> void:
    if _waiting_for_chunks:
        return

    # During gameplay, request priority generation around player
    _request_nearby_chunks()

    wish_dir = Input.get_vector("left", "right", "up", "down")

    if grounded():
        if linear_velocity.x * wish_dir.x < 500.0:
            apply_central_force(Vector2(wish_dir.x, 0) * 100000 * delta)

        if wish_dir.y < 0.0:
            jump()
    else:
        if linear_velocity.x * wish_dir.x < 500.0:
            apply_central_force(Vector2(wish_dir.x, 0) * 10000 * delta)

    var lines: Array[Node] = line_holder.get_children()

    if wish_dir.length() > 0.05:
        for i in lines.size():
            var line: GrappleLine = lines[i] as GrappleLine
            if not line:
                continue
            var line_dir: Vector2 = line.get_angle_vector()
            var facing: float = line_dir.normalized().dot(wish_dir.normalized())

            if facing > 0:
                apply_central_force(line_dir * facing * wish_dir.length() * grappling_line_force * delta)

func _request_nearby_chunks() -> void:
    if not ChunkParent.instance:
        return

    var player_tile: Vector2i = ChunkParent.instance.snap_global_to_grid(global_position)
    var player_chunk: Vector2i = ChunkParent.instance.get_chunk_pos(player_tile)

    # Force-generate immediate neighbors if missing (safety net)
    for dy in range(-2, 3):  # Increased from -1, 2
        for dx in range(-2, 3):  # Increased from -1, 2
            var check_pos: Vector2i = player_chunk + Vector2i(dx, dy)
            if not ChunkParent.instance.is_generated(check_pos):
                ChunkParent.instance.force_generate(check_pos)

    # Priority-queue a much larger area
    var priority_radius := 8  # Chunks that MUST be ready soon
    var queue_radius := 16    # Chunks to queue for later
    
    for r in range(3, queue_radius + 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if abs(dx) != r and abs(dy) != r:
                    continue  # Only process the ring edge
                
                # Skip corners (circular loading)
                if dx * dx + dy * dy > queue_radius * queue_radius:
                    continue
                    
                var check_pos: Vector2i = player_chunk + Vector2i(dx, dy)
                if ChunkParent.instance.is_generated(check_pos):
                    continue
                    
                if r <= priority_radius:
                    ChunkParent.instance.generate_chunk_priority(check_pos)
                else:
                    ChunkParent.instance.generate_chunk(check_pos)
                    
func grounded() -> bool:
    if _waiting_for_chunks:
        return true

    if ground_raycast.is_colliding():
        return true
    if local_collisions.size() > 0:
        for point in local_collisions:
            if point.y > collider.shape.height / 2.0 - collider.shape.radius and abs(point.x) < collider.shape.radius - 0.01:
                return true

    return false

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
    local_collisions.clear()
    for i in state.get_contact_count():
        local_collisions.push_back(to_local(state.get_contact_local_position(i)))

func boom() -> void:
    boom_sfx.play_random()

func pickuop() -> void:
    pickup_sfx.play_random()

func get_max_grappling_hooks() -> int:
    return max_grappling_hooks
