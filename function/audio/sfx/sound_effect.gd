extends Node2D
class_name SoundEffect

@export var volume_db:float = -10.0

var variations = Array()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    for c in get_children():
        if c is AudioStreamPlayer:
            variations.push_back(c)
            c.volume_db = volume_db

func play_random():
    variations.shuffle()
    for v:AudioStreamPlayer in variations:
        if not v.playing:
            v.play()
            break

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    pass
