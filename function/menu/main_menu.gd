extends Control

@onready var play_button: Button = $HBox/LeftPanel/MarginContainer/VBox/PlayButton
@onready var settings_button: Button = $HBox/LeftPanel/MarginContainer/VBox/SettingsButton
@onready var quit_button: Button = $HBox/LeftPanel/MarginContainer/VBox/QuitButton
@onready var settings_popup: PopupPanel = $SettingsPopup
@onready var performance_option: OptionButton = $SettingsPopup/MarginContainer/VBox/PerformanceRow/OptionButton
@onready var close_button: Button = $SettingsPopup/MarginContainer/VBox/CloseButton

const MAIN_SCENE := "res://function/world/main.tscn"


func _ready() -> void:
    play_button.pressed.connect(_on_play_pressed)
    settings_button.pressed.connect(_on_settings_pressed)
    quit_button.pressed.connect(_on_quit_pressed)
    close_button.pressed.connect(_on_close_settings)
    performance_option.item_selected.connect(_on_performance_changed)
    _refresh_performance_option()


func _refresh_performance_option() -> void:
    performance_option.selected = 1 if GameState.performance_mode else 0


func _on_play_pressed() -> void:
    get_tree().change_scene_to_file(MAIN_SCENE)


func _on_settings_pressed() -> void:
    _refresh_performance_option()
    settings_popup.popup_centered()


func _on_close_settings() -> void:
    settings_popup.hide()


func _on_performance_changed(index: int) -> void:
    GameState.performance_mode = (index == 1)
    GameState.save_settings()


func _on_quit_pressed() -> void:
    get_tree().quit()
