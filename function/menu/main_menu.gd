extends Control

@onready var play_button: Button = $HBox/LeftPanel/MarginContainer/VBox/PlayButton
@onready var quit_button: Button = $HBox/LeftPanel/MarginContainer/VBox/QuitButton

const MAIN_SCENE := "res://function/world/main.tscn"


func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _on_play_pressed() -> void:
    get_tree().change_scene_to_file(MAIN_SCENE)


func _on_quit_pressed() -> void:
    get_tree().quit()
