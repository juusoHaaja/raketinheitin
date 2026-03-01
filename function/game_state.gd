# game_state.gd
# Autoload for persisting highscore and settings across sessions.
extends Node

const SAVE_PATH := "user://highscore.cfg"
const SETTINGS_PATH := "user://settings.cfg"
const KEY_HIGHSCORE := "highscore"
const KEY_PERFORMANCE_MODE := "performance_mode"

var highscore: int = 0

## Performance mode: when true, fog of war is disabled for better performance.
var performance_mode: bool = true

func _ready() -> void:
	load_highscore()
	load_settings()

func load_highscore() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err == OK:
		highscore = cfg.get_value("game", KEY_HIGHSCORE, 0)
	else:
		highscore = 0

func save_highscore(value: int) -> void:
	if value <= highscore:
		return
	highscore = value
	var cfg := ConfigFile.new()
	cfg.set_value("game", KEY_HIGHSCORE, highscore)
	cfg.save(SAVE_PATH)

func load_settings() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SETTINGS_PATH)
	if err == OK:
		performance_mode = cfg.get_value("settings", KEY_PERFORMANCE_MODE, true)
	else:
		performance_mode = true

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", KEY_PERFORMANCE_MODE, performance_mode)
	cfg.save(SETTINGS_PATH)
