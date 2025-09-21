# NPC.gd
extends CharacterBody2D

signal room_changed(new_room_id)
signal door_travel_started(from_room: String, to_room: String)

@export var current_room_id: String = "room_a"
@export var door_group: String = "door"
@export var inter_room_wander_chance: float = 0.25
@export var min_idle_after_room: float = 0.2
@export var max_idle_after_room: float = 0.6

@export var tile_node: NodePath
@export var block_layers: Array[NodePath] = []
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var RM: Node = get_node_or_null("/root/RoomManager")

var ground_tm: TileMap = null
var ground_layer: TileMapLayer = null
var _block_layers_nodes: Array = []

@export var tiles_per_second: float = 1.5
@export var acceleration_px: float = 700.0
@export var stop_epsilon: float = 1.0

@export var wander_every: float = 1.2
@export var wander_min_steps: int = 1
@export var wander_max_steps: int = 10
@export var idle_pause_min: float = 0.15
@export var idle_pause_max: float = 0.25

@export var base_walk_fps: float = 10.0
@export var min_anim_speed: float = 0.75
@export var max_anim_speed: float = 1.35

@export var bob_amount: float = 1.0
@export var bob_speed: float = 8.0

@export var dynamic_obstacle_group: String = "obstacle_dynamic"
@export var dynamic_block_neighborhood: int = 0

@export var max_slide_bounces: int = 3
@export var repath_on_stuck_time: float = 0.18
@export var progress_epsilon: float = 0.8
@export var agent_clearance_tiles: int = 1
@export var replan_cooldown: float = 0.25

var _replan_cd: float = 0.0
var _stuck_timer: float = 0.0
var _last_dist_to_target: float = INF

var _path_world: PackedVector2Array = PackedVector2Array()
var _path_cells: Array[Vector2i] = []
var _current_target: Vector2 = Vector2.ZERO
var _goal_cell: Vector2i = Vector2i.ZERO
var _wander_timer: float = 0.0
var _moving: bool = false
var _wander_scheduled: bool = false
var _last_dir: String = "SE"
var _bob_phase: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _pending_door: Door = null

const DIRS4: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]

# --------- Sims/Tamagotchi ----------
enum State { IDLE, WALK, INTERACT, TRAVEL }
var _state: State = State.IDLE

var needs: Dictionary[String, float] = {
	"hunger": 0.20,
	"energy": 0.10,
	"fun":    0.35
}
var need_decay: Dictionary[String, float] = {
	"hunger": 0.005,
	"energy": 0.003,
	"fun":    0.004
}
var need_weight: Dictionary[String, float] = {
	"hunger": 1.0,
	"energy": 0.9,
	"fun":    0.7
}

@export var decide_every: float = 2.0
var _decide_timer: float = 0.0

var _target_activity: ActivityPoint = null
var _interact_timer: float = 0.0

# ================== READY ==================
func _ready() -> void:
	safe_margin = 0.01
	_ensure_tile_refs()
	_resolve_block_layers()
	await get_tree().process_frame
	_ensure_tile_refs()
	_resolve_block_layers()

	if ground_layer != null or ground_tm != null:
		var c: Vector2i = _world_to_cell(global_position)
		global_position = _cell_center_world(c)

	if anim != null:
		anim.speed_scale = 1.0
		_play_idle_anim()
		_base_sprite_pos = anim.position
		
	# En _ready() del NPC (al final) SOLO PARA PRUEBAS
	needs["hunger"] = 0.98
	need_weight["hunger"] = 1.0
	need_weight["energy"] = 0.0
	need_weight["fun"]    = 0.0
	decide_every = 0.2  # decide muy seguido


	call_deferred("_kickstart_wander")

func _kickstart_wander() -> void:
	if not _moving and not _wander_scheduled:
		_wander_timer = 0.0
		_wander_pick_long_target()

# ================== LOOP ==================
func _process(delta: float) -> void:
	# Decaimiento de necesidades
	for k: String in needs.keys():
		needs[k] = clamp(needs[k] + need_decay.get(k, 0.0) * delta, 0.0, 1.0)

	# Decidir actividad si está en reposo
	_decide_timer -= delta
	if _decide_timer <= 0.0 and _state == State.IDLE:
		_decide_timer = decide_every
		_try_decide_activity()

	# Wander original
	if not _moving and not _wander_scheduled and _path_world.size() == 0:
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = 0.0
			_wander_pick_long_target()
		return
	if _moving or _wander_scheduled:
		return
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_wander_pick_long_target()

# ========== FÍSICA ==========
func _physics_process(delta: float) -> void:
	if _replan_cd > 0.0:
		_replan_cd = max(0.0, _replan_cd - delta)
	if not _ensure_tile_refs():
		return
	if not _moving:
		return

	var next_cell: Vector2i = _world_to_cell(_current_target)
	if _is_blocked(next_cell):
		print("[NPC] next_cell bloqueada:", next_cell, " -> replan")
		_repath_to_goal()
		return


	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var desired: Vector2 = Vector2.ZERO
	if to_target != Vector2.ZERO:
		desired = to_target.normalized() * px_per_sec

	if acceleration_px > 0.0:
		velocity = velocity.move_toward(desired, acceleration_px * delta)
	else:
		velocity = desired

	var dist: float = to_target.length()
	var wanted_motion: Vector2 = velocity * delta
	if dist <= stop_epsilon:
		wanted_motion = Vector2.ZERO
	elif wanted_motion.length() > dist:
		wanted_motion = wanted_motion.limit_length(dist)

	var remaining: Vector2 = wanted_motion
	var any_collision: bool = false
	var hit_normal: Vector2 = Vector2.ZERO
	var dir_attempt: Vector2 = Vector2.ZERO
	if desired != Vector2.ZERO:
		dir_attempt = desired.normalized()

	for i in range(max_slide_bounces):
		if remaining.length() <= 0.0001:
			break
		var col: KinematicCollision2D = move_and_collide(remaining)
		if col:
			any_collision = true
			hit_normal = col.get_normal()
			remaining = col.get_remainder().slide(hit_normal)
			velocity = velocity.slide(hit_normal)
		else:
			break

	var new_dist: float = (_current_target - global_position).length()

	if any_collision and dir_attempt != Vector2.ZERO and hit_normal != Vector2.ZERO:
		var frontal_impact: bool = dir_attempt.dot(-hit_normal) > 0.8
		if frontal_impact and new_dist > float(_tile_size().x) * 0.25:
			_repath_to_goal()

	var snap_eps: float = max(stop_epsilon, float(_tile_size().x) * 0.2)
	if new_dist <= snap_eps:
		global_position = _current_target
		_play_walk_anim(to_target)
		_advance_path_or_stop()
	else:
		if velocity.length() < 5.0:
			_play_idle_anim()
		else:
			_play_walk_anim(velocity)

	var progressed: bool = new_dist < (_last_dist_to_target - progress_epsilon)
	if progressed:
		_stuck_timer = 0.0
	else:
		_stuck_timer += delta
	if _stuck_timer >= repath_on_stuck_time:
		_stuck_timer = 0.0
		_repath_to_goal()
	_last_dist_to_target = new_dist

	_apply_walk_bob(delta)

# ================== API ==================
func go_to_cell(target_cell: Vector2i) -> void:
	print("[NPC] go_to_cell start:", _current_cell(), " -> target:", target_cell)
	if not _ensure_tile_refs():
		return
	_goal_cell = target_cell

	var start: Vector2i = _current_cell()
	if start == target_cell:
		print("[NPC] ya estoy en la celda destino.")
		# si es una puerta pendiente, cruza YA
		if _pending_door != null:
			_cross_pending_door()
		return

	_path_cells = _astar_path_cells(start, target_cell)
	print("[NPC] A* path len:", _path_cells.size(), " start=", start, " goal=", target_cell)

	if _path_cells.size() <= 1:
		# 1) si es puerta y estoy pegado al entry, cruzar igual
		if _pending_door != null:
			var manhattan: int = abs(start.x - target_cell.x) + abs(start.y - target_cell.y)
			if manhattan <= 1:
				print("[NPC] sin ruta pero adyacente a puerta -> cruzo.")
				_cross_pending_door()
				return
		# 2) fallback: intenta ir a la celda de piso más cercana al target
		var near := _nearest_floor_cell(target_cell)
		if near != target_cell:
			print("[NPC] sin ruta: pruebo near=", near)
			if near != start:
				_path_cells = _astar_path_cells(start, near)
		# 3) si sigue sin ruta, aborta movimiento
		if _path_cells.size() <= 1:
			print("[NPC] sin ruta -> no me muevo.")
			return

	# pasa a world y arranca
	_path_world.clear()
	for cell in _path_cells:
		_path_world.append(_cell_center_world(cell))
	if _path_world.size() > 0:
		_path_world.remove_at(0)
	_set_next_target_from_path()


func get_needs() -> Dictionary[String, float]:
	# copiamos para no exponer el original por referencia
	return needs.duplicate()

func get_state_name() -> String:
	match _state:
		State.IDLE:     return "IDLE"
		State.WALK:     return "WALK"
		State.INTERACT: return "INTERACT"
		State.TRAVEL:   return "TRAVEL"
	return "UNKNOWN"


# ================== WANDER ==================
func _try_pick_random_door_and_go() -> bool:
	var doors_any: Array = []
	if RM != null and RM.has_method("get_doors"):
		doors_any = RM.get_doors(current_room_id)  # puede traer Area2D o Door
	else:
		doors_any = get_tree().get_nodes_in_group(door_group)

	print("[NPC][Door] room=", current_room_id, " doors_found_global=", doors_any.size())

	var candidates: Array = []
	for n in doors_any:
		# aceptamos Area2D con las props necesarias aunque no sea 'Door' tipado
		if not (n is Area2D):
			continue
		# verificamos que tenga las propiedades
		if not ("room_id" in n and "entry_cell" in n and "target_room_id" in n and "target_spawn_cell" in n and "locked" in n):
			continue
		if String(n.room_id) != current_room_id:
			continue

		var ok_cell := _cell_has_floor(n.entry_cell) and not _is_blocked(n.entry_cell)
		print("[NPC][Door] check name=", n.name, " locked=", n.locked, " entry=", n.entry_cell, " ok_cell=", ok_cell, " target_room=", n.target_room_id)
		if not n.locked and ok_cell:
			candidates.append(n)

	print("[NPC][Door] candidates=", candidates.size())
	if candidates.is_empty():
		return false

	candidates.shuffle()  # o tu _weighted_pick_door
	_pending_door = candidates[0]
	var entry: Vector2i = _pending_door.entry_cell
	if not _cell_has_floor(entry) or _is_blocked(entry):
		entry = _nearest_floor_cell(entry)  # ya la tenés implementada
	#print("[NPC][Door] entry ajustada a:", entry)
	#go_to_cell(entry)
	go_to_cell(_pending_door.entry_cell)
	_state = State.TRAVEL
	return true



func _weighted_pick_door(arr: Array[Door]) -> Door:
	var total: float = 0.0
	for d: Door in arr:
		var w: float = max(0.0, float(d.wander_weight))
		total += w
	if total <= 0.0:
		arr.shuffle()
		return arr[0]
	var r: float = randf() * total
	var acc: float = 0.0
	for d: Door in arr:
		var w: float = max(0.0, float(d.wander_weight))
		acc += w
		if r <= acc:
			return d
	return arr.back()

func _wander_pick_long_target() -> void:
	if not _ensure_tile_refs():
		return
	if randf() < inter_room_wander_chance:
		if _try_pick_random_door_and_go():
			return
	_wander_pick_long_target_same_room()

func _wander_pick_long_target_same_room() -> void:
	var start: Vector2i = _current_cell()
	var used: Rect2i = _used_rect()
	var libres: Array[Vector2i] = []
	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c: Vector2i = Vector2i(x, y)
			if c == start: continue
			if not _cell_has_floor(c): continue
			if _is_blocked(c): continue
			libres.append(c)
	if libres.is_empty():
		return
	var cand: Array[Vector2i] = []
	for c in libres:
		var d: int = abs(c.x - start.x) + abs(c.y - start.y)
		if d >= max(1, wander_min_steps) and d <= max(wander_min_steps, wander_max_steps):
			cand.append(c)
	if cand.is_empty():
		cand = (libres.duplicate() as Array[Vector2i])
	cand.shuffle()
	for target: Vector2i in cand:
		var path: Array[Vector2i] = _astar_path_cells(start, target)
		if path.size() > 1:
			go_to_cell(target)
			return
	for dvec: Vector2i in DIRS4:
		var nb: Vector2i = start + dvec
		if used.has_point(nb) and _cell_has_floor(nb) and not _is_blocked(nb):
			var p2: Array[Vector2i] = _astar_path_cells(start, nb)
			if p2.size() > 1:
				go_to_cell(nb)
				return

func _schedule_next_wander() -> void:
	if _wander_scheduled:
		return
	_wander_scheduled = true
	call_deferred("_do_schedule_next_wander")

func _do_schedule_next_wander() -> void:
	await get_tree().create_timer(randf_range(idle_pause_min, idle_pause_max)).timeout
	_wander_scheduled = false
	if not _moving:
		_wander_pick_long_target()

# ================== PATH TILE A TILE ==================
func _advance_path_or_stop() -> void:
	if _path_world.size() == 0:
		if _pending_door != null:
			print("[NPC] path done en puerta -> cruzo.")
			_cross_pending_door()
			return
		print("[NPC] path done -> idle")
		_moving = false
		velocity = Vector2.ZERO
		call_deferred("_to_idle_after_frame")
		return
	_set_next_target_from_path()


func _to_idle_after_frame() -> void:
	await get_tree().process_frame
	_play_idle_anim()
	_wander_timer = 0.0
	_schedule_next_wander()
	_state = State.IDLE

func _set_next_target_from_path() -> void:
	_current_target = _path_world[0]
	_path_world.remove_at(0)
	_moving = true

func _repath_to_goal() -> void:
	if _replan_cd > 0.0: return
	_replan_cd = replan_cooldown
	print("[NPC] replan to:", _goal_cell, " desde:", _current_cell(), " moving=", _moving, " path_world=", _path_world.size())
	if _goal_cell == _current_cell():
		_moving = false; velocity = Vector2.ZERO; _play_idle_anim(); return
	if _moving and _path_world.size() > 0:
		return
	go_to_cell(_goal_cell)


# --------- Puertas: cruce ----------
func _cross_pending_door() -> void:
	if _pending_door == null:
		return
	var door: Door = _pending_door
	_pending_door = null
	print("[NPC][Door] CROSS from", current_room_id, "to", door.target_room_id, " spawn=", door.target_spawn_cell)

	if RM != null and RM.has_method("move_npc_to_room"):
		RM.move_npc_to_room(self, door.target_room_id, door.target_spawn_cell)
	else:
		push_warning("RoomManager no disponible; no se puede cambiar de sala.")
		return

	current_room_id = door.target_room_id
	_wander_timer = 0.0
	_wander_scheduled = false


# --------- Utility AI: decidir actividad ----------
func _try_decide_activity() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var best_score: float = -INF
	var best_room: String = ""
	var best_ap: ActivityPoint = null

	if RM != null and RM.has_method("get_activities"):
		for ap: ActivityPoint in RM.get_activities(current_room_id):
			if not ap.is_available(now):
				continue
			var s: float = _score_activity(ap)
			if s > best_score:
				best_score = s
				best_room = current_room_id
				best_ap = ap

	if RM != null and RM.has_method("get_doors"):
		for d: Door in RM.get_doors(current_room_id):
			for ap2: ActivityPoint in RM.get_activities(d.target_room_id):
				if not ap2.is_available(now):
					continue
				var s2: float = _score_activity(ap2) - 0.15
				if s2 > best_score:
					best_score = s2
					best_room = d.target_room_id
					best_ap = ap2

	if best_ap == null or best_score <= 0.05:
		return

	_target_activity = best_ap
	if best_room != current_room_id:
		_go_to_room_for_activity(best_room, best_ap)
	else:
		go_to_cell(best_ap.entry_cell)
		_state = State.WALK

func _score_activity(ap: ActivityPoint) -> float:
	var score: float = 0.0
	for need_name: String in needs.keys():
		var deficit: float = needs.get(need_name, 0.0)
		var weight: float = need_weight.get(need_name, 0.0)
		var delta: float = -float(ap.need_effect.get(need_name, 0.0))
		score += deficit * weight * delta
	score += ap.priority_bias
	return score

func _go_to_room_for_activity(target_room: String, ap: ActivityPoint) -> void:
	var doors: Array[Door] = RM.get_doors(current_room_id) as Array[Door]
	var dir_doors: Array[Door] = []
	for d: Door in doors:
		if (not d.locked) and d.target_room_id == target_room:
			dir_doors.append(d)
	if dir_doors.is_empty():
		_try_pick_random_door_and_go()
		return
	var start: Vector2i = _current_cell()
	dir_doors.sort_custom(func(a: Door, b: Door) -> bool:
		var da: int = abs(a.entry_cell.x - start.x) + abs(a.entry_cell.y - start.y)
		var db: int = abs(b.entry_cell.x - start.x) + abs(b.entry_cell.y - start.y)
		return da < db
	)
	_pending_door = dir_doors[0]
	go_to_cell(_pending_door.entry_cell)
	_state = State.TRAVEL

# --------- Interacción ----------
func _start_interact(ap: ActivityPoint) -> void:
	_state = State.INTERACT
	_interact_timer = ap.duration
	_play_idle_anim()

func _apply_activity_effect(ap: ActivityPoint) -> void:
	for k: String in ap.need_effect.keys():
		needs[k] = clamp(needs.get(k, 0.0) + float(ap.need_effect[k]), 0.0, 1.0)

# ================== A* EN GRILLA ==================
func _mark_solid_with_clearance(grid: AStarGrid2D, bounds: Rect2i, c: Vector2i, clr: int) -> void:
	if clr <= 0:
		grid.set_point_solid(c, true)
		return
	for dy in range(-clr, clr + 1):
		for dx in range(-clr, clr + 1):
			var p: Vector2i = c + Vector2i(dx, dy)
			if bounds.has_point(p):
				grid.set_point_solid(p, true)

func _nearest_floor_cell(from_cell: Vector2i) -> Vector2i:
	var used: Rect2i = _used_rect()
	var best: Vector2i = used.position
	var bestd: float = INF
	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c: Vector2i = Vector2i(x, y)
			if _cell_has_floor(c):
				var d: float = float((c - from_cell).length_squared())
				if d < bestd:
					bestd = d
					best = c
	return best

func _astar_path_cells(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _ensure_tile_refs():
		result.append(start)
		return result
	var used: Rect2i = _used_rect()
	if not used.has_point(start) or not _cell_has_floor(start):
		start = _nearest_floor_cell(start)
	if not used.has_point(goal) or not _cell_has_floor(goal):
		goal = _nearest_floor_cell(goal)

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
			if not _cell_has_floor(c):
				grid.set_point_solid(c, true)
				continue
			if _is_blocked(c):
				_mark_solid_with_clearance(grid, region, c, agent_clearance_tiles)

	if region.has_point(start):
		grid.set_point_solid(start, false)
	if region.has_point(goal):
		grid.set_point_solid(goal, false)

	if not region.has_point(goal) or grid.is_point_solid(goal):
		result.append(start)
		return result

	var id_path: PackedVector2Array = grid.get_id_path(start, goal)
	if id_path.size() == 0:
		result.append(start)
		return result

	for i in range(id_path.size()):
		var v: Vector2 = id_path[i]
		result.append(Vector2i(v))
	return result

# ================== BLOQUEOS / WRAPPERS ==================
func _is_blocked(c: Vector2i) -> bool:
	if not _cell_has_floor(c):
		return true
	if _blocked_in_layers(c):
		return true
	if _blocked_by_dynamic(c):
		return true
	return false

func _blocked_in_layers(c: Vector2i) -> bool:
	for n in _block_layers_nodes:
		if n is TileMapLayer:
			var lyr: TileMapLayer = n
			if lyr.get_cell_source_id(c) != -1:
				return true
		elif n is TileMap:
			var tm: TileMap = n
			if tm.get_cell_source_id(0, c) != -1:
				return true
	return false

func _blocked_by_dynamic(c: Vector2i) -> bool:
	for nd in get_tree().get_nodes_in_group(dynamic_obstacle_group):
		if nd == self:
			continue
		if !(nd is Node2D):
			continue
		var cell: Vector2i = _world_to_cell((nd as Node2D).global_position)
		if cell == c:
			return true
		if dynamic_block_neighborhood > 0:
			for d: Vector2i in DIRS4:
				if cell == c + d:
					return true
	return false

func _ensure_tile_refs() -> bool:
	if ground_layer != null or ground_tm != null:
		return true
	var n: Node = null
	if not tile_node.is_empty():
		n = get_node_or_null(tile_node)
	if n == null:
		var g: Node = get_tree().get_first_node_in_group("ground")
		if g != null:
			n = g
	if n == null:
		var layers: Array = get_tree().get_nodes_in_group("TileMapLayer")
		if layers.size() > 0:
			n = layers[0]
	if n == null:
		var maps: Array = get_tree().get_nodes_in_group("TileMap")
		if maps.size() > 0:
			n = maps[0]
	if n is TileMapLayer:
		ground_layer = n
		if ground_layer.has_method("get_tile_map"):
			ground_tm = ground_layer.get_tile_map()
		else:
			ground_tm = ground_layer.get_parent() as TileMap
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

func _tile_size() -> Vector2i:
	if ground_layer != null:
		return ground_layer.tile_set.tile_size
	elif ground_tm != null:
		return ground_tm.tile_set.tile_size
	return Vector2i(32, 32)

func _cell_has_floor(c: Vector2i) -> bool:
	if ground_layer != null:
		return ground_layer.get_cell_source_id(c) != -1
	elif ground_tm != null:
		var lc: int = ground_tm.get_layers_count()
		for layer in range(lc):
			if ground_tm.get_cell_source_id(layer, c) != -1:
				return true
	return false

func _get_tile_data(c: Vector2i) -> TileData:
	if ground_layer != null:
		return ground_layer.get_cell_tile_data(c)
	elif ground_tm != null:
		var lc: int = ground_tm.get_layers_count()
		for layer in range(lc):
			var td: TileData = ground_tm.get_cell_tile_data(layer, c)
			if td != null:
				return td
	return null

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

func _current_cell() -> Vector2i:
	return _world_to_cell(global_position)

# ================== ANIMACIÓN ==================
func _play_anim_safe(anim_name: String) -> void:
	if anim == null:
		return
	var frames: SpriteFrames = anim.sprite_frames
	if frames != null and frames.has_animation(anim_name):
		if anim.animation != anim_name:
			anim.play(anim_name)
		elif anim.speed_scale == 0.0:
			anim.speed_scale = 1.0

func _play_walk_anim(move_vec: Vector2) -> void:
	if anim == null or move_vec.length() < 0.05:
		return
	var dir: Vector2 = move_vec.normalized()
	var ne: Vector2 = Vector2( 1, -1).normalized()
	var nw: Vector2 = Vector2(-1, -1).normalized()
	var se: Vector2 = Vector2( 1,  1).normalized()
	var sw: Vector2 = Vector2(-1,  1).normalized()
	var best: String = "SE"
	var best_dot: float = -INF
	var names: Array[String] = ["NE", "NW", "SE", "SW"]
	var vecs: Array[Vector2] = [ne, nw, se, sw]
	for i in range(names.size()):
		var dot: float = dir.dot(vecs[i])
		if dot > best_dot:
			best_dot = dot
			best = names[i]
	_last_dir = best
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var speed_ratio: float = (velocity.length() / px_per_sec) if px_per_sec > 0.0 else 0.0
	var scale_now: float = clamp(speed_ratio * (10.0 / base_walk_fps), min_anim_speed, max_anim_speed)
	anim.speed_scale = scale_now
	_play_anim_safe("walk_%s" % best)

func _play_idle_anim() -> void:
	if anim == null:
		return
	anim.speed_scale = 1.0
	_play_anim_safe("idle_%s" % _last_dir)

func _apply_walk_bob(delta: float) -> void:
	if anim == null:
		return
	if velocity.length() < 1.0:
		anim.position = _base_sprite_pos
		_bob_phase = 0.0
		return
	_bob_phase += bob_speed * delta
	var y_off: float = -abs(sin(_bob_phase)) * bob_amount
	anim.position = _base_sprite_pos + Vector2(0, y_off)

# ================== DEBUG CLICK ==================
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _ensure_tile_refs():
			return
		var gp: Vector2 = get_global_mouse_position()
		var cell: Vector2i
		if ground_layer != null:
			cell = ground_layer.local_to_map(ground_layer.to_local(gp))
		elif ground_tm != null:
			cell = ground_tm.local_to_map(ground_tm.to_local(gp))
		else:
			return
		go_to_cell(cell)
		
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.is_key_pressed(KEY_SHIFT):
		if not _ensure_tile_refs():
			return
		var gp: Vector2 = get_global_mouse_position()
		var cell: Vector2i
		if ground_layer != null:
			cell = ground_layer.local_to_map(ground_layer.to_local(gp))
		elif ground_tm != null:
			cell = ground_tm.local_to_map(ground_tm.to_local(gp))
		else:
			return
		print("[NPC] click cell:", cell, " has_floor:", _cell_has_floor(cell), " blocked:", _is_blocked(cell))


# --------- INTERACT timer (puede ir en _process si preferís) ----------
func _integrate_forces(delta: float) -> void:
	if _state == State.INTERACT and _target_activity != null:
		_interact_timer -= delta
		if _interact_timer <= 0.0:
			_apply_activity_effect(_target_activity)
			_target_activity.reserve(Time.get_ticks_msec()/1000.0)
			_target_activity = null
			_state = State.IDLE
			_wander_timer = 0.0
