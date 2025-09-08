extends CharacterBody2D

# ===== Señales para la HUD =====
signal hunger_changed(value: float)
signal energy_changed(value: float)
signal mood_changed(value: float)
signal state_changed(new_state: String)

# ===== Setup general =====
@export var move_speed := 80.0
@export var wander_radius := 280.0

# Necesidades (0..100)
@export var max_value := 100.0
@export var hunger := 20.0
@export var energy := 80.0
@export var mood   := 80.0

# Ritmos (por segundo)
@export var hunger_rate := 2.0
@export var energy_drain_walk := 3.0
@export var energy_recover_sleep := 12.0
@export var mood_drain_hungry := 2.0
@export var mood_recover := 1.0

# Umbrales
@export var hungry_threshold := 65.0
@export var tired_threshold  := 25.0

# Cooldowns (segundos)
@export var cd_after_eat := 10.0
@export var cd_after_sleep := 12.0
@export var cd_after_play := 8.0

# ===== Nodos =====
@onready var agent: NavigationAgent2D = $NavigationAgent2D
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

# ===== Interno =====
var _target := Vector2.ZERO
var _time_to_new_target := 0.0

enum State {IDLE, WANDER, GO_TO_POI, USE_POI, SLEEP}
var _state: State = State.WANDER
var _poi_target: Node2D = null
var _poi_kind: String = ""  # "food","bed","toy","toilet"

var _cooldowns := {"food": 0.0, "bed": 0.0, "toy": 0.0}

# --- ISO anim helpers ---
var _last_dir := "SE"
const INV_SQRT2 := 0.7071067811865476
const _DIRS = [
	{"name":"NE", "v": Vector2( INV_SQRT2, -INV_SQRT2)},
	{"name":"NW", "v": Vector2(-INV_SQRT2, -INV_SQRT2)},
	{"name":"SE", "v": Vector2( INV_SQRT2,  INV_SQRT2)},
	{"name":"SW", "v": Vector2(-INV_SQRT2,  INV_SQRT2)},
]

# Direcciones de movimiento “snap” a iso
const ISO_DIRS: Array[Vector2] = [
	Vector2(1, 1),
	Vector2(-1, 1),
	Vector2(1, -1),
	Vector2(-1, -1),
]

# ====== NAV helpers (clamp a la NavigationRegion) ======
func _nav_map() -> RID:
	return agent.get_navigation_map()

func _closest_on_nav(p: Vector2) -> Vector2:
	return NavigationServer2D.map_get_closest_point(_nav_map(), p)

func _ready() -> void:
	randomize()
	_pick_new_wander_target()
	_emit_all()
	state_changed.emit(_state_to_string())

func _process(delta: float) -> void:
	_tick_needs(delta)
	_tick_cooldowns(delta)
	_fsm_step(delta)

func _physics_process(delta: float) -> void:
	# Si por cualquier motivo salió del navmesh, lo traemos de vuelta
	var snap := _closest_on_nav(global_position)
	if snap.distance_to(global_position) > 2.0:
		global_position = snap
		velocity = Vector2.ZERO

	_move_with_agent(delta)

	# Animación según estado/velocidad
	if _state == State.SLEEP:
		_update_iso_animation(Vector2.ZERO, false, "sleep")
	else:
		_update_iso_animation(velocity, velocity.length() > 0.1)

# ==================== Necesidades ====================
func _tick_needs(delta: float) -> void:
	hunger = clampf(hunger + hunger_rate * delta, 0.0, max_value)
	if hunger >= hungry_threshold:
		mood = clampf(mood - mood_drain_hungry * delta, 0.0, max_value)
	else:
		mood = clampf(mood + mood_recover * delta, 0.0, max_value)

	match _state:
		State.SLEEP:
			energy = clampf(energy + energy_recover_sleep * delta, 0.0, max_value)
		State.WANDER, State.GO_TO_POI, State.USE_POI:
			energy = clampf(energy - energy_drain_walk * delta, 0.0, max_value)
		_:
			pass

	hunger_changed.emit(hunger)
	energy_changed.emit(energy)
	mood_changed.emit(mood)

func _tick_cooldowns(delta: float) -> void:
	for k in _cooldowns.keys():
		_cooldowns[k] = max(0.0, _cooldowns[k] - delta)

# ==================== FSM ====================
func _fsm_step(delta: float) -> void:
	if energy <= tired_threshold and _state != State.SLEEP:
		_set_state(State.SLEEP)
	elif hunger >= hungry_threshold and _state != State.GO_TO_POI and _cooldowns["food"] <= 0.0:
		_seek_poi("food")
	elif mood <= 35.0 and _state != State.GO_TO_POI and _cooldowns["toy"] <= 0.0:
		_seek_poi("toy")

	match _state:
		State.IDLE:
			_time_to_new_target -= delta
			if _time_to_new_target <= 0:
				_set_state(State.WANDER)

		State.WANDER:
			_wander_logic(delta)

		State.GO_TO_POI:
			if _poi_target == null or not _poi_target.is_inside_tree():
				_set_state(State.WANDER)
				return
			if agent.is_navigation_finished():
				_set_state(State.USE_POI)

		State.USE_POI:
			if _poi_target == null:
				_set_state(State.WANDER)
				return
			_use_poi(_poi_target)
			_poi_target = null
			_set_state(State.WANDER)

		State.SLEEP:
			velocity = Vector2.ZERO
			if energy >= 85.0:
				_cooldowns["bed"] = cd_after_sleep
				_set_state(State.WANDER)

# ==================== Wander ====================
func _wander_logic(delta: float) -> void:
	_time_to_new_target -= delta
	if _time_to_new_target <= 0.0 or _is_close_to(agent.target_position, 12.0):
		_pick_new_wander_target()

# ==================== Movimiento con NavigationAgent2D ====================
func _iso_quantize(dir: Vector2) -> Vector2:
	if dir.length() < 0.001:
		return Vector2.ZERO

	var nv: Vector2 = dir.normalized()
	var best: Vector2 = ISO_DIRS[0].normalized()
	var best_dot: float = -INF

	for d: Vector2 in ISO_DIRS:
		var nd: Vector2 = d.normalized()
		var dot: float = nv.dot(nd)
		if dot > best_dot:
			best_dot = dot
			best = nd

	return best



func _move_with_agent(delta: float) -> void:
	if agent.is_navigation_finished():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var next_point := agent.get_next_path_position()
	var to_next := next_point - global_position

	# cuantizamos a diagonales isométricas
	var dir := _iso_quantize(to_next)
	var desired := dir * move_speed

	# Si usás avoidance, podés usar set_velocity + señal velocity_computed
	velocity = desired
	move_and_slide()

# ==================== POIs ====================
func _seek_poi(kind: String) -> void:
	var poi := _find_nearest_poi(kind)
	if poi:
		_poi_kind = kind
		_poi_target = poi
		agent.target_position = _closest_on_nav(poi.global_position)  # clamp target
		_set_state(State.GO_TO_POI)
	else:
		_set_state(State.WANDER)

func _use_poi(poi: Node2D) -> void:
	var kind := _get_poi_kind(poi)
	match kind:
		"food":
			var nutrition := 40.0
			if "nutrition" in poi: nutrition = float(poi.nutrition)
			hunger = clampf(hunger - nutrition, 0.0, max_value)
			energy = clampf(energy + nutrition * 0.25, 0.0, max_value)
			mood   = clampf(mood + 10.0, 0.0, max_value)
			_cooldowns["food"] = cd_after_eat
			if poi.has_method("consume"): poi.consume()
		"bed":
			energy = clampf(energy + 35.0, 0.0, max_value)
			mood   = clampf(mood + 6.0, 0.0, max_value)
			_cooldowns["bed"] = cd_after_sleep
		"toy":
			mood   = clampf(mood + 25.0, 0.0, max_value)
			energy = clampf(energy - 8.0, 0.0, max_value)
			_cooldowns["toy"] = cd_after_play
		"toilet":
			mood   = clampf(mood + 5.0, 0.0, max_value)
	_emit_all()

func _find_nearest_poi(kind: String) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("poi"):
		if n is Node2D and n.is_inside_tree():
			if _get_poi_kind(n) == kind:
				var d := global_position.distance_to(n.global_position)
				if d < best_d:
					best_d = d
					best = n
	return best

func _get_poi_kind(n: Node) -> String:
	if "kind" in n:
		return str(n.kind)
	if n.has_meta("kind"):
		return str(n.get_meta("kind"))
	return ""

# ==================== Helpers ====================
func _pick_new_wander_target() -> void:
	var angle := randf() * TAU
	var dist := randf() * wander_radius
	var offset := Vector2(cos(angle), sin(angle)) * dist
	var p := global_position + offset
	agent.target_position = _closest_on_nav(p)  # clamp aleatorio al navmesh
	_time_to_new_target = randf_range(1.2, 3.0)

func _is_close_to(p: Vector2, r: float) -> bool:
	return global_position.distance_to(p) <= r

func _set_state(s: State) -> void:
	if _state == s: return
	_state = s
	state_changed.emit(_state_to_string())

func _state_to_string() -> String:
	match _state:
		State.IDLE: return "IDLE"
		State.WANDER: return "WANDER"
		State.GO_TO_POI: return "GO_TO_POI"
		State.USE_POI: return "USE_POI"
		State.SLEEP: return "SLEEP"
	return "UNKNOWN"

func _emit_all() -> void:
	hunger_changed.emit(hunger)
	energy_changed.emit(energy)
	mood_changed.emit(mood)

# ===== Animación isométrica =====
func _play_anim(name: String) -> void:
	var frames := anim.sprite_frames
	if frames and frames.has_animation(name):
		anim.play(name)

func _update_iso_animation(v: Vector2, moving: bool, force_state: String = "") -> void:
	if not is_instance_valid(anim) or anim.sprite_frames == null:
		return

	if force_state == "sleep":
		_play_anim("sleep")
		return

	if v.length() < 0.1:
		_play_anim("idle_%s" % _last_dir)
		return

	var best := "SE"
	var best_dot := -INF
	var nv := v.normalized()
	for d in _DIRS:
		var dirv: Vector2 = (d["v"] as Vector2)  # ya normalizado por INV_SQRT2
		var dot := nv.dot(dirv)
		if dot > best_dot:
			best_dot = dot
			best = d["name"]

	_last_dir = best
	_play_anim("walk_%s" % best)
