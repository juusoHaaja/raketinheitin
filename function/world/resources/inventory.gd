extends Node2D
class_name Inventory

@onready var collection_area = $Area2D
var gems = Array()

func add_gem(type: int, count: int):
    populate_gems(type)
    gems[type]+= count

func has_enough_gems(type:int, count:int) -> bool:
    populate_gems(type)
    return gems[type] >= count

func remove_gems(type:int, count:int):
    populate_gems(type)
    gems[type] -= count

func populate_gems(up_to_type: int):
    var diff = up_to_type-gems.size()+1
    if diff > 0:
        for i in range(diff):
            gems.push_back(0)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    collection_area.connect("body_entered", body_enter)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass

func body_enter(body:Node2D):
    if body is Gem:
        add_gem(body.gem_type, 1)
        body.queue_free()
