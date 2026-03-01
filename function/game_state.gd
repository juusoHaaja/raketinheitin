# game_state.gd
# Autoload for persisting highscore across sessions.
extends Node

const SAVE_PATH := "user://highscore.cfg"
const KEY_HIGHSCORE := "highscore"

var highscore: int = 0

func _ready() -> void:
	load_highscore()

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
