extends Node2D
class_name GrappleLine

var anchor: Vector2 = Vector2.ZERO
var cut_offset: float = 50.0
var max_length: float = 1000.0
var hook_velocity: float = 3000.0

enum LineState {
    ATTACHED,
    SHOT,
    RETURNING
}

var state: LineState = LineState.SHOT

var shot_dir: Vector2 = Vector2.ZERO

@onready var line2d: Line2D = $Line2D
@onready var raycast: RayCast2D = $RayCast2D
@onready var player: Player = get_parent().get_parent()
@onready var hook: Node2D = $HookHolder/Hook
@onready var hook_raycast: RayCast2D = $HookHolder/Hook/RayCast2D

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    position = player.global_position

func _physics_process(delta: float) -> void:
    position = player.global_position


    if state == LineState.SHOT:
        shoot_update(delta)
    if state == LineState.ATTACHED:
        update()
    if state == LineState.RETURNING:
        return_update(delta)

func update():
    raycast.target_position = to_local(anchor)

    raycast.force_raycast_update()

    if raycast.is_colliding():
        if (raycast.get_collision_point().distance_squared_to(global_position) + cut_offset * cut_offset) / get_length_squared() < 0.8 * 0.8:
            reel_in()
    
    if get_length_squared() > max_length * max_length:
        reel_in()

    update_line()

    if check_if_empty_terrain(anchor):
        reel_in()


func update_anchor(global_pos: Vector2):
    anchor = global_pos


func get_angle_vector() -> Vector2:
    if state != LineState.ATTACHED:
        return Vector2.ZERO
    return (anchor - global_position).normalized()


func get_length() -> float:
    if state != LineState.ATTACHED:
        return 0.0
    return (anchor - global_position).length()


func get_length_squared() -> float:
    if state != LineState.ATTACHED:
        return 0.0
    return (anchor - global_position).length_squared()


func shoot(pos: Vector2, dir: Vector2):
    state = LineState.SHOT
    hook.visible = true

    shot_dir = dir

    hook.position = pos
    hook_raycast.target_position = dir


func shoot_update(delta: float):
    hook_raycast.target_position = shot_dir * hook_velocity * delta
    hook_raycast.force_raycast_update()

    anchor = hook.global_position
    update_line()

    if hook_raycast.is_colliding():
        var collision_point = hook_raycast.get_collision_point()
        anchor = collision_point

        hook.visible = false

        state = LineState.ATTACHED

    hook.position += shot_dir * hook_velocity * delta

    if hook.global_position.distance_squared_to(player.global_position) > max_length * max_length:
        reel_in()
    

func return_update(delta: float):
    hook.position += hook.position.direction_to(player.global_position) * hook_velocity * delta

    anchor = hook.position
    update_line()

    if hook.position.distance_squared_to(player.global_position) < hook_velocity * delta * hook_velocity * delta:
        queue_free()


func reel_in():
    state = LineState.RETURNING
    hook.visible = true


func update_line():
    line2d.set_point_position(1, to_local(anchor))


func check_if_empty_terrain(pos: Vector2) -> bool:
    var chunk_parent := ChunkParent.instance

    var cooler_pos = pos - Vector2(2.0, 2.0)

    for i in 3:
        for j in 3:
            var even_cooler_pos = cooler_pos + Vector2(i, j)
            if chunk_parent.api_get_tile_pos(chunk_parent.snap_global_to_grid(even_cooler_pos)) != 0:
                return false

    return true