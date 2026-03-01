extends Node
class_name HealthComponent

## Reusable health component. Add as child to any node (player, enemy, etc.).
## Connect to [signal health_changed] or [signal died] to react.

signal health_changed(current: float, maximum: float)
signal damage_taken(amount: float)
signal died

@export var max_health: float = 100.0

var _current: float = 0.0

var current_health: float:
	set(value):
		_current = clampf(value, 0.0, max_health)
		health_changed.emit(_current, max_health)
		if _current <= 0.0:
			died.emit()
	get:
		return _current


func _ready() -> void:
	_current = max_health


func take_damage(amount: float) -> void:
	damage_taken.emit(amount)
	current_health -= amount


func heal(amount: float) -> void:
	current_health += amount


func is_alive() -> bool:
	return current_health > 0.0


func get_health_ratio() -> float:
	if max_health <= 0.0:
		return 1.0
	return current_health / max_health
