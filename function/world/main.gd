# world/main.gd
extends Node2D
class_name Main

var instance: Main

@export var projectile_scene: PackedScene
@export var grappling_hook_scene: PackedScene
@export var worm_scene: PackedScene

@export var player: Player

var circle_tool: CircleTool

@onready var chunk_parent: ChunkParent = $ChunkParent
@onready var fog_of_war: Node2D = $FogOfWar
@onready var ui_layer: CanvasLayer = $UI
@onready var player_health_bar: ProgressBar = $UI/PlayerHealthBar
@onready var worm_health_bar: ProgressBar = $WormBarContainer/WormHealthBar
@onready var worm_segment_bars_container: Node2D = $WormBarContainer
@onready var game_over_layer: Control = $UI/GameOverLayer
@onready var restart_button: Button = $UI/GameOverLayer/VBox/RestartButton
@onready var grappling_reminder_label: Label = $UI/GrapplingReminderLabel
@onready var score_label: Label = $UI/ScoreLabel
@onready var worm_count_label: Label = $UI/WormCountLabel
@onready var next_worm_label: Label = $UI/NextWormLabel
@onready var game_over_score_label: Label = $UI/GameOverLayer/VBox/ScoreLabel
@onready var game_over_highscore_label: Label = $UI/GameOverLayer/VBox/HighscoreLabel

var _worms: Array[Node2D] = []
var _worm: Node2D = null  ## Primary/first worm for health bar display
var _grappling_hook_used: bool = false
var _grappling_reminder_timer: float = 0.0
var _grappling_reminder_shown: bool = false
var _worm_segment_bars: Array[ProgressBar] = []
const WORM_SEGMENT_BAR_SIZE: Vector2 = Vector2(40, 6)

## Firing cooldown so player cannot spam rockets
const FIRE_COOLDOWN: float = 0.4
var _fire_cooldown_timer: float = 0.0

## Score: 1 per damage, bonus per worm kill
const SCORE_PER_DAMAGE: float = 1.0
const SCORE_PER_WORM_KILL: int = 100
var _score: int = 0

## Progressive worm spawning
const INITIAL_WORM_COUNT: int = 1
const SPAWN_INTERVAL_START: float = 45.0  ## Seconds until 2nd worm
const SPAWN_INTERVAL_DECAY: float = 0.92  ## Each spawn shortens next interval (e.g. 45, 41, 38...)
const SPAWN_INTERVAL_MIN: float = 12.0
var _next_worm_spawn_timer: float = 0.0
var _spawn_interval: float = SPAWN_INTERVAL_START

func _enter_tree() -> void:
    instance = self

func _ready():
    if fog_of_war != null:
        fog_of_war.fog_enabled = not GameState.performance_mode
    if DestructionManager.instance == null:
        var dm = DestructionManager.new()
        dm.name = "DestructionManager"
        add_child(dm)

        circle_tool = CircleTool.new(16.0)

    if player:
        player.health.health_changed.connect(_on_player_health_changed)
        player.health.died.connect(_on_player_died)
        _update_player_health_bar()

    game_over_layer.visible = false
    if grappling_reminder_label:
        grappling_reminder_label.visible = false
    _score = 0
    _update_score_display()
    # Keep UI processing when game is paused so Restart button works
    ui_layer.process_mode = Node.PROCESS_MODE_ALWAYS
    if restart_button:
        restart_button.pressed.connect(_on_restart_pressed)

    _spawn_worm()

func _process(delta: float) -> void:
    if _fire_cooldown_timer > 0.0:
        _fire_cooldown_timer -= delta
    _update_worm_health_bar()
    _update_progressive_spawn(delta)
    _update_worm_segment_bars()
    _update_worm_ui_labels()
    # Show grappling hook reminder after 10s if player hasn't used right click
    if not _grappling_hook_used and not _grappling_reminder_shown and grappling_reminder_label:
        _grappling_reminder_timer += delta
        if _grappling_reminder_timer >= 10.0:
            _grappling_reminder_shown = true
            grappling_reminder_label.visible = true

func _update_worm_health_bar() -> void:
    if not is_instance_valid(_worm):
        worm_health_bar.visible = false
        return
    var head: Node2D = _worm.get_node_or_null("Head")
    var worm_health_node: Node = _worm.get_node_or_null("Health")
    if not head or not worm_health_node:
        worm_health_bar.visible = false
        return
    var worm_health: HealthComponent = worm_health_node as HealthComponent
    if not worm_health:
        worm_health_bar.visible = false
        return
    var segments_parent: Node = _worm.get_node_or_null("Segments")
    var segs: Array[Node] = segments_parent.get_children() if segments_parent else []
    var total_max: float = worm_health.max_health
    var total_current: float = worm_health.current_health
    if segs.size() > 1:
        for seg in segs:
            var sh: HealthComponent = (seg as Node).get_node_or_null("Health") as HealthComponent
            if sh:
                total_max += sh.max_health
                total_current += sh.current_health
    else:
        total_max = worm_health.max_health
        total_current = worm_health.current_health
    var world_pos: Vector2 = head.global_position + Vector2(0, -50)
    worm_health_bar.position = world_pos - Vector2(worm_health_bar.size.x * 0.5, 20.0)
    worm_health_bar.max_value = total_max
    worm_health_bar.value = total_current
    worm_health_bar.visible = true

func _ensure_worm_segment_bars(count: int) -> void:
    while _worm_segment_bars.size() < count:
        var bar: ProgressBar = ProgressBar.new()
        bar.custom_minimum_size = WORM_SEGMENT_BAR_SIZE
        bar.size = WORM_SEGMENT_BAR_SIZE
        bar.show_percentage = false
        bar.visible = false
        bar.set_anchors_preset(Control.PRESET_TOP_LEFT)
        worm_segment_bars_container.add_child(bar)
        _worm_segment_bars.append(bar)

func _update_worm_segment_bars() -> void:
    for b in _worm_segment_bars:
        b.visible = false
    if not is_instance_valid(_worm):
        return
    var segments_parent: Node = _worm.get_node_or_null("Segments")
    if not segments_parent:
        return
    var segs: Array[Node] = segments_parent.get_children()
    if segs.size() <= 1:
        return
    _ensure_worm_segment_bars(segs.size())
    for i in range(segs.size()):
        var seg: Node2D = segs[i] as Node2D
        if not is_instance_valid(seg):
            continue
        var health_node: Node = seg.get_node_or_null("Health")
        var seg_health: HealthComponent = health_node as HealthComponent
        if not seg_health:
            continue
        var bar: ProgressBar = _worm_segment_bars[i]
        var world_pos: Vector2 = seg.global_position + Vector2(0, -25)
        bar.position = world_pos - Vector2(WORM_SEGMENT_BAR_SIZE.x * 0.5, 10.0)
        bar.max_value = seg_health.max_health
        bar.value = seg_health.current_health
        bar.visible = true

func _on_player_health_changed(_current: float, _maximum: float) -> void:
    _update_player_health_bar()

func _update_player_health_bar() -> void:
    if player_health_bar and player and player.health:
        player_health_bar.max_value = player.health.max_health
        player_health_bar.value = player.health.current_health

func _on_player_died() -> void:
    if _score > GameState.highscore:
        GameState.save_highscore(_score)
    if game_over_score_label:
        game_over_score_label.text = "Score: %d" % _score
    if game_over_highscore_label:
        game_over_highscore_label.text = "Highscore: %d" % GameState.highscore
    game_over_layer.visible = true
    get_tree().paused = true

func _on_restart_pressed() -> void:
    get_tree().paused = false
    get_tree().reload_current_scene()

func _on_player_damage_dealt(amount: float) -> void:
    _score += int(amount * SCORE_PER_DAMAGE)
    _update_score_display()

func _update_score_display() -> void:
    if score_label:
        score_label.text = "Score: %d | Best: %d" % [_score, GameState.highscore]

func _update_worm_ui_labels() -> void:
    if worm_count_label:
        worm_count_label.text = "Worms: %d" % _worms.size()
    if next_worm_label:
        if not player or not player.health or not player.health.is_alive():
            next_worm_label.visible = false
        else:
            next_worm_label.visible = true
            var remaining := _spawn_interval - _next_worm_spawn_timer
            next_worm_label.text = "Next worm in %ds" % maxi(0, floori(remaining))

func _update_progressive_spawn(delta: float) -> void:
    if not player or not player.health or not player.health.is_alive():
        return
    _next_worm_spawn_timer += delta
    if _next_worm_spawn_timer >= _spawn_interval:
        _next_worm_spawn_timer = 0.0
        _spawn_interval = maxf(SPAWN_INTERVAL_MIN, _spawn_interval * SPAWN_INTERVAL_DECAY)
        _spawn_worm()

func _on_worm_died(worm: Node2D) -> void:
    _worms.erase(worm)
    _score += SCORE_PER_WORM_KILL
    _update_score_display()
    if _worm == worm:
        _worm = _worms[0] if _worms.size() > 0 else null

func _spawn_worm() -> void:
    if worm_scene == null or player == null:
        return
    var worm: Node2D = worm_scene.instantiate()
    if worm == null:
        return
    var angle := randf() * TAU
    var dist := randf_range(180.0, 280.0)
    worm.global_position = player.global_position + Vector2(cos(angle), sin(angle)) * dist
    if worm.has_method("set_player_target"):
        worm.set_player_target(player)
    add_child(worm)
    _worms.append(worm)
    if _worm == null:
        _worm = worm
    var worm_health: Node = worm.get_node_or_null("Health")
    if worm_health is HealthComponent:
        (worm_health as HealthComponent).died.connect(_on_worm_died.bind(worm))

func _unhandled_input(event: InputEvent):
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if _fire_cooldown_timer <= 0.0:
                shoot_rocket()
                _fire_cooldown_timer = FIRE_COOLDOWN

        # Scroll to change explosion size (commented out)
        #if event.button_index == MOUSE_BUTTON_WHEEL_UP:
        #    circle_tool.set_radius(circle_tool.radius + 0.5)
        #    print("Explosion radius: ", circle_tool.radius)
        #elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
        #    circle_tool.set_radius(circle_tool.radius - 0.5)
        #    print("Explosion radius: ", circle_tool.radius)

        if player == null:
            push_error("Failed to find player")
            return

        if event.button_index == MOUSE_BUTTON_RIGHT:
            _grappling_hook_used = true
            if grappling_reminder_label:
                grappling_reminder_label.visible = false
            shoot_grappling_hook()
            if player.line_holder.get_child_count() > player.get_max_grappling_hooks():
                player.line_holder.get_children()[0].reel_in()

func shoot_rocket() -> void:
    if projectile_scene == null:
        push_error("Assign projectile scene in inspector!")
        return

    var rocket = projectile_scene.instantiate()

    if rocket == null:
        push_error("Failed to instantiate projectile!")
        return

    var start_pos = get_viewport_rect().size / 2.0
    start_pos = get_canvas_transform().affine_inverse() * start_pos
    var target_pos = get_global_mouse_position()
    var direction = (target_pos - start_pos).normalized()

    rocket.explosion_radius = circle_tool.radius
    rocket.initialize(start_pos, direction, circle_tool)
    rocket.ignore_body = player
    rocket.connect("exploded", player.boom)
    add_child(rocket)
    if fog_of_war != null and fog_of_war.has_method("track_projectile"):
        fog_of_war.track_projectile(rocket)
        rocket.tree_exiting.connect(func(): fog_of_war.untrack_projectile(rocket))
    rocket.exploded.connect(func(): _on_rocket_exploded(rocket))
    if rocket.has_signal("damage_dealt"):
        rocket.damage_dealt.connect(_on_player_damage_dealt)

func _on_rocket_exploded(rocket: Projectile) -> void:
    if fog_of_war == null or not fog_of_war.has_method("add_explosion_flash"):
        return
    fog_of_war.add_explosion_flash(rocket.global_position, rocket.explosion_radius)


func shoot_grappling_hook():
    if grappling_hook_scene == null:
        push_error("Assign hook projectile scene in inspector!")
        return

    var grappling_hook: GrappleLine = grappling_hook_scene.instantiate()

    if grappling_hook == null:
        push_error("Failed to instantiate hook projectile!")
        return

    if player == null:
        push_error("Failed to find player")
        return

    player.line_holder.add_child(grappling_hook)

    var start_pos = get_viewport_rect().size / 2.0
    start_pos = get_canvas_transform().affine_inverse() * start_pos
    var target_pos = get_global_mouse_position()
    var direction = (target_pos - start_pos).normalized()

    grappling_hook.shoot(start_pos, direction)
