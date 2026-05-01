# character_npc.gd
extends CharacterBody2D

signal room_changed(new_room_id)

# ================== EXPORTS ==================
@export var current_room_id: String = "dormitorio"
@export var tiles_per_second: float = 4.0
@export var tile_node: NodePath
@export var block_layers: Array[NodePath] = []

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

# ================== TILE REFS ==================
var ground_layer: TileMapLayer = null
var ground_tm: TileMap = null
var _block_layers_nodes: Array = []

# ================== MOVIMIENTO ==================
var _path_cells: Array[Vector2i] = []
var _moving: bool = false
var _current_cell: Vector2i = Vector2i.ZERO
var _last_dir: String = "SE"
var _tween: Tween = null

# ================== ESTADO ==================
enum State { IDLE, WALK, INTERACT, TRAVEL }
var _state: State = State.IDLE

# ================== NECESIDADES ==================
var needs: Dictionary = {
	"hunger": 0.20,
	"energy": 0.10,
	"fun":    0.35
}
var need_decay: Dictionary = {
	"hunger": 0.005,
	"energy": 0.003,
	"fun":    0.004
}
var need_weight: Dictionary = {
	"hunger": 1.0,
	"energy": 0.9,
	"fun":    0.7
}

# ================== DECISION ==================
# [MEJORA] decide_every ahora está conectado al loop de proceso.
# El NPC reevalúa su actividad periódicamente, incluso mientras hace wander,
# para poder interrumpirse si surge una necesidad urgente.
@export var decide_every: float = 2.0
var _decide_timer: float = 0.0

var _target_activity = null
var _interact_timer: float = 0.0

# [MEJORA] Cooldown por actividad: evita que el NPC repita la misma
# actividad inmediatamente después de terminarla.
var _activity_cooldowns: Dictionary = {}
@export var activity_cooldown_duration: float = 10.0

# ================== WANDER ==================
var _wander_timer: float = 0.0

# [MEJORA] Historial de celdas visitadas recientemente.
var _visited_cells: Array[Vector2i] = []
const VISITED_HISTORY_SIZE: int = 8

# [MEJORA] Última celda de wander para calcular inercia de dirección.
var _last_wander_cell: Vector2i = Vector2i.ZERO

# ================== FAILSAFE ==================
var _stuck_timer: float = 0.0

const DIRS4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
]

# ================== READY ==================
func _ready() -> void:
	_ensure_tile_refs()
	_resolve_block_layers()
	await get_tree().process_frame
	_ensure_tile_refs()
	_resolve_block_layers()

	if ground_layer != null or ground_tm != null:
		_current_cell = _world_to_cell(global_position)
		global_position = _cell_center_world(_current_cell)
		_last_wander_cell = _current_cell

	if anim != null:
		_play_idle_anim()

	z_index = 2

# ================== PROCESS ==================
func _process(delta: float) -> void:
	for k: String in needs.keys():
		needs[k] = clamp(needs[k] + need_decay.get(k, 0.0) * delta, 0.0, 1.0)

	# [MEJORA] Reducir cooldowns de actividades cada frame
	for key in _activity_cooldowns.keys():
		_activity_cooldowns[key] -= delta
		if _activity_cooldowns[key] <= 0.0:
			_activity_cooldowns.erase(key)

	# [MEJORA] Reevaluar actividad periódicamente
	if _state == State.IDLE or _state == State.WALK:
		_decide_timer -= delta
		if _decide_timer <= 0.0:
			_decide_timer = decide_every
			_try_decide_activity()

	if _state == State.INTERACT and _target_activity != null:
		_interact_timer -= delta
		if _interact_timer <= 0.0:
			_apply_activity_effect(_target_activity)
			# [MEJORA] Registrar cooldown al terminar la actividad
			var act_id: String = _get_activity_id(_target_activity)
			_activity_cooldowns[act_id] = activity_cooldown_duration
			_target_activity = null
			_state = State.IDLE

	if not _moving and _path_cells.size() > 0:
		_step_next_cell()

	if _state == State.IDLE and not _moving and _path_cells.size() == 0:
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = randf_range(2.0, 5.0)
			_wander_pick_random_cell()

	if _state == State.WALK and not _moving:
		_stuck_timer += delta
		if _stuck_timer > 3.0:
			print("[NPC] stuck detectado, reseteando")
			_stuck_timer = 0.0
			_path_cells.clear()
			_state = State.IDLE
			_wander_timer = 0.0
	else:
		_stuck_timer = 0.0

# ================== WANDER ==================
func _wander_pick_random_cell() -> void:
	if not _ensure_tile_refs():
		return

	# [MEJORA] Vector de inercia desde la última celda de wander
	var momentum: Vector2i = _current_cell - _last_wander_cell

	var used: Rect2i = _used_rect()
	var candidates: Array[Vector2i] = []
	var scores: Array[float] = []

	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c := Vector2i(x, y)
			if c == _current_cell:
				continue
			if not _cell_has_floor(c):
				continue
			if _is_blocked(c):
				continue
			var dist: int = abs(c.x - _current_cell.x) + abs(c.y - _current_cell.y)
			if dist < 2 or dist > 6:
				continue

			var score: float = 0.0

			# [MEJORA] Bonus de inercia
			if momentum != Vector2i.ZERO:
				var to_candidate: Vector2i = c - _current_cell
				var dot: float = (
					float(momentum.x * to_candidate.x + momentum.y * to_candidate.y) /
					(momentum.length() * to_candidate.length() + 0.001)
				)
				score += dot * 0.4

			# [MEJORA] Penalizar celdas visitadas recientemente
			if c in _visited_cells:
				score -= 0.6

			candidates.append(c)
			scores.append(score)

	if candidates.is_empty():
		_wander_timer = 1.0
		return

	var best_score: float = scores.max()
	var best_candidates: Array[Vector2i] = []
	for i in range(candidates.size()):
		if scores[i] >= best_score - 0.2:
			best_candidates.append(candidates[i])

	best_candidates.shuffle()
	var chosen: Vector2i = best_candidates[0]

	# [MEJORA] Actualizar historial
	_last_wander_cell = _current_cell
	_visited_cells.append(_current_cell)
	if _visited_cells.size() > VISITED_HISTORY_SIZE:
		_visited_cells.remove_at(0)

	go_to_cell(chosen)

# ================== MOVIMIENTO TÁCTICO ==================
func go_to_cell(target_cell: Vector2i) -> void:
	if not _ensure_tile_refs():
		return
	var start: Vector2i = _current_cell
	if start == target_cell:
		return

	_path_cells = _astar_path_cells(start, target_cell)

	if _path_cells.size() > 0 and _path_cells[0] == start:
		_path_cells.remove_at(0)

	_state = State.WALK
	if not _moving and _path_cells.size() > 0:
		_step_next_cell()

func _step_next_cell() -> void:
	if _path_cells.size() == 0:
		_moving = false
		_play_idle_anim()
		_state = State.IDLE
		_on_arrived()
		return

	var next_cell: Vector2i = _path_cells[0]
	_path_cells.remove_at(0)

	if _is_blocked(next_cell):
		_path_cells.clear()
		_moving = false
		_play_idle_anim()
		_state = State.IDLE
		return

	var to_pos: Vector2 = _cell_center_world(next_cell)
	var dir: Vector2 = to_pos - global_position

	_play_walk_anim(dir)

	var duration: float = 1.0 / tiles_per_second
	_moving = true
	_current_cell = next_cell

	if _tween != null and _tween.is_valid():
		_tween.kill()

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "global_position", to_pos, duration)
	_tween.finished.connect(_on_step_finished, CONNECT_ONE_SHOT)

func _on_step_finished() -> void:
	_moving = false
	if _path_cells.size() > 0:
		_step_next_cell()
	else:
		_play_idle_anim()
		_state = State.IDLE
		_on_arrived()

func _on_arrived() -> void:
	# [MEJORA] Chequear si llegó a la actividad objetivo
	if _target_activity != null and _current_cell == _target_activity.entry_cell:
		_start_interact(_target_activity)
		return

	var rm: Node = get_node_or_null("/root/RoomManager")
	if rm == null or not rm.has_method("get_doors"):
		_wander_timer = 0.0
		return
	var doors = rm.get_doors(current_room_id)
	for door in doors:
		if door.entry_cell == _current_cell and not door.locked:
			_cross_door(door)
			return
	_wander_timer = 0.0

# ================== PUERTAS ==================
func _cross_door(door) -> void:
	var rm: Node = get_node_or_null("/root/RoomManager")
	if rm == null:
		return

	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = false
	modulate.a = 0.0
	current_room_id = door.target_room_id
	_path_cells.clear()
	_moving = false
	_state = State.IDLE
	velocity = Vector2.ZERO

	await rm.move_npc_to_room(self, door.target_room_id, door.target_spawn_cell)

# ================== NECESIDADES ==================
func _try_decide_activity() -> void:
	var rm: Node = get_node_or_null("/root/RoomManager")
	if rm == null or not rm.has_method("get_activities"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var best_score: float = -INF
	var best_ap = null

	for ap in rm.get_activities(current_room_id):
		if not ap.is_available(now):
			continue

		# [MEJORA] Saltar actividades en cooldown
		var act_id: String = _get_activity_id(ap)
		if _activity_cooldowns.has(act_id):
			continue

		var s: float = _score_activity(ap)
		if s > best_score:
			best_score = s
			best_ap = ap

	if best_ap == null or best_score <= 0.05:
		return

	# [MEJORA] Solo interrumpir si supera por margen significativo
	if _state == State.INTERACT and _target_activity != null:
		var current_score: float = _score_activity(_target_activity)
		if best_score < current_score + 0.15:
			return

	_target_activity = best_ap
	go_to_cell(best_ap.entry_cell)
	_state = State.WALK

func _score_activity(ap) -> float:
	var score: float = 0.0
	for need_name: String in needs.keys():
		var deficit: float = needs.get(need_name, 0.0)
		var weight: float = need_weight.get(need_name, 0.0)
		var delta: float = -float(ap.need_effect.get(need_name, 0.0))
		score += deficit * weight * delta
	score += ap.priority_bias

	# [MEJORA] Penalización por distancia Manhattan
	var dist: int = abs(ap.entry_cell.x - _current_cell.x) + abs(ap.entry_cell.y - _current_cell.y)
	score -= dist * 0.02

	return score

func _apply_activity_effect(ap) -> void:
	for k: String in ap.need_effect.keys():
		needs[k] = clamp(needs.get(k, 0.0) + float(ap.need_effect[k]), 0.0, 1.0)

func _start_interact(ap) -> void:
	_state = State.INTERACT
	_interact_timer = ap.duration
	_play_idle_anim()

# [MEJORA] ID único por actividad para el sistema de cooldowns
func _get_activity_id(ap) -> String:
	var cell_str: String = "%d_%d" % [ap.entry_cell.x, ap.entry_cell.y]
	var name_str: String = ap.get("activity_name") if ap.get("activity_name") != null else str(ap.get_instance_id())
	return "%s_%s" % [name_str, cell_str]

func get_needs() -> Dictionary:
	return needs.duplicate()

func get_state_name() -> String:
	match _state:
		State.IDLE:     return "IDLE"
		State.WALK:     return "WALK"
		State.INTERACT: return "INTERACT"
		State.TRAVEL:   return "TRAVEL"
	return "UNKNOWN"

# ================== A* ==================
func _astar_path_cells(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _ensure_tile_refs():
		result.append(start)
		return result

	var used: Rect2i = _used_rect()
	var minx: int = min(used.position.x, min(start.x, goal.x)) - 1
	var miny: int = min(used.position.y, min(start.y, goal.y)) - 1
	var maxx: int = max(used.position.x + used.size.x - 1, max(start.x, goal.x)) + 1
	var maxy: int = max(used.position.y + used.size.y - 1, max(start.y, goal.y)) + 1
	var region: Rect2i = Rect2i(Vector2i(minx, miny), Vector2i(maxx - minx + 1, maxy - miny + 1))

	var grid: AStarGrid2D = AStarGrid2D.new()
	grid.region = region
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()

	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			var c: Vector2i = Vector2i(x, y)
			if not _cell_has_floor(c) or _is_blocked(c):
				grid.set_point_solid(c, true)

	if region.has_point(start):
		grid.set_point_solid(start, false)
	if region.has_point(goal):
		grid.set_point_solid(goal, false)

	if not region.has_point(goal) or grid.is_point_solid(goal):
		result.append(start)
		return result

	var id_path: PackedVector2Array = grid.get_id_path(start, goal)
	for v in id_path:
		result.append(Vector2i(v))
	return result

# ================== BLOQUEOS ==================
func _is_blocked(c: Vector2i) -> bool:
	if not _cell_has_floor(c):
		return true
	if ground_layer != null:
		var td: TileData = ground_layer.get_cell_tile_data(c)
		if td != null:
			var val = td.get_custom_data("Blocked")
			if val is bool and val == true:
				return true
	return _blocked_in_layers(c)

func _blocked_in_layers(c: Vector2i) -> bool:
	for n in _block_layers_nodes:
		if n is TileMapLayer:
			var lyr: TileMapLayer = n
			if lyr.get_cell_source_id(c) != -1:
				var td: TileData = lyr.get_cell_tile_data(c)
				if td == null:
					return true
				var val = td.get_custom_data("Blocked")
				if val is bool and val == true:
					return true
	return false

# ================== TILE HELPERS ==================
func _ensure_tile_refs() -> bool:
	if ground_layer != null or ground_tm != null:
		return true
	var n: Node = null
	if not tile_node.is_empty():
		n = get_node_or_null(tile_node)
	if n == null:
		n = get_tree().get_first_node_in_group("ground")
	if n is TileMapLayer:
		ground_layer = n
		return true
	elif n is TileMap:
		ground_tm = n
		return true
	return false

func _resolve_block_layers() -> void:
	_block_layers_nodes.clear()
	for p: NodePath in block_layers:
		var nn: Node = get_node_or_null(p)
		if nn != null:
			_block_layers_nodes.append(nn)

func _cell_has_floor(c: Vector2i) -> bool:
	if ground_layer != null:
		return ground_layer.get_cell_source_id(c) != -1
	elif ground_tm != null:
		for layer in range(ground_tm.get_layers_count()):
			if ground_tm.get_cell_source_id(layer, c) != -1:
				return true
	return false

func _world_to_cell(world_pos: Vector2) -> Vector2i:
	if ground_layer != null:
		return ground_layer.local_to_map(ground_layer.to_local(world_pos))
	elif ground_tm != null:
		return ground_tm.local_to_map(ground_tm.to_local(world_pos))
	return Vector2i.ZERO

func _cell_center_world(c: Vector2i) -> Vector2:
	if ground_layer != null:
		return ground_layer.to_global(ground_layer.map_to_local(c))
	elif ground_tm != null:
		return ground_tm.to_global(ground_tm.map_to_local(c))
	return global_position

func _used_rect() -> Rect2i:
	if ground_layer != null:
		return ground_layer.get_used_rect()
	elif ground_tm != null:
		return ground_tm.get_used_rect()
	return Rect2i(Vector2i.ZERO, Vector2i(1, 1))

# ================== ANIMACIÓN ==================
func _play_walk_anim(move_vec: Vector2) -> void:
	if anim == null or move_vec.length() < 0.05:
		return
	var dir: Vector2 = move_vec.normalized()
	var best: String = "SE"
	var best_dot: float = -INF
	var names: Array[String] = ["NE", "NW", "SE", "SW"]
	var vecs: Array[Vector2] = [
		Vector2(1, -1).normalized(),
		Vector2(-1, -1).normalized(),
		Vector2(1, 1).normalized(),
		Vector2(-1, 1).normalized()
	]
	for i in range(names.size()):
		var dot: float = dir.dot(vecs[i])
		if dot > best_dot:
			best_dot = dot
			best = names[i]
	_last_dir = best
	_play_anim_safe("walk_%s" % best)

func _play_idle_anim() -> void:
	if anim == null:
		return
	anim.speed_scale = 1.0
	_play_anim_safe("idle_%s" % _last_dir)

func _play_anim_safe(anim_name: String) -> void:
	if anim == null:
		return
	var frames: SpriteFrames = anim.sprite_frames
	if frames != null and frames.has_animation(anim_name):
		if anim.animation != anim_name:
			anim.play(anim_name)
