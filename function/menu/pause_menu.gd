extends Control

signal closed

@onready var canvas_layer: CanvasLayer = get_parent()
@onready var settings_button: Button = $MarginContainer/VBox/SettingsButton
@onready var main_menu_button: Button = $MarginContainer/VBox/MainMenuButton
@onready var quit_button: Button = $MarginContainer/VBox/QuitButton
@onready var settings_popup: PopupPanel = $SettingsPopup
@onready var performance_option: OptionButton = $SettingsPopup/MarginContainer/VBox/PerformanceRow/OptionButton
@onready var close_settings_button: Button = $SettingsPopup/MarginContainer/VBox/CloseButton

const MAIN_MENU_SCENE := "res://function/menu/main_menu.tscn"


func _ready() -> void:
	settings_button.pressed.connect(_on_settings_pressed)
	main_menu_button.pressed.connect(_on_main_menu_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	close_settings_button.pressed.connect(_on_close_settings)
	performance_option.item_selected.connect(_on_performance_changed)
	_refresh_performance_option()


func _refresh_performance_option() -> void:
	performance_option.selected = 1 if GameState.performance_mode else 0


func _on_settings_pressed() -> void:
	_refresh_performance_option()
	settings_popup.popup_centered()


func _on_close_settings() -> void:
	settings_popup.hide()


func _on_performance_changed(index: int) -> void:
	GameState.performance_mode = (index == 1)
	GameState.save_settings()


func _on_main_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if settings_popup.visible:
			settings_popup.hide()
			get_viewport().set_input_as_handled()
		else:
			closed.emit()
			hide_pause_menu()
			get_viewport().set_input_as_handled()


func show_pause_menu() -> void:
	canvas_layer.visible = true
	get_tree().paused = true


func hide_pause_menu() -> void:
	canvas_layer.visible = false
	get_tree().paused = false
