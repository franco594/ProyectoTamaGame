extends CharacterBody2D

# ================== REFERENCIAS ==================
@export var tile_node: NodePath                    # TileMap o TileMapLayer del piso
@export var block_layers: Array[NodePath] = []     # Capas que bloquean (Pared, Objetos, etc.)
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

var ground_tm: TileMap = null                      # si el piso es TileMap
var ground_layer: TileMapLayer = null              # si el piso es TileMapLayer
var _block_layers_nodes: Array = []                # nodos reales de block_layers (TileMap/Layer)

# ================== MOVIMIENTO / FEEL ==================
@export var tiles_per_second: float = 4.5
@export var acceleration_px: float = 700.0
@export var stop_epsilon: float = 0.5

# Wander / Paseos
@export var wander_every: float = 1.2
@export var wander_min_steps: int = 4
@export var wander_max_steps: int = 10

# Pausas naturales
@export var idle_pause_min: float = 0.4
@export var idle_pause_max: float = 0.9

# Anim sync
@export var base_walk_fps: float = 10.0
@export var min_anim_speed: float = 0.75
@export var max_anim_speed: float = 1.35

# Bobbing
@export var bob_amount: float = 1.0
@export var bob_speed: float = 8.0

# Obstáculos dinámicos
@export var dynamic_obstacle_group: String = "obstacle_dynamic"
@export var dynamic_block_neighborhood: int = 0    # 0 = solo celda; 1 = también 4 vecinas

# ================== ESTADO ==================
var _path_world: PackedVector2Array = PackedVector2Array()
var _path_cells: Array[Vector2i] = []
var _current_target: Vector2 = Vector2.ZERO
var _goal_cell: Vector2i = Vector2i.ZERO           # para replanificar
var _wander_timer: float = 0.0
var _moving: bool = false
var _wander_scheduled: bool = false
var _last_dir: String = "SE"
var _bob_phase: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO

const DIRS4: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]

# ================== READY ==================
func _ready() -> void:
	_ensure_tile_refs()
	_resolve_block_layers()
	await get_tree().process_frame
	_ensure_tile_refs()
	_resolve_block_layers()

	# Snap inicial
	if ground_layer != null or ground_tm != null:
		var c: Vector2i = _world_to_cell(global_position)
		global_position = _cell_center_world(c)

	if anim != null:
		anim.speed_scale = 1.0
		_play_idle_anim()
		_base_sprite_pos = anim.position

# ================== LOOP ==================
func _process(delta: float) -> void:
	if _moving or _wander_scheduled:
		return
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_wander_pick_long_target()

func _physics_process(delta: float) -> void:
	if not _ensure_tile_refs():
		return
	if not _moving:
		return

	# Si el siguiente tile se bloqueó (objeto nuevo/dinámico), replantea camino
	var next_cell := _world_to_cell(_current_target)
	if _is_blocked(next_cell):
		_repath_to_goal()
		return

	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var desired: Vector2 = to_target.normalized() * px_per_sec

	var step: Vector2
	if acceleration_px > 0.0:
		velocity = velocity.move_toward(desired, acceleration_px * delta)
		step = velocity * delta
	else:
		step = desired * delta
		velocity = desired

	if step.length() >= to_target.length() or to_target.length() <= stop_epsilon:
		global_position = _current_target
		_play_walk_anim(to_target)
		_advance_path_or_stop()
	else:
		global_position += step
		_play_walk_anim(step)

	_apply_walk_bob(delta)

# ================== API ==================
func go_to_cell(target_cell: Vector2i) -> void:
	if not _ensure_tile_refs():
		return
	_goal_cell = target_cell

	var start: Vector2i = _current_cell()
	if start == target_cell:
		return

	_path_cells = _astar_path_cells(start, target_cell)
	if _path_cells.size() <= 1:
		return

	_path_world.clear()
	for cell in _path_cells:
		_path_world.append(_cell_center_world(cell))

	if _path_world.size() > 0:
		_path_world.remove_at(0)
	_set_next_target_from_path()

# ================== WANDER ==================
func _wander_pick_long_target() -> void:
	if not _ensure_tile_refs():
		return

	var start: Vector2i = _current_cell()
	var tries: int = 24
	var min_s: int = max(1, wander_min_steps)
	var max_s: int = max(min_s, wander_max_steps)
	var best: Vector2i = start
	var used: Rect2i = _used_rect()

	while tries > 0:
		tries -= 1
		var dist: int = randi_range(min_s, max_s)
		var dx: int = randi_range(-dist, dist)
		var dy: int = dist - abs(dx)
		if randi() % 2 == 0:
			dy = -dy
		var cand: Vector2i = start + Vector2i(dx, dy)
		if not used.has_point(cand):
			continue
		if _is_blocked(cand):
			continue
		best = cand
		break

	if best != start:
		go_to_cell(best)

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
		_moving = false
		velocity = Vector2.ZERO
		call_deferred("_to_idle_after_frame")
		return
	_set_next_target_from_path()

func _to_idle_after_frame() -> void:
	await get_tree().process_frame
	_play_idle_anim()
	_schedule_next_wander()

func _set_next_target_from_path() -> void:
	_current_target = _path_world[0]
	_path_world.remove_at(0)
	_moving = true

func _repath_to_goal() -> void:
	if _goal_cell == _current_cell():
		_moving = false
		_play_idle_anim()
		return
	go_to_cell(_goal_cell)

# ================== A* EN GRILLA ==================
func _astar_path_cells(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _ensure_tile_refs():
		result.append(start)
		return result

	var used: Rect2i = _used_rect()
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(used.position, used.size)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()

	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c: Vector2i = Vector2i(x, y)
			if _is_blocked(c):
				grid.set_point_solid(c, true)

	if grid.is_point_solid(start) or grid.is_point_solid(goal):
		result.append(start)
		return result

	return grid.get_id_path(start, goal)

# ================== BLOQUEOS ==================
func _is_blocked(c: Vector2i) -> bool:
	# 1) Sin piso => bloqueado
	if not _cell_has_floor(c):
		return true
	# 2) Custom data "blocked" en piso
	var data: TileData = _get_tile_data(c)
	if data != null and data.get_custom_data("blocked") == true:
		return true
	# 3) Capas extra de bloqueo (pared/objetos)
	if _blocked_in_layers(c):
		return true
	# 4) Obstáculos dinámicos
	if _blocked_by_dynamic(c):
		return true
	return false

func _blocked_in_layers(c: Vector2i) -> bool:
	for n in _block_layers_nodes:
		if n is TileMapLayer:
			var lyr: TileMapLayer = n
			if lyr.get_cell_source_id(c) != -1:
				var td := lyr.get_cell_tile_data(c)
				# Si la capa de objetos no tiene custom data, la tratamos como bloqueante por defecto
				if td == null or (td and td.get_custom_data("blocked") == true):
					return true
		elif n is TileMap:
			var tm: TileMap = n
			if tm.get_cell_source_id(0, c) != -1:
				var td2 := tm.get_cell_tile_data(0, c)
				if td2 == null or (td2 and td2.get_custom_data("blocked") == true):
					return true
	return false

func _blocked_by_dynamic(c: Vector2i) -> bool:
	var cell_center := _cell_center_world(c)
	for nd in get_tree().get_nodes_in_group(dynamic_obstacle_group):
		if !(nd is Node2D):
			continue
		var p: Vector2 = (nd as Node2D).global_position
		# bloquea su propia celda …
		if _world_to_cell(p) == c:
			return true
		# … y opcionalmente vecinas 4-dir
		if dynamic_block_neighborhood > 0:
			for d in DIRS4:
				if _world_to_cell(p) == c + d:
					return true
	return false

# ================== RESOLVER NODOS ==================
func _ensure_tile_refs() -> bool:
	if ground_layer != null or ground_tm != null:
		return true
	var n: Node = null
	if not tile_node.is_empty():
		n = get_node_or_null(tile_node)
	if n == null:
		var g: Node = get_tree().get_first_node_in_group("ground")
		if g != null: n = g
	if n == null:
		var layers: Array = get_tree().get_nodes_in_group("TileMapLayer")
		if layers.size() > 0: n = layers[0]
	if n == null:
		var maps: Array = get_tree().get_nodes_in_group("TileMap")
		if maps.size() > 0: n = maps[0]
	if n is TileMapLayer:
		ground_layer = n
		if "get_tile_map" in ground_layer:
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
	for p in block_layers:
		var nn := get_node_or_null(p)
		if nn != null:
			_block_layers_nodes.append(nn)

# ================== WRAPPERS SEGURAS ==================
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
		return ground_tm.get_cell_source_id(0, c) != -1
	return false

func _get_tile_data(c: Vector2i) -> TileData:
	if ground_layer != null:
		return ground_layer.get_cell_tile_data(c)
	elif ground_tm != null:
		return ground_tm.get_cell_tile_data(0, c)
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
func _play_anim_safe(name: String) -> void:
	if anim == null:
		return
	var frames: SpriteFrames = anim.sprite_frames
	if frames != null and frames.has_animation(name):
		if anim.animation != name:
			anim.play(name)
		elif anim.speed_scale == 0.0:
			anim.speed_scale = 1.0

func _play_walk_anim(move_vec: Vector2) -> void:
	if anim == null:
		return
	if move_vec.length() < 0.05:
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
	var speed_ratio: float = 0.0
	if px_per_sec > 0.0:
		speed_ratio = velocity.length() / px_per_sec
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
