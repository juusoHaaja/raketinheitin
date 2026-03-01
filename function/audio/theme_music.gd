extends Node

const THEME_PATH := "res://audio/theme.mp3"

var _player: AudioStreamPlayer


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	var stream: AudioStream = load(THEME_PATH) as AudioStream
	if stream is AudioStreamMP3:
		stream.loop = true
	_player.stream = stream
	_player.play()
