# world/main.gd
extends Node2D
class_name Main

var instance: Main

@export var projectile_scene: PackedScene
@export var grappling_hook_scene: PackedScene

@export var player: Player

var circle_tool: CircleTool

@onready var chunk_parent: ChunkParent = $ChunkParent

func _enter_tree() -> void:
    instance = self

func _ready():
    circle_tool = CircleTool.new(6.0)

func _unhandled_input(event: InputEvent):
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_LEFT:
            shoot_rocket()
        
        # Scroll to change explosion size
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            circle_tool.set_radius(circle_tool.radius + 0.5)
            print("Explosion radius: ", circle_tool.radius)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            circle_tool.set_radius(circle_tool.radius - 0.5)
            print("Explosion radius: ", circle_tool.radius)

func shoot_rocket():
    if projectile_scene == null:
        push_error("Assign projectile scene in inspector!")
        return
    
    var rocket = projectile_scene.instantiate()
    
    if rocket == null:
        push_error("Failed to instantiate projectile!")
        return
    
    var start_pos = get_viewport_rect().size / 2.0
    start_pos = get_canvas_transform().affine_inverse() * start_pos
    var target_pos = get_global_mouse_position()
    var direction = (target_pos - start_pos).normalized()
    
    rocket.explosion_radius = circle_tool.radius
    rocket.initialize(start_pos, direction, circle_tool)
    rocket.connect("exploded", player.boom)
    add_child(rocket)


func shoot_grappling_hook():
    if projectile_scene == null:
        push_error("Assign hook projectile scene in inspector!")
        return

    var grappling_hook: GrappleLine = grappling_hook_scene.instantiate()

    if grappling_hook == null:
        push_error("Failed to instantiate hook projectile!")
        return



    var start_pos = get_viewport_rect().size / 2.0
    start_pos = get_canvas_transform().affine_inverse() * start_pos
    var target_pos = get_global_mouse_position()
    var direction = (target_pos - start_pos).normalized()

    grappling_hook.shoot(start_pos, direction)

