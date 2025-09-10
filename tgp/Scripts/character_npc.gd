extends CharacterBody2D

# ================== REFERENCIAS ==================
@export var tile_node: NodePath                   # TileMap o TileMapLayer del piso
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

var ground_tm: TileMap = null                     # si el piso es TileMap
var ground_layer: TileMapLayer = null             # si el piso es TileMapLayer

# ================== MOVIMIENTO / FEEL ==================
@export var tiles_per_second: float = 1.5         # celdas por segundo (bajito para ver pasos)
@export var acceleration_px: float = 500    # px/s^2 (suaviza arranque y frenado)
@export var stop_epsilon: float = 0        # px; cuándo consideramos “llegado” al centro

# Wander / Paseos
@export var wander_every: float = 1.2             # cada cuánto intenta planificar paseo (s)
@export var wander_min_steps: int = 1             # mínimo de celdas a recorrer por paseo
@export var wander_max_steps: int = 20            # máximo de celdas a recorrer por paseo

# Pausas naturales al llegar
@export var idle_pause_min: float = 0.4           # pausa mínima (s)
@export var idle_pause_max: float = 5           # pausa máxima (s)

# Sincronía animación-camino
@export var base_walk_fps: float = 3           # FPS con que creaste tus walk_* en SpriteFrames
@export var min_anim_speed: float = 0.75          # límites de multiplicador de anim
@export var max_anim_speed: float = 1.35

# Bobbing sutil (sensación de peso)
@export var bob_amount: float = 1.0               # px
@export var bob_speed: float = 8.0                # frecuencia

# ================== ESTADO INTERNO ==================
var _path_world: PackedVector2Array = PackedVector2Array() # centros de celdas (mundo)
var _path_cells: Array[Vector2i] = []                       # camino en celdas
var _current_target: Vector2 = Vector2.ZERO                 # centro de celda objetivo
var _wander_timer: float = 0.0
var _moving: bool = false
var _wander_scheduled: bool = false
var _last_dir: String = "SE"                                # para idle
var _bob_phase: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO

# 4 vecinos (grilla iso/diamond)
const DIRS4: Array[Vector2i] = [
	Vector2i( 1,  0),  # NE
	Vector2i(-1,  0),  # SW
	Vector2i( 0,  1),  # SE
	Vector2i( 0, -1),  # NW
]

# ================== ARRANQUE ==================
func _ready() -> void:
	_ensure_tile_refs()
	await get_tree().process_frame
	_ensure_tile_refs()

	# Snap inicial al centro de celda
	if ground_layer != null or ground_tm != null:
		var c: Vector2i = _world_to_cell(global_position)
		global_position = _cell_center_world(c)

	if anim != null:
		anim.speed_scale = 1.0
		_play_idle_anim()
		_base_sprite_pos = anim.position

# ================== LOOP ==================
func _process(delta: float) -> void:
	# Si está caminando o hay pausa planificada, no dispares otro paseo aquí
	if _moving or _wander_scheduled:
		return

	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_wander_pick_long_target()   # planifica paseo de varias celdas

func _physics_process(delta: float) -> void:
	if not _ensure_tile_refs():
		return
	if not _moving:
		return

	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var desired: Vector2 = to_target.normalized() * px_per_sec

	# --- Movimiento con aceleración (natural) ---
	var step: Vector2
	if acceleration_px > 0.0:
		velocity = velocity.move_toward(desired, acceleration_px * delta)
		step = velocity * delta
	else:
		step = desired * delta
		velocity = desired

	# --- Evitar sobrepasar el objetivo; mantener walk 1 frame al aterrizar ---
	if step.length() >= to_target.length() or to_target.length() <= stop_epsilon:
		global_position = _current_target
		_play_walk_anim(to_target)  # usa el vector previo; evita corte brusco
		_advance_path_or_stop()
	else:
		global_position += step
		_play_walk_anim(step)       # anim en base al movimiento real

	_apply_walk_bob(delta)

# ================== API ==================
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
		# Distancia manhattan aleatoria entre min y max
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
		call_deferred("_to_idle_after_frame")   # deja 1 frame de walk antes de idle
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

	# 1) Inspector
	if not tile_node.is_empty():
		n = get_node_or_null(tile_node)

	# 2) Grupo "ground"
	if n == null:
		var g: Node = get_tree().get_first_node_in_group("ground")
		if g != null:
			n = g

	# 3) Buscar TileMapLayer
	if n == null:
		var layers: Array = get_tree().get_nodes_in_group("TileMapLayer")
		if layers.size() > 0:
			n = layers[0]

	# 4) Buscar TileMap
	if n == null:
		var maps: Array = get_tree().get_nodes_in_group("TileMap")
		if maps.size() > 0:
			n = maps[0]

	# 5) Asignación final
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

# ================== WRAPPERS SEGUROS (TileMap / TileMapLayer) ==================
func _tile_size() -> Vector2i:
	if not _ensure_tile_refs():
		return Vector2i(32, 32)
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

# ================== ANIMACIÓN / FEEDBACK ==================
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

	# Histéresis: si el movimiento es diminuto, no cortes a idle aún
	if move_vec.length() < 0.05:
		return

	# Dirección iso (NE/NW/SE/SW)
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

	# Sincronía anim ↔ velocidad real
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
	# Sin bob si no hay movimiento perceptible
	if velocity.length() < 1.0:
		anim.position = _base_sprite_pos
		_bob_phase = 0.0
		return
	_bob_phase += bob_speed * delta
	var y_off: float = -abs(sin(_bob_phase)) * bob_amount
	anim.position = _base_sprite_pos + Vector2(0, y_off)
