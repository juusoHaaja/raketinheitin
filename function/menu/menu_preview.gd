extends Node2D

## Menu preview: only ChunkParent (random seed map). No fog, no player.
## main_menu sets ChunkParent.world_seed = randi() so terrain is different each time.

@onready var camera: Camera2D = $Camera2D
@onready var chunk_parent: ChunkParent = $ChunkParent

const PREVIEW_CENTER := Vector2(400.0, 300.0)


func _ready() -> void:
	camera.make_current()
	camera.position = PREVIEW_CENTER
	call_deferred("_force_terrain_around_preview")


func _force_terrain_around_preview() -> void:
	if not is_instance_valid(chunk_parent):
		return
	if not chunk_parent._initial_generation_complete or chunk_parent.get_tile_size() <= 0.0:
		return
	var center_chunk: Vector2i = chunk_parent.get_chunk_pos(chunk_parent.snap_global_to_grid(PREVIEW_CENTER))
	chunk_parent._force_generate_area(center_chunk, 8)
	chunk_parent.flush_all_pending_tilemap_visuals()
