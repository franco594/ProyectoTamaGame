extends CharacterBody2D

# ================== REFERENCIAS ==================
@export var tile_node: NodePath                   # Asigná el TileMap o TileMapLayer del piso
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

# Soporte dual: TileMap o TileMapLayer
var ground_tm: TileMap = null
var ground_layer: TileMapLayer = null

# ================== MOVIMIENTO GRID ==================
@export var tiles_per_second: float = 6.0         # celdas por segundo
@export var stop_epsilon: float = 1.0             # tolerancia al centro de celda (px)
@export var wander_every: float = 1.2             # cada cuánto da UN paso aleatorio (s)

var _path_world: PackedVector2Array = PackedVector2Array() # centros de celdas en mundo
var _path_cells: Array[Vector2i] = []             # camino en coordenadas de mapa
var _current_target: Vector2 = Vector2.ZERO       # punto mundo (centro de celda objetivo)
var _wander_timer: float = 0.0
var _moving: bool = false
var _last_dir: String = "SE"                      # para idle

# 4 vecinos (grilla iso/diamond)
const DIRS4: Array[Vector2i] = [
	Vector2i( 1,  0),  # NE
	Vector2i(-1,  0),  # SW
	Vector2i( 0,  1),  # SE
	Vector2i( 0, -1),  # NW
]

# ================== ARRANQUE ==================
func _ready() -> void:
	# Intentar resolver referencias al TileMap/Layer
	_ensure_tile_refs()
	# Esperar un frame por si el mapa se instanció este mismo tick
	await get_tree().process_frame
	_ensure_tile_refs()

	# Snap inicial al centro de celda si ya tenemos piso
	if ground_layer != null or ground_tm != null:
		var c: Vector2i = _world_to_cell(global_position)
		global_position = _cell_center_world(c)

	# Animación por defecto
	if anim != null:
		anim.speed_scale = 1.0
		_play_idle_anim()

# ================== LOOP ==================
func _process(delta: float) -> void:
	if _moving:
		return

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_step_random()

func _physics_process(delta: float) -> void:
	# Si no hay piso resuelto, no hacer nada
	if not _ensure_tile_refs():
		return

	if not _moving:
		return

	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x) # aprox
	var step: Vector2 = to_target.normalized() * px_per_sec * delta

	if to_target.length() <= stop_epsilon or step.length() >= to_target.length():
		# Llegó a la celda: snap al centro exacto
		global_position = _current_target
		_advance_path_or_stop()
	else:
		global_position += step
		_play_walk_anim(to_target)

# ================== API: IR A UNA CELDA ==================
func go_to_cell(target_cell: Vector2i) -> void:
	if not _ensure_tile_refs():
		return

	var start: Vector2i = _current_cell()
	if start == target_cell:
		return

	_path_cells = _astar_path_cells(start, target_cell)
	if _path_cells.size() <= 1:
		return

	_path_world.clear()
	for cell in _path_cells:
		_path_world.append(_cell_center_world(cell))

	# descartar la celda actual
	if _path_world.size() > 0:
		_path_world.remove_at(0)
	_set_next_target_from_path()

# ================== WANDER: UN PASO ALEATORIO ==================
func _step_random() -> void:
	if not _ensure_tile_refs():
		return
	var start: Vector2i = _current_cell()
	var candidates: Array[Vector2i] = []
	for d in DIRS4:
		var c: Vector2i = start + d
		if not _is_blocked(c):
			candidates.append(c)
	if candidates.is_empty():
		_play_idle_anim()
		return
	candidates.shuffle()
	go_to_cell(candidates.front())

# ================== PATH TILE A TILE ==================
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

# ================== A* EN GRILLA (4 DIRECCIONES) ==================
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

	# Marcar sólidas
	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c: Vector2i = Vector2i(x, y)
			if _is_blocked(c):
				grid.set_point_solid(c, true)

	# Seguridad
	if grid.is_point_solid(start) or grid.is_point_solid(goal):
		result.append(start)
		return result

	return grid.get_id_path(start, goal)

# ================== BLOQUEOS / COLISIONES ==================
func _is_blocked(c: Vector2i) -> bool:
	# 1) Sin piso => bloqueado
	if not _cell_has_floor(c):
		return true

	# 2) Custom Data "blocked" en el TileSet (opcional)
	var data: TileData = _get_tile_data(c)
	if data != null and data.get_custom_data("blocked") == true:
		return true

	return false

# ================== RESOLUCIÓN DEL TILEMAP/LAYER ==================
func _ensure_tile_refs() -> bool:
	# Ya resuelto
	if ground_layer != null or ground_tm != null:
		return true

	var n: Node = null

	# 1) Intentar con lo asignado en el Inspector
	if not tile_node.is_empty():
		n = get_node_or_null(tile_node)

	# 2) Autodetección: grupo "ground"
	if n == null:
		var g: Node = get_tree().get_first_node_in_group("ground")
		if g != null:
			n = g

	# 3) Autodetección: buscar TileMapLayer por grupo o por tipo
	if n == null:
		var layers: Array = get_tree().get_nodes_in_group("TileMapLayer")
		if layers.size() > 0:
			n = layers[0]
	if n == null:
		# fallback: primer TileMap en la escena si existe
		var maps: Array = get_tree().get_nodes_in_group("TileMap")
		if maps.size() > 0:
			n = maps[0]

	# 4) Asignación final si el nodo es válido
	if n is TileMapLayer:
		ground_layer = n
		# Intentar obtener el TileMap dueño
		if "get_tile_map" in ground_layer:
			ground_tm = ground_layer.get_tile_map()
		else:
			ground_tm = ground_layer.get_parent() as TileMap
		return true
	elif n is TileMap:
		ground_tm = n
		return true

	return false

# ================== WRAPPERS SEGUROS (TileMap / TileMapLayer) ==================
func _tile_size() -> Vector2i:
	if not _ensure_tile_refs():
		return Vector2i(32, 32) # fallback
	if ground_layer != null:
		return ground_layer.tile_set.tile_size
	else:
		return ground_tm.tile_set.tile_size

func _cell_has_floor(c: Vector2i) -> bool:
	if not _ensure_tile_refs():
		return false
	if ground_layer != null:
		return ground_layer.get_cell_source_id(c) != -1
	else:
		return ground_tm.get_cell_source_id(0, c) != -1

func _get_tile_data(c: Vector2i) -> TileData:
	if not _ensure_tile_refs():
		return null
	if ground_layer != null:
		return ground_layer.get_cell_tile_data(c)
	else:
		return ground_tm.get_cell_tile_data(0, c)

func _world_to_cell(world_pos: Vector2) -> Vector2i:
	if not _ensure_tile_refs():
		return Vector2i.ZERO
	if ground_layer != null:
		return ground_layer.local_to_map(ground_layer.to_local(world_pos))
	else:
		return ground_tm.local_to_map(ground_tm.to_local(world_pos))

func _cell_center_world(c: Vector2i) -> Vector2:
	if not _ensure_tile_refs():
		return global_position
	if ground_layer != null:
		return ground_layer.to_global(ground_layer.map_to_local(c))
	else:
		return ground_tm.to_global(ground_tm.map_to_local(c))

func _used_rect() -> Rect2i:
	if not _ensure_tile_refs():
		return Rect2i(Vector2i.ZERO, Vector2i(1, 1))
	if ground_layer != null:
		return ground_layer.get_used_rect()
	else:
		return ground_tm.get_used_rect()

func _current_cell() -> Vector2i:
	return _world_to_cell(global_position)

# ================== ANIMACIÓN ISO (idle/walk NE, NW, SE, SW) ==================
func _play_anim_safe(name: String) -> void:
	if anim == null:
		return
	var frames: SpriteFrames = anim.sprite_frames
	if frames != null and frames.has_animation(name):
		if anim.animation != name:
			anim.play(name)
		elif anim.speed_scale == 0.0:
			anim.speed_scale = 1.0

func _play_walk_anim(to_target: Vector2) -> void:
	if anim == null:
		return
	if to_target.length() < 0.1:
		_play_idle_anim()
		return

	var dir: Vector2 = to_target.normalized()
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
	anim.speed_scale = 1.0
	_play_anim_safe("walk_%s" % best)

func _play_idle_anim() -> void:
	if anim == null:
		return
	anim.speed_scale = 1.0
	_play_anim_safe("idle_%s" % _last_dir)
