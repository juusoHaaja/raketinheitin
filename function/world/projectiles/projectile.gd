# projectiles/projectile.gd
extends Area2D
class_name Projectile

@export var speed: float = 1000.0
@export var explosion_radius: float = 4.0
@export var lifetime: float = 5.0

var velocity: Vector2 = Vector2.ZERO
var circle_tool: CircleTool
var time_alive: float = 0.0

func initialize(start_pos: Vector2, direction: Vector2, p_circle_tool: TileTool):
    global_position = start_pos
    velocity = direction.normalized() * speed
    circle_tool = p_circle_tool
    body_entered.connect(_on_body_entered)

func _physics_process(delta: float):
    position += velocity * delta
    
    time_alive += delta
    if time_alive >= lifetime:
        queue_free()

func explode():
    circle_tool.radius = explosion_radius
    
    # Get destroyed tiles before applying
    var center := ChunkParent.instance.snap_global_to_grid(global_position)
    var destroyed := _collect_tiles_in_radius(center)
    
    # Apply destruction to tilemap
    circle_tool.apply_global(global_position)
    
    # Spawn all effects via DestructionManager
    if DestructionManager.instance != null:
        var tile_size: float = ChunkParent.instance.chunks[0].tile_set.tile_size.x
        DestructionManager.instance.create_explosion(
            global_position,
            destroyed,
            explosion_radius * tile_size
        )
    
    queue_free()

func _collect_tiles_in_radius(center: Vector2i) -> Array[Dictionary]:
    var tiles: Array[Dictionary] = []
    var radius_int := int(ceil(explosion_radius))
    var radius_sq := explosion_radius * explosion_radius
    
    for y in range(center.y - radius_int, center.y + radius_int + 1):
        for x in range(center.x - radius_int, center.x + radius_int + 1):
            var pos := Vector2i(x, y)
            var dist_sq := Vector2(center).distance_squared_to(Vector2(pos))
            
            if dist_sq <= radius_sq:
                var tile := ChunkParent.instance.api_get_tile_pos(pos)
                if tile != 0:
                    tiles.append({
                        "position": pos,
                        "material": tile
                    })
    
    return tiles

func _on_body_entered(_body: Node2D):
    explode()
