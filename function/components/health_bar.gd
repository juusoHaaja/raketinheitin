extends Node2D
class_name HealthBar

## Draws a health bar. Parent must have a child "Health" (HealthComponent).
## Position this node where the bar should appear (e.g. above an enemy).

@export var bar_width: float = 40.0
@export var bar_height: float = 5.0
@export var outline_size: float = 1.0
@export var offset_y: float = -45.0

var _health: HealthComponent = null

func _ready() -> void:
	_health = get_parent().get_node_or_null("Health") as HealthComponent
	if _health:
		_health.health_changed.connect(_on_health_changed)
	queue_redraw()

func _on_health_changed(_current: float, _maximum: float) -> void:
	queue_redraw()

func _draw() -> void:
	if _health == null:
		return
	var ratio: float = _health.get_health_ratio()
	# Outline
	draw_rect(Rect2(-bar_width / 2 - outline_size, -bar_height / 2 - outline_size, bar_width + outline_size * 2, bar_height + outline_size * 2), Color.BLACK)
	# Background
	draw_rect(Rect2(-bar_width / 2, -bar_height / 2, bar_width, bar_height), Color(0.2, 0.2, 0.2))
	# Fill
	var fill_w: float = bar_width * ratio
	if fill_w > 0:
		var fill_color: Color = Color.GREEN
		if ratio < 0.5:
			fill_color = Color.YELLOW
		if ratio < 0.25:
			fill_color = Color.RED
		draw_rect(Rect2(-bar_width / 2, -bar_height / 2, fill_w, bar_height), fill_color)
