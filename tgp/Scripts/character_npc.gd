extends CharacterBody2D

# ================== REFERENCIAS ==================
@export var tile_node: NodePath         # Asigná el TileMap o TileMapLayer del piso
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

# Pueden venir TileMap o TileMapLayer, soportamos ambos:
var ground_tm: TileMap                  # si es TileMap
var ground_layer: TileMapLayer          # si es TileMapLayer

# ================== MOVIMIENTO GRID ==================
@export var tiles_per_second: float = 6.0     # velocidad: celdas por segundo
@export var stop_epsilon: float = 1.0         # tolerancia al centro de la celda (px)
@export var wander_every: float = 1.2         # cada cuánto intenta dar UN paso aleatorio (s)

var _path_world: PackedVector2Array = []      # centros de celdas en mundo
var _path_cells: Array[Vector2i] = []         # path en celdas (map coords)
var _current_target: Vector2 = Vector2.ZERO   # punto mundo de la celda objetivo
var _wander_timer: float = 0.0
var _moving: bool = false
var _last_dir: String = "SE"                  # para idle

# 4 vecinos (grilla iso/diamond)
const DIRS4: Array[Vector2i] = [
	Vector2i( 1,  0),  # NE
	Vector2i(-1,  0),  # SW
	Vector2i( 0,  1),  # SE
	Vector2i( 0, -1),  # NW
]

# ================== READY ==================
func _ready() -> void:
	if tile_node.is_empty():
		push_error("Asigná 'tile_node' al TileMap/TileMapLayer del piso.")
		return

	var n := get_node(tile_node)
	if n is TileMapLayer:
		ground_layer = n
		if "get_tile_map" in ground_layer:
			ground_tm = ground_layer.get_tile_map()
		else:
			ground_tm = ground_layer.get_parent() as TileMap
	elif n is TileMap:
		ground_tm = n
	else:
		push_error("El nodo asignado no es TileMap ni TileMapLayer.")
		return

	# Snap inicial
	var c := _world_to_cell(global_position)
	global_position = _cell_center_world(c)

	# Idle inicial
	if anim:
		anim.speed_scale = 1.0
		_play_idle_anim()

# ================== LOOP ==================
func _process(delta: float) -> void:
	if _moving:
		return

	# Wander básico
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_step_random()

func _physics_process(delta: float) -> void:
	if not _moving:
		return

	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var step: Vector2 = to_target.normalized() * px_per_sec * delta

	if to_target.length() <= stop_epsilon or step.length() >= to_target.length():
		global_position = _current_target
		_advance_path_or_stop()
	else:
		global_position += step
		_play_walk_anim(to_target)

# ================== API ==================
func go_to_cell(target_cell: Vector2i) -> void:
	var start: Vector2i = _current_cell()
	if start == target_cell:
		return

	_path_cells = _astar_path_cells(start, target_cell)
	if _path_cells.size() <= 1:
		return

	_path_world.clear()
	for cell in _path_cells:
		_path_world.append(_cell_center_world(cell))

	_path_world.remove_at(0) # descartar actual
	_set_next_target_from_path()

# ================== WANDER ==================
func _step_random() -> void:
	var start: Vector2i = _current_cell()
	var candidates: Array[Vector2i] = []
	for d in DIRS4:
		var c := start + d
		if not _is_blocked(c):
			candidates.append(c)
	if candidates.is_empty():
		_play_idle_anim()
		return
	candidates.shuffle()
	go_to_cell(candidates.front())

# ================== PATH ==================
func _advance_path_or_stop() -> void:
	if _path_world.size() == 0:
		_moving = false
		_play_idle_anim()
		return
	_set_next_target_from_path()

func _set_next_target_from_path() -> void:
	_current_target = _path_world[0]
	_path_world.remove_at(0)
	_moving = true

# ================== A* ==================
func _astar_path_cells(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var used: Rect2i = _used_rect()
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(used.position, used.size)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()

	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c := Vector2i(x, y)
			if _is_blocked(c):
				grid.set_point_solid(c, true)

	if grid.is_point_solid(start) or grid.is_point_solid(goal):
		return [start]

	return grid.get_id_path(start, goal)

# ================== BLOQUEOS ==================
func _is_blocked(c: Vector2i) -> bool:
	if not _cell_has_floor(c):
		return true
	var data: TileData = _get_tile_data(c)
	if data and data.get_custom_data("blocked") == true:
		return true
	return false

# ================== WRAPPERS ==================
func _tile_size() -> Vector2i:
	if ground_layer != null:
		return ground_layer.tile_set.tile_size
	else:
		return ground_tm.tile_set.tile_size

func _cell_has_floor(c: Vector2i) -> bool:
	if ground_layer != null:
		return ground_layer.get_cell_source_id(c) != -1
	else:
		return ground_tm.get_cell_source_id(0, c) != -1

func _get_tile_data(c: Vector2i) -> TileData:
	if ground_layer != null:
		return ground_layer.get_cell_tile_data(c)
	else:
		return ground_tm.get_cell_tile_data(0, c)

func _world_to_cell(world_pos: Vector2) -> Vector2i:
	if ground_layer != null:
		return ground_layer.local_to_map(ground_layer.to_local(world_pos))
	else:
		return ground_tm.local_to_map(ground_tm.to_local(world_pos))

func _cell_center_world(c: Vector2i) -> Vector2:
	if ground_layer != null:
		return ground_layer.to_global(ground_layer.map_to_local(c))
	else:
		return ground_tm.to_global(ground_tm.map_to_local(c))

func _used_rect() -> Rect2i:
	if ground_layer != null:
		return ground_layer.get_used_rect()
	else:
		return ground_tm.get_used_rect()

func _current_cell() -> Vector2i:
	return _world_to_cell(global_position)

# ================== ANIMACIÓN ==================
func _play_anim_safe(name: String) -> void:
	var frames: SpriteFrames = anim.sprite_frames
	if frames and frames.has_animation(name):
		if anim.animation != name:
			anim.play(name)
		elif anim.speed_scale == 0.0:
			anim.speed_scale = 1.0

func _play_walk_anim(to_target: Vector2) -> void:
	if to_target.length() < 0.1:
		_play_idle_anim()
		return

	var dir: Vector2 = to_target.normalized()
	var ne := Vector2( 1, -1).normalized()
	var nw := Vector2(-1, -1).normalized()
	var se := Vector2( 1,  1).normalized()
	var sw := Vector2(-1,  1).normalized()

	var best: String = "SE"
	var best_dot: float = -INF
	var options := {"NE": ne, "NW": nw, "SE": se, "SW": sw}
	for name in options.keys():
		var d: Vector2 = options[name]
		var dot: float = dir.dot(d)
		if dot > best_dot:
			best_dot = dot
			best = String(name)

	_last_dir = best
	anim.speed_scale = 1.0
	_play_anim_safe("walk_%s" % best)

func _play_idle_anim() -> void:
	anim.speed_scale = 1.0
	_play_anim_safe("idle_%s" % _last_dir)
