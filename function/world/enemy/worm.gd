extends Node2D

@onready var head: WormHead = $Head
@onready var target_node:Node2D = $TargetNode
@onready var segment_parent:Node2D = $Segments
@onready var line: Line2D = $Line2D

@export var segment_dist: float = 100.0

var sample_count: int = 100
var segment_count: int = 7
var segment_total_length: float = 1000.0

var segments: Array[Sprite2D]

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    for num in segment_count:
        var newsprite = Sprite2D.new()
        segment_parent.add_child(newsprite)
        segments.push_back(newsprite)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    target_node.global_position = get_global_mouse_position()

func _physics_process(delta: float) -> void:
    pass

func line_segment_from_length(length: float) -> int:
    for i in line.points.size():
        if i == line.points.size():
            return 0
        return 1
    return 0
