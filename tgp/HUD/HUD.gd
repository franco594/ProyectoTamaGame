extends CanvasLayer

# Asigná estos 4 desde el Inspector:
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

func _ready() -> void:
	# 1) Resuelve nodos de UI con chequeos
	_bar_hunger = get_node_or_null(bar_hunger_path) as ProgressBar
	_bar_energy = get_node_or_null(bar_energy_path) as ProgressBar
	_bar_fun    = get_node_or_null(bar_fun_path)    as ProgressBar
	_lbl_state  = get_node_or_null(lbl_state_path)  as Label

	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		push_error("[HUD] Asigná bar_*_path y lbl_state_path en el Inspector (alguna barra/label es null).")
	else:
		# Setealos una sola vez (no hace falta cada frame)
		_bar_hunger.min_value = 0.0; _bar_hunger.max_value = 100.0
		_bar_energy.min_value = 0.0; _bar_energy.max_value = 100.0
		_bar_fun.min_value    = 0.0; _bar_fun.max_value    = 100.0

	# 2) Localiza el NPC (por path o por grupo 'npc')
	if npc_path != NodePath(""):
		_npc = get_node_or_null(npc_path)
	if _npc == null:
		var list: Array = get_tree().get_nodes_in_group("npc")
		if list.size() > 0:
			_npc = list[0]

	if _npc == null and _lbl_state != null:
		_lbl_state.text = "State: (sin NPC)"

	_update_all(0.0)

func _process(delta: float) -> void:
	_update_all(delta)

func _update_all(delta: float) -> void:
	# Si falta alguna barra/label, salgo silencioso
	if _bar_hunger == null or _bar_energy == null or _bar_fun == null or _lbl_state == null:
		return

	if _npc == null:
		_lbl_state.text = "State: (sin NPC)"
		_set_bar(_bar_hunger, 0.0)
		_set_bar(_bar_energy, 0.0)
		_set_bar(_bar_fun,    0.0)
		if not _printed_once:
			_printed_once = true
			push_warning("[HUD] No encontré NPC. Ponelo en el grupo 'npc' o asigná npc_path en el Inspector.")
		return

	var needs_dict: Dictionary = {}
	if _npc.has_method("get_needs"):
		needs_dict = _npc.call("get_needs") as Dictionary
	elif _npc.has_method("get"):
		needs_dict = _npc.get("needs") as Dictionary

	var h: float = float(needs_dict.get("hunger", 0.0))
	var e: float = float(needs_dict.get("energy", 0.0))
	var f: float = float(needs_dict.get("fun",    0.0))

	if not _printed_once:
		_printed_once = true
		print("[HUD] NPC:", _npc, " needs=", needs_dict)

	_set_bar(_bar_hunger, h)
	_set_bar(_bar_energy, e)
	_set_bar(_bar_fun,    f)

	var state_text: String = ""
	if _npc.has_method("get_state_name"):
		state_text = String(_npc.call("get_state_name"))
	elif _npc.has_method("get"):
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
	var vclamp: float = clamp(v01, 0.0, 1.0)
	bar.value = vclamp * 100.0
