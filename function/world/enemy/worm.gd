extends Node2D

enum Move {
    ORBIT,
    LUNGE,
    RETREAT,
    STRAFE,
    PAUSE,
    CHARGE,
}

@onready var head: WormHead = $Head
@onready var health: HealthComponent = $Health
@onready var target_node: Node2D = $TargetNode
@onready var segment_parent: Node2D = $Segments
@onready var damage_zone: Area2D = $Head/DamageZone
@onready var health_bar: Node2D = $HealthBar
@onready var hit_sfx: AudioStreamPlayer = $HitSfx

@export var segment_dist: float = 100.0
@export var contact_damage: float = 10.0
@export var damage_cooldown: float = 1.0

## Charge attack: runs at player, breaks cells, extra damage
@export var charge_probability: float = 0.30
@export var charge_speed: float = 2200.0
@export var charge_duration_min: float = 0.6
@export var charge_duration_max: float = 1.2
@export var charge_damage: float = 28.0
@export var charge_break_radius: float = 6.5
@export var head_move_speed: float = 1000.0

var _damage_cooldown_timer: float = 0.0
var _charge_direction: Vector2 = Vector2.RIGHT
var _charge_break_tool: CircleTool
@export var segment_smooth: float = 12.0  ## How quickly segments follow (higher = tighter chain)
@export var path_step: float = 8.0  ## Add path point every this many units (smaller = smoother tail)

## AI: orbit around this target (e.g. player). If null, head follows mouse (editor/test).
var player_target: Node2D = null
@export var orbit_radius: float = 280.0
@export var orbit_speed: float = 0.6  ## Radians per second
@export var orbit_wobble: float = 0.15  ## Radius variation (0 = perfect circle)
@export var orbit_wobble_speed: float = 2.0
@export var move_duration_min: float = 1.0
@export var move_duration_max: float = 2.8
@export var lunge_radius_ratio: float = 0.45  ## How close during lunge (more aggressive)
@export var retreat_radius_ratio: float = 1.3
@export var strafe_speed: float = 1.6  ## Faster strafing
@export var close_range_threshold: float = 180.0  ## Prefer lunge when player within this distance
@export var stationary_charge_bonus: float = 0.25  ## Extra charge chance when player barely moving

var _orbit_angle: float = 0.0
var _current_move: Move = Move.ORBIT
var _move_timer: float = 0.0
var _move_duration: float = 2.0
var _strafe_direction: float = 1.0

var segments: Array[Node2D] = []

## Path the head has traveled; segments follow this trail. Each element: { "p": Vector2, "d": float }
var _path: Array = []
var _path_length: float = 0.0
var _last_path_pos: Vector2 = Vector2.INF
var _last_segment_mode: bool = false
var _last_segment_ref: Node2D = null

func _ready() -> void:
    health.died.connect(_on_died)
    health.damage_taken.connect(_on_damage_taken)
    head.target_node = target_node
    head.move_speed = head_move_speed
    head.z_index = -1
    damage_zone.body_entered.connect(_on_damage_zone_body_entered)
    if ChunkParent.instance:
        _charge_break_tool = CircleTool.new(charge_break_radius)
    # Head runs first so we get this frame's position for path recording
    head.set_physics_process_priority(-1)
    for c in segment_parent.get_children():
        if c is Node2D:
            var seg: Node2D = c as Node2D
            seg.z_index = -1
            segments.append(seg)
            var seg_health: HealthComponent = seg.get_node_or_null("Health") as HealthComponent
            if seg_health:
                seg_health.died.connect(_on_segment_died.bind(seg))
    _orbit_angle = randf() * TAU
    _pick_next_move()

func _on_segment_died(seg: Node2D) -> void:
    segments.erase(seg)
    seg.queue_free()

func _enter_last_segment_mode() -> void:
    _last_segment_mode = true
    if segments.is_empty():
        return
    _last_segment_ref = segments[0]
    var seg_health: HealthComponent = _last_segment_ref.get_node_or_null("Health") as HealthComponent
    if not seg_health:
        return
    var combined_max: float = health.max_health + seg_health.max_health
    var combined_current: float = health.current_health + seg_health.current_health
    health.max_health = combined_max
    health.current_health = combined_current
    seg_health.current_health = seg_health.max_health
    seg_health.damage_taken.connect(_on_last_segment_damage_taken)

func _on_last_segment_damage_taken(amount: float) -> void:
    health.take_damage(amount)
    if is_instance_valid(_last_segment_ref):
        var seg_health: HealthComponent = _last_segment_ref.get_node_or_null("Health") as HealthComponent
        if seg_health:
            call_deferred("_heal_last_segment", amount)

func _heal_last_segment(amount: float) -> void:
    if not is_instance_valid(_last_segment_ref):
        return
    var seg_health: HealthComponent = _last_segment_ref.get_node_or_null("Health") as HealthComponent
    if seg_health:
        seg_health.heal(amount)

func set_player_target(p: Node2D) -> void:
    player_target = p

func _on_died() -> void:
    queue_free()

func _on_damage_taken(amount: float) -> void:
    if hit_sfx and hit_sfx.stream:
        hit_sfx.play()
    # Distribute head damage equally across head + all segments (skip when merged with last segment)
    if segments.is_empty() or _last_segment_mode:
        return
    var total_parts: int = segments.size() + 1
    var per_part: float = amount / float(total_parts)
    health.heal(amount - per_part)
    for seg in segments.duplicate():
        if not is_instance_valid(seg):
            continue
        var seg_health: HealthComponent = seg.get_node_or_null("Health") as HealthComponent
        if seg_health:
            seg_health.take_damage(per_part)

func _process(delta: float) -> void:
    if _damage_cooldown_timer > 0.0:
        _damage_cooldown_timer -= delta
    if is_instance_valid(player_target):
        _update_ai_target(delta)
    else:
        target_node.global_position = get_global_mouse_position()  # Editor/test: follow mouse

func _on_damage_zone_body_entered(body: Node2D) -> void:
    if _damage_cooldown_timer > 0.0:
        return
    if not body.is_in_group("player"):
        return
    var body_health: HealthComponent = _find_health(body)
    if body_health != null:
        var damage: float = charge_damage if _current_move == Move.CHARGE else contact_damage
        var cooldown: float = damage_cooldown * 0.3 if _current_move == Move.CHARGE else damage_cooldown
        body_health.take_damage(damage)
        _damage_cooldown_timer = cooldown

func _find_health(node: Node) -> HealthComponent:
    var n: Node = node
    while n != null:
        var h: Node = n.get_node_or_null("Health")
        if h is HealthComponent:
            return h as HealthComponent
        n = n.get_parent()
    return null

func _pick_next_move() -> void:
    if _current_move == Move.CHARGE:
        head.move_speed = head_move_speed
    var dist_to_player: float = 0.0
    if is_instance_valid(player_target):
        dist_to_player = head.global_position.distance_to(player_target.global_position)
    # When player is close, charge more often and prefer aggressive moves (lunge/strafe over pause/retreat)
    var charge_roll: float = charge_probability
    if dist_to_player > 0.0 and dist_to_player < close_range_threshold:
        charge_roll += stationary_charge_bonus
    var candidates: Array[Move]
    if dist_to_player > 0.0 and dist_to_player < close_range_threshold:
        candidates = [Move.LUNGE, Move.LUNGE, Move.STRAFE, Move.ORBIT, Move.LUNGE, Move.STRAFE]
    else:
        candidates = [Move.ORBIT, Move.ORBIT, Move.LUNGE, Move.RETREAT, Move.STRAFE, Move.PAUSE]
    if randf() < charge_roll and is_instance_valid(player_target):
        _current_move = Move.CHARGE
        _charge_direction = (player_target.global_position - head.global_position).normalized()
        if _charge_direction.length_squared() < 0.01:
            _charge_direction = Vector2.RIGHT.rotated(head.global_rotation)
        head.move_speed = charge_speed
        _move_duration = randf_range(charge_duration_min, charge_duration_max)
    else:
        _current_move = candidates.pick_random()
        _move_duration = randf_range(move_duration_min, move_duration_max)
    _move_timer = 0.0
    if _current_move == Move.STRAFE:
        _strafe_direction = 1.0 if randf() > 0.5 else -1.0

func _update_ai_target(delta: float) -> void:
    _move_timer += delta
    if _move_timer >= _move_duration:
        _pick_next_move()

    var center: Vector2 = player_target.global_position
    var to_head: Vector2 = head.global_position - center
    var current_angle: float = atan2(to_head.y, to_head.x) if to_head.length_squared() > 1.0 else _orbit_angle
    _orbit_angle = current_angle

    var target_pos: Vector2
    match _current_move:
        Move.ORBIT:
            _orbit_angle += orbit_speed * delta
            var radius: float = orbit_radius * (1.0 + orbit_wobble * sin(_orbit_angle * orbit_wobble_speed))
            target_pos = center + Vector2(cos(_orbit_angle), sin(_orbit_angle)) * radius
        Move.LUNGE:
            _orbit_angle += orbit_speed * delta * 0.7
            var radius: float = orbit_radius * lunge_radius_ratio
            target_pos = center + Vector2(cos(_orbit_angle), sin(_orbit_angle)) * radius
        Move.RETREAT:
            _orbit_angle += orbit_speed * delta * 0.5
            var radius: float = orbit_radius * retreat_radius_ratio
            target_pos = center + Vector2(cos(_orbit_angle), sin(_orbit_angle)) * radius
        Move.STRAFE:
            _orbit_angle += strafe_speed * _strafe_direction * delta
            var radius: float = orbit_radius * (1.0 + orbit_wobble * 0.5 * sin(_orbit_angle * orbit_wobble_speed))
            target_pos = center + Vector2(cos(_orbit_angle), sin(_orbit_angle)) * radius
        Move.PAUSE:
            target_pos = target_node.global_position  # Stay put
        Move.CHARGE:
            target_pos = head.global_position + _charge_direction * 4000.0

    target_node.global_position = target_pos

func _record_head_path() -> void:
    var pos: Vector2 = head.global_position
    if _path.is_empty():
        _path.append({"p": pos, "d": 0.0})
        _path_length = 0.0
        _last_path_pos = pos
        return
    var d: float = _last_path_pos.distance_to(pos)
    var min_points: int = (segments.size() + 1) * 3  # Build trail quickly at start
    var should_add: bool = (d >= path_step) or (_path.size() < min_points and d > 0.5)
    if should_add:
        _path_length += d
        _path.append({"p": pos, "d": _path_length})
        _last_path_pos = pos
        var max_len: float = (segments.size() + 1) * segment_dist * 1.5
        while _path.size() > 1 and _path_length - _path[0]["d"] > max_len:
            _path.pop_front()

func _get_path_position_at_distance(behind: float) -> Vector2:
    if _path.is_empty():
        return head.global_position
    var d: float = _path_length - behind
    if d <= _path[0]["d"]:
        return _path[0]["p"]
    for i in range(_path.size() - 1):
        var a: float = _path[i]["d"]
        var b: float = _path[i + 1]["d"]
        if d >= a and d <= b:
            var t: float = (d - a) / (b - a) if b > a else 0.0
            return _path[i]["p"].lerp(_path[i + 1]["p"], t)
    return _path[-1]["p"]

func _get_path_direction_at_distance(behind: float) -> Vector2:
    if _path.size() < 2:
        return Vector2.RIGHT.rotated(head.global_rotation)
    var d: float = _path_length - behind
    if d <= _path[0]["d"]:
        return (_path[1]["p"] - _path[0]["p"]).normalized()
    for i in range(_path.size() - 1):
        if d >= _path[i]["d"] and d <= _path[i + 1]["d"]:
            return (_path[i + 1]["p"] - _path[i]["p"]).normalized()
    return (_path[-1]["p"] - _path[-2]["p"]).normalized()

func _update_segments_from_path(delta: float) -> void:
    var blend: float = clampf(segment_smooth * delta, 0.0, 1.0)
    for i in range(segments.size()):
        var s: Node2D = segments[i]
        if not is_instance_valid(s):
            continue
        var trail_dist: float = (i + 1) * segment_dist
        var target_pos: Vector2 = _get_path_position_at_distance(trail_dist)
        var current_pos: Vector2 = s.global_position
        s.global_position = current_pos.lerp(target_pos, blend)
        var tangent: Vector2 = _get_path_direction_at_distance(trail_dist)
        var target_angle: float = tangent.angle() + PI * 0.5
        s.global_rotation = lerp_angle(s.global_rotation, target_angle, blend)

func _physics_process(delta: float) -> void:
    if segments.size() == 1 and not _last_segment_mode:
        _enter_last_segment_mode()
    if health_bar:
        health_bar.position = head.position + Vector2(0, -50)


    # During charge: break cells along the path
    if _current_move == Move.CHARGE and _charge_break_tool != null:
        var destroyed: Array[Dictionary] = _charge_break_tool.apply_global_return_destroyed(head.global_position)
        if destroyed.size() > 0 and DestructionManager.instance != null:
            var tile_size: float = ChunkParent.instance.get_tile_size()
            DestructionManager.instance.create_explosion(
                head.global_position,
                destroyed,
                charge_break_radius * tile_size
            )

    _record_head_path()
    _update_segments_from_path(delta)

