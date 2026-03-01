extends RigidBody2D
class_name FallingParticle

var material_type: int = 1
var lifetime: float = 5.0
var _time_alive: float = 0.0
var _tile_size: float = 16.0

var _sprite: Sprite2D = null
var _collision: CollisionShape2D = null

func _ready() -> void:
	gravity_scale = 2.0
	linear_damp = 0.5
	angular_damp = 2.0
	_sprite = get_node_or_null("Sprite2D")
	_collision = get_node_or_null("CollisionShape2D")

func setup(mat_type: int, life: float, tile_size: float) -> void:
	material_type = mat_type
	lifetime = life
	_tile_size = tile_size
	_setup_sprite()
	rotation = randf() * TAU
	angular_velocity = randf_range(-5.0, 5.0)
	linear_velocity = Vector2(randf_range(-20, 20), 0)

func _setup_sprite() -> void:
	if not _sprite:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite2D"
		add_child(_sprite)
	var img: Image = Image.create(int(_tile_size), int(_tile_size), false, Image.FORMAT_RGBA8)
	img.fill(_get_material_color())
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_sprite.texture = tex
	_sprite.centered = true
	var shape_size: Vector2 = Vector2(_tile_size * 0.8, _tile_size * 0.8)
	if not _collision:
		_collision = CollisionShape2D.new()
		_collision.name = "CollisionShape2D"
		var shape: RectangleShape2D = RectangleShape2D.new()
		shape.size = shape_size
		_collision.shape = shape
		add_child(_collision)
	elif _collision.shape is RectangleShape2D:
		(_collision.shape as RectangleShape2D).size = shape_size

func _get_material_color() -> Color:
	match material_type:
		1: return Color(0.6, 0.4, 0.2)
		2: return Color(0.5, 0.5, 0.5)
		3: return Color(0.7, 0.6, 0.3)
		4: return Color(0.3, 0.5, 0.7)
		5: return Color(0.8, 0.7, 0.5)
		_: return Color(0.5, 0.5, 0.5)

func _process(delta: float) -> void:
	_time_alive += delta
	if _time_alive > lifetime * 0.8:
		var fade_progress: float = (_time_alive - lifetime * 0.8) / (lifetime * 0.2)
		modulate.a = 1.0 - fade_progress
	if _time_alive >= lifetime:
		queue_free()
