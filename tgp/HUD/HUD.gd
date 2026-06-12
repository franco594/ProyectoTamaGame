extends CanvasLayer

# ================== NPC — paths desde Inspector ==================
@export var npc_path: NodePath
@export var bar_hunger_path: NodePath
@export var bar_energy_path: NodePath
@export var bar_fun_path: NodePath
@export var lbl_state_path: NodePath

var _npc: Node = null
var _bar_hunger: ProgressBar
var _bar_energy: ProgressBar
var _bar_fun: ProgressBar
var _lbl_state: Label
var _printed_once: bool = false

# ================== RELOJ — paths desde Inspector ==================
@export var lbl_clock_path: NodePath
@export var lbl_day_path: NodePath      # → LblDay    (nombre del día: "Lunes")
@export var lbl_number_path: NodePath   # → LblNumber (número del día: "1")
@export var texture_season_path: NodePath
@export var lbl_year_path: NodePath
@export var lbl_holiday_path: NodePath
@export var day_buttons: Array[NodePath] = []

var _lbl_clock: Label
var _lbl_day: Label      # muestra el nombre del día "Lunes"
var _lbl_number: Label   # muestra el número del día "1"
var _texture_season: TextureRect
var _lbl_year: Label
var _lbl_holiday: Label
var _day_buttons: Array[Button] = []

# ================== TELÉFONO / NOTIFICACIONES ==================
@export var telephone_path: NodePath

var _telephone: AnimatedSprite2D
var _notification_queue: Array[String] = []
var _has_notification: bool = false

# ================== READY ==================
func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	# --- Barras de necesidades ---
	_bar_hunger = get_node_or_null(bar_hunger_path) as ProgressBar
	_bar_energy = get_node_or_null(bar_energy_path) as ProgressBar
	_bar_fun    = get_node_or_null(bar_fun_path)    as ProgressBar
	_lbl_state  = get_node_or_null(lbl_state_path)  as Label

	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		push_error("[HUD] Alguna barra o label de necesidades es null.")
	else:
		_bar_hunger.min_value = 0.0; _bar_hunger.max_value = 100.0
		_bar_energy.min_value = 0.0; _bar_energy.max_value = 100.0
		_bar_fun.min_value    = 0.0; _bar_fun.max_value    = 100.0

	# --- NPC ---
	if npc_path != NodePath(""):
		_npc = get_node_or_null(npc_path)
	if _npc == null:
		var list: Array = get_tree().get_nodes_in_group("npc")
		if list.size() > 0:
			_npc = list[0]
	if _npc == null and _lbl_state != null:
		_lbl_state.text = "State: (sin NPC)"

	# --- Reloj ---
	_lbl_clock      = get_node_or_null(lbl_clock_path)     as Label
	_lbl_day        = get_node_or_null(lbl_day_path)        as Label
	_lbl_number     = get_node_or_null(lbl_number_path)     as Label
	_texture_season = get_node_or_null(texture_season_path) as TextureRect
	_lbl_year       = get_node_or_null(lbl_year_path)       as Label
	_lbl_holiday    = get_node_or_null(lbl_holiday_path)    as Label

	for p in day_buttons:
		var b: Button = get_node_or_null(p) as Button
		if b != null:
			_day_buttons.append(b)

	# --- Teléfono ---
	_telephone = get_node_or_null(telephone_path) as AnimatedSprite2D
	if _telephone != null:
		_telephone.visible = true
		_telephone.play("idle")
		_telephone.set_process_input(true)
		print("[HUD] Telephone listo")
	else:
		push_warning("[HUD] No se encontró Telephone. Asigná telephone_path en el Inspector.")

	# --- Señales del GameClock ---
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc != null:
		gc.day_changed.connect(_on_day_changed)
		gc.month_changed.connect(_on_month_changed)
		gc.year_changed.connect(_on_year_changed)
	else:
		push_warning("[HUD] GameClock no encontrado.")

	_update_all(0.0)
	_refresh_clock()

	# --- Timer de prueba ---
	await get_tree().create_timer(2.0).timeout
	push_notification("🔔 Notificación de prueba")

	var timer := Timer.new()
	add_child(timer)
	timer.wait_time = 60.0
	timer.autostart = false
	timer.timeout.connect(func(): push_notification("🔔 Notificación de prueba"))
	timer.start()

# ================== PROCESS ==================
func _process(delta: float) -> void:
	_update_all(delta)
	if _lbl_clock != null:
		var gc: Node = get_node_or_null("/root/GameClock")
		if gc != null:
			_lbl_clock.text = gc.get_time_string()

# ================== INPUT ==================
func _input(event: InputEvent) -> void:
	if not _has_notification:
		return
	if _telephone == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _is_click_on_telephone(event.position):
			_dismiss_notification()

func _is_click_on_telephone(click_pos: Vector2) -> bool:
	if _telephone == null:
		return false
	var local_pos: Vector2 = _telephone.to_local(click_pos)
	var frames: SpriteFrames = _telephone.sprite_frames
	if frames == null:
		return false
	var tex: Texture2D = frames.get_frame_texture(_telephone.animation, 0)
	if tex == null:
		return false
	var half_w: float = tex.get_width()  * _telephone.scale.x / 2.0
	var half_h: float = tex.get_height() * _telephone.scale.y / 2.0
	return abs(local_pos.x) < half_w and abs(local_pos.y) < half_h

# ================== NOTIFICACIONES ==================
func push_notification(message: String) -> void:
	_notification_queue.append(message)
	print("[HUD] notificación en cola: '", message, "' | total: ", _notification_queue.size())
	if not _has_notification:
		_show_next_notification()

func _show_next_notification() -> void:
	if _notification_queue.is_empty():
		return
	var msg: String = _notification_queue[0]
	_has_notification = true
	print("[HUD] mostrando: '", msg, "'")
	if _telephone != null:
		if _telephone.sprite_frames != null and _telephone.sprite_frames.has_animation("pulse"):
			_telephone.play("pulse")
		else:
			push_warning("[HUD] Telephone no tiene animación 'pulse'.")

func _dismiss_notification() -> void:
	if _notification_queue.is_empty():
		return
	var dismissed: String = _notification_queue[0]
	_notification_queue.remove_at(0)
	print("[HUD] descartada: '", dismissed, "' | quedan: ", _notification_queue.size())
	if _notification_queue.is_empty():
		_has_notification = false
		if _telephone != null:
			_telephone.stop()
			if _telephone.sprite_frames != null and _telephone.sprite_frames.has_animation("idle"):
				_telephone.play("idle")
			else:
				push_warning("[HUD] Telephone no tiene animación 'idle'.")
	else:
		_show_next_notification()

# ================== NECESIDADES ==================
func _update_all(_delta: float) -> void:
	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		return
	if _npc == null:
		_lbl_state.text = "State: (sin NPC)"
		_set_bar(_bar_hunger, 0.0)
		_set_bar(_bar_energy, 0.0)
		_set_bar(_bar_fun,    0.0)
		if not _printed_once:
			_printed_once = true
			push_warning("[HUD] No encontré NPC.")
		return

	var needs_dict: Dictionary = {}
	if _npc.has_method("get_needs"):
		needs_dict = _npc.call("get_needs") as Dictionary
	elif _npc.has_method("get"):
		needs_dict = _npc.get("needs") as Dictionary

	if not _printed_once:
		_printed_once = true
		print("[HUD] NPC:", _npc, " needs=", needs_dict)

	_set_bar(_bar_hunger, float(needs_dict.get("hunger", 0.0)))
	_set_bar(_bar_energy, float(needs_dict.get("energy", 0.0)))
	_set_bar(_bar_fun,    float(needs_dict.get("fun",    0.0)))

	var state_text: String = ""
	if _npc.has_method("get_state_name"):
		state_text = String(_npc.call("get_state_name"))
	else:
		var s: int = int(_npc.get("_state"))
		match s:
			0: state_text = "IDLE"
			1: state_text = "WALK"
			2: state_text = "INTERACT"
			3: state_text = "TRAVEL"
			_: state_text = "UNKNOWN"
	_lbl_state.text = "State: %s" % state_text

func _set_bar(bar: ProgressBar, v01: float) -> void:
	if bar == null:
		return
	bar.value = clamp(v01, 0.0, 1.0) * 100.0

# ================== RELOJ ==================
func _refresh_clock() -> void:
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc == null:
		return
	if _lbl_clock   != null: _lbl_clock.text   = gc.get_time_string()
	if _lbl_day     != null: _lbl_day.text      = gc.get_weekday()
	if _lbl_number  != null: _lbl_number.text   = str(gc.current_day)
	if _lbl_year    != null: _lbl_year.text     = "Año %d" % gc.current_year
	if _texture_season != null:
		_texture_season.texture = gc.get_season_texture()
	_update_holiday()
	_update_day_buttons()

func _update_holiday() -> void:
	if _lbl_holiday == null:
		return
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc == null:
		return
	var holiday: String = gc.get_holiday_name()
	if holiday != "":
		_lbl_holiday.text    = "🎉 " + holiday
		_lbl_holiday.visible = true
	else:
		_lbl_holiday.visible = false

func _update_day_buttons() -> void:
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc == null:
		return
	for i in range(_day_buttons.size()):
		var btn: Button = _day_buttons[i]
		if btn == null:
			continue
		btn.visible = (i == gc.current_weekday_index)

# ================== SEÑALES DEL GAMECLOCK ==================
func _on_day_changed(day: int, weekday: String, is_holiday: bool, holiday_name: String) -> void:
	if _lbl_day    != null: _lbl_day.text    = weekday
	if _lbl_number != null: _lbl_number.text = str(day)
	_update_holiday()
	_update_day_buttons()
	if is_holiday and holiday_name != "":
		push_notification("🎉 " + holiday_name)

func _on_month_changed(_month: int, season: String) -> void:
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc == null:
		return
	if _texture_season != null:
		_texture_season.texture = gc.get_season_texture()
	push_notification("Nueva estación: " + season)

func _on_year_changed(year: int) -> void:
	if _lbl_year != null: _lbl_year.text = "Año %d" % year
	push_notification("¡Año nuevo! " + str(year))
