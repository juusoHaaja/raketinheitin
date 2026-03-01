# world/main.gd
extends Node2D
class_name Main

var instance: Main

@export var projectile_scene: PackedScene
@export var grappling_hook_scene: PackedScene

@export var player: Player

var circle_tool: CircleTool

@onready var chunk_parent: ChunkParent = $ChunkParent
@onready var fog_of_war: Node2D = $FogOfWar

func _enter_tree() -> void:
    instance = self

func _ready():
    if DestructionManager.instance == null:
        var dm = DestructionManager.new()
        dm.name = "DestructionManager"
        add_child(dm)
    
        circle_tool = CircleTool.new(16.0)

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

        if player == null:
            push_error("Failed to find player")
            return

        if event.button_index == MOUSE_BUTTON_RIGHT:
            shoot_grappling_hook()
            if player.line_holder.get_child_count() > player.get_max_grappling_hooks():
                player.line_holder.get_children()[0].reel_in()

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
    if fog_of_war != null and fog_of_war.has_method("track_projectile"):
        fog_of_war.track_projectile(rocket)
        rocket.tree_exiting.connect(func(): fog_of_war.untrack_projectile(rocket))
    rocket.exploded.connect(func(): _on_rocket_exploded(rocket))

func _on_rocket_exploded(rocket: Projectile) -> void:
    if fog_of_war == null or not fog_of_war.has_method("add_explosion_flash"):
        return
    fog_of_war.add_explosion_flash(rocket.global_position, rocket.explosion_radius)


func shoot_grappling_hook():
    if grappling_hook_scene == null:
        push_error("Assign hook projectile scene in inspector!")
        return

    var grappling_hook: GrappleLine = grappling_hook_scene.instantiate()

    if grappling_hook == null:
        push_error("Failed to instantiate hook projectile!")
        return

    if player == null:
        push_error("Failed to find player")
        return
    
    player.line_holder.add_child(grappling_hook)

    var start_pos = get_viewport_rect().size / 2.0
    start_pos = get_canvas_transform().affine_inverse() * start_pos
    var target_pos = get_global_mouse_position()
    var direction = (target_pos - start_pos).normalized()

    grappling_hook.shoot(start_pos, direction)
