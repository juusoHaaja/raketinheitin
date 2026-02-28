extends Node2D

@export var map_width = 100
@export var map_height = 100

var cells = PackedByteArray()

func clear_cells():
    cells.clear()

func create_cells():
    clear_cells()
    for i in range(map_height):
        for l in range(map_width):
            cells.push(0)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass
