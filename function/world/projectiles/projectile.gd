# projectiles/projectile.gd
extends Area2D
class_name Projectile

@export var speed: float = 400.0
@export var explosion_radius: float = 4.0
@export var lifetime: float = 5.0

var velocity: Vector2 = Vector2.ZERO
var circle_tool: CircleTool
var time_alive: float = 0.0

func initialize(start_pos: Vector2, direction: Vector2, p_circle_tool: CircleTool):
    global_position = start_pos
    velocity = direction.normalized() * speed
    circle_tool = p_circle_tool

func _physics_process(delta: float):
    position += velocity * delta
    
    time_alive += delta
    if time_alive >= lifetime:
        queue_free()
        return "disable_mode"
    
    var grid = circle_tool.grid
    var grid_pos = grid.global_to_grid(global_position)
    
    # Bounds check
    if grid_pos.x < 0 or grid_pos.x >= grid.map_width:
        return
    if grid_pos.y < 0 or grid_pos.y >= grid.map_height:
        return
    
    var tile = grid.api_get_tile_pos(grid_pos)
    if tile != 0:
        explode()

func explode():
    circle_tool.radius = explosion_radius
    circle_tool.selected_tile = 0  # Destroy tiles
    circle_tool.apply_global(global_position)
    queue_free()
