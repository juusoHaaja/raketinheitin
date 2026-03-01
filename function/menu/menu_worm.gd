extends RigidBody2D

## Worm that wanders randomly for the menu preview. No player input; view is fixed.
## Sprite is hidden so we don't show placeholder art (icon) in the menu.

@onready var sprite: Sprite2D = $Sprite2D

## Center of the area the worm should stay in (world position)
@export var bounds_center: Vector2 = Vector2(400, 300)
## Half-size of the bounding box (worm stays within center ± bounds_half)
@export var bounds_half: Vector2 = Vector2(280, 160)

var _move_timer: float = 0.0
var _direction: float = 1.0  # -1 or 1 for left/right
const MOVE_FORCE: float = 8000.0
const JUMP_FORCE: float = 22000.0
const DIRECTION_CHANGE_TIME: float = 1.2
const JUMP_CHANCE: float = 0.15  # per direction tick


func _ready() -> void:
	freeze = true
	freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
	_direction = 1.0 if randf() > 0.5 else -1.0
	if sprite:
		sprite.visible = false  # No placeholder/icon in menu preview
	# Wait for ChunkParent to generate terrain around this worm (it's in group "player")
	while not ChunkParent.instance or not ChunkParent.instance._initial_generation_complete:
		await get_tree().process_frame
	var chunk_parent: ChunkParent = ChunkParent.instance
	var my_tile: Vector2i = chunk_parent.snap_global_to_grid(global_position)
	var my_chunk: Vector2i = chunk_parent.get_chunk_pos(my_tile)
	chunk_parent._force_generate_area(my_chunk, 3)
	while not _chunks_ready_for_worm(chunk_parent):
		chunk_parent._force_generate_area(my_chunk, 2)
		await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	freeze = false


func _chunks_ready_for_worm(cp: ChunkParent) -> bool:
	var my_tile: Vector2i = cp.snap_global_to_grid(global_position)
	var my_chunk: Vector2i = cp.get_chunk_pos(my_tile)
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var p: Vector2i = my_chunk + Vector2i(dx, dy)
			if not cp.is_generated(p):
				return false
			var ch: Chunk = cp.get_chunk_if_exists(p)
			if not ch or not ch.generation_complete:
				return false
	return true


func _physics_process(delta: float) -> void:
	_move_timer -= delta
	if _move_timer <= 0.0:
		_move_timer = randf_range(DIRECTION_CHANGE_TIME * 0.6, DIRECTION_CHANGE_TIME)
		_direction = -_direction
		if randf() < JUMP_CHANCE:
			apply_central_force(Vector2.UP * JUMP_FORCE)

	apply_central_force(Vector2(_direction * MOVE_FORCE, 0) * delta)
	sprite.flip_h = _direction < 0

	# Keep worm within bounds (soft clamp by nudging back)
	var pos := global_position
	if pos.x < bounds_center.x - bounds_half.x:
		apply_central_force(Vector2.RIGHT * MOVE_FORCE * 2.0 * delta)
	elif pos.x > bounds_center.x + bounds_half.x:
		apply_central_force(Vector2.LEFT * MOVE_FORCE * 2.0 * delta)
	if pos.y < bounds_center.y - bounds_half.y:
		apply_central_force(Vector2.DOWN * 2000.0 * delta)
	elif pos.y > bounds_center.y + bounds_half.y:
		apply_central_force(Vector2.UP * 2000.0 * delta)
