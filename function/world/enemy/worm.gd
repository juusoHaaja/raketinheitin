extends Node2D

@onready var head: WormHead = $Head
@onready var target_node:Node2D = $TargetNode
@onready var segment_parent:Node2D = $Segments

@export var segment_dist: float = 100.0

var segments:=Array()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    head.target_node = target_node
    for c in segment_parent.get_children():
        segments.push_back(c)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    target_node.global_position = get_global_mouse_position()

func _physics_process(delta: float) -> void:
    var prev_pos = head.global_position
    for s in segments:
        var pos = s.global_position
        var diff:Vector2 = pos-prev_pos
        var normal = diff.normalized()
        var new_pos = prev_pos+normal*segment_dist
        s.global_position = new_pos
        prev_pos = new_pos
