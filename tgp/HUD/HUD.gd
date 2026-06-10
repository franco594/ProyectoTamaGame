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
@export var lbl_day_path: NodePath
@export var lbl_weekday_path: NodePath
@export var texture_season_path: NodePath   # TextureRect, no Label
@export var lbl_year_path: NodePath
@export var lbl_holiday_path: NodePath
@export var day_buttons: Array[NodePath] = []

var _lbl_clock: Label
var _lbl_day: Label
var _lbl_weekday: Label
var _texture_season: TextureRect            # TextureRect, no Label
var _lbl_year: Label
var _lbl_holiday: Label
var _day_buttons: Array[Button] = []

# ================== READY ==================
func _ready() -> void:
	# [FIX] Esperar dos frames para que el NPC termine su _ready()
	await get_tree().process_frame
	await get_tree().process_frame

	# --- Barras de necesidades ---
	_bar_hunger = get_node_or_null(bar_hunger_path) as ProgressBar
	_bar_energy = get_node_or_null(bar_energy_path) as ProgressBar
	_bar_fun    = get_node_or_null(bar_fun_path)    as ProgressBar
	_lbl_state  = get_node_or_null(lbl_state_path)  as Label

	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		push_error("[HUD] Alguna barra o label de necesidades es null. Revisá los paths en el Inspector.")
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
	_lbl_clock      = get_node_or_null(lbl_clock_path)      as Label
	_lbl_day        = get_node_or_null(lbl_day_path)         as Label
	_lbl_weekday    = get_node_or_null(lbl_weekday_path)     as Label
	_texture_season = get_node_or_null(texture_season_path)  as TextureRect
	_lbl_year       = get_node_or_null(lbl_year_path)        as Label
	_lbl_holiday    = get_node_or_null(lbl_holiday_path)     as Label

	for p in day_buttons:
		var b: Button = get_node_or_null(p) as Button
		if b != null:
			_day_buttons.append(b)

	# Conectar señales del GameClock
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc != null:
		gc.day_changed.connect(_on_day_changed)
		gc.month_changed.connect(_on_month_changed)
		gc.year_changed.connect(_on_year_changed)
	else:
		push_warning("[HUD] GameClock no encontrado. Agregalo como Autoload.")

	_update_all(0.0)
	_refresh_clock()

# ================== PROCESS ==================
func _process(delta: float) -> void:
	_update_all(delta)
	if _lbl_clock != null:
		var gc: Node = get_node_or_null("/root/GameClock")
		if gc != null:
			_lbl_clock.text = gc.get_time_string()

# ================== NECESIDADES ==================
func _update_all(delta: float) -> void:
	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		return

	if _npc == null:
		_lbl_state.text = "State: (sin NPC)"
		_set_bar(_bar_hunger, 0.0)
		_set_bar(_bar_energy, 0.0)
		_set_bar(_bar_fun,    0.0)
		if not _printed_once:
			_printed_once = true
			push_warning("[HUD] No encontré NPC. Ponelo en el grupo 'npc' o asigná npc_path.")
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

	if _lbl_clock   != null: _lbl_clock.text  = gc.get_time_string()
	if _lbl_day     != null: _lbl_day.text     = "Día %d" % gc.current_day
	if _lbl_weekday != null: _lbl_weekday.text = gc.get_weekday()
	if _lbl_year    != null: _lbl_year.text    = "Año %d" % gc.current_year

	# Textura de estación
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
func _on_day_changed(day: int, weekday: String, _is_holiday: bool, _holiday_name: String) -> void:
	if _lbl_day     != null: _lbl_day.text     = "Día %d" % day
	if _lbl_weekday != null: _lbl_weekday.text = weekday
	_update_holiday()
	_update_day_buttons()

func _on_month_changed(_month: int, _season: String) -> void:
	var gc: Node = get_node_or_null("/root/GameClock")
	if gc == null:
		return
	if _texture_season != null:
		_texture_season.texture = gc.get_season_texture()

func _on_year_changed(year: int) -> void:
	if _lbl_year != null: _lbl_year.text = "Año %d" % year
