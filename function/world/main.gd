# world/main.gd
extends Node2D

@export var projectile_scene: PackedScene

var circle_tool: CircleTool

@onready var chunk_parent: ChunkParent = $ChunkParent

func _ready():
    if DestructionManager.instance == null:
        var dm = DestructionManager.new()
        dm.name = "DestructionManager"
        add_child(dm)
    
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
    add_child(rocket)
