extends CharacterBody2D
# NPC basado en celdas (tile grid) que:
# - Usa A* sobre TileMap/TileMapLayer (sin diagonales)
# - Camina con aceleración y “slide” en colisión
# - Evita obstáculos estáticos (capas) y dinámicos (grupo)
# - Pasea automáticamente (wander) dentro del used_rect
# - Replanifica si se atasca o aparece un obstáculo nuevo
# - Sincroniza anims de caminar/idle con la velocidad
# - Efecto bobbing al caminar

# ================== REFERENCIAS ==================
@export var tile_node: NodePath                    # Referencia al piso (TileMap o TileMapLayer). Si está vacío, intenta autodescubrir.
@export var block_layers: Array[NodePath] = []     # Capas extra que bloquean (paredes/objetos). Se consultan con get_cell_source_id.
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

var ground_tm: TileMap = null                      # Cache: si el piso es TileMap
var ground_layer: TileMapLayer = null              # Cache: si el piso es TileMapLayer
var _block_layers_nodes: Array = []                # Nodos reales de block_layers (TileMap/TileMapLayer)

# ================== MOVIMIENTO / FEEL ==================
@export var tiles_per_second: float = 1.5          # Velocidad “lógica” en tiles/seg (se convierte a px/s según tile_size.x)
@export var acceleration_px: float = 700.0         # Aceleración de CharacterBody2D (si 0 => velocidad instantánea)
@export var stop_epsilon: float = 1.0              # Umbral en px para considerar “llegado” al target

# Wander / Paseos (elige celdas al azar dentro del used_rect)
@export var wander_every: float = 1.2              # Frecuencia base entre intentos de pasear (si no está ya caminando)
@export var wander_min_steps: int = 1              # Distancia Manhattan mínima (en celdas) al destino del paseo
@export var wander_max_steps: int = 10             # Distancia Manhattan máxima (en celdas) al destino del paseo
@export var idle_pause_min: float = 0.15           # Pausa aleatoria entre paseos (mín)
@export var idle_pause_max: float = 0.25           # Pausa aleatoria entre paseos (máx)

# Anim sync (ajusta speed_scale según velocidad real)
@export var base_walk_fps: float = 10.0
@export var min_anim_speed: float = 0.75
@export var max_anim_speed: float = 1.35

# Bobbing vertical del sprite al caminar
@export var bob_amount: float = 1.0
@export var bob_speed: float = 8.0

# Obstáculos dinámicos (por grupo)
@export var dynamic_obstacle_group: String = "obstacle_dynamic"
@export var dynamic_block_neighborhood: int = 0    # 0: solo celda; 1: también 4 vecinas

# ======== ANTI-TRABE (slide + watchdog + clearance) ========
@export var max_slide_bounces: int = 3             # Cuántos rebotes de slide por frame
@export var repath_on_stuck_time: float = 0.18     # Tiempo sin progreso que dispara replanificación
@export var progress_epsilon: float = 0.8          # Avance mínimo (px) para contar como progreso
@export var agent_clearance_tiles: int = 1         # “Dilata” obstáculos sólidos en el grid A* para simular ancho del agente
@export var replan_cooldown: float = 0.25          # Antirrebote entre replanificaciones (seg)

var _replan_cd: float = 0.0                        # Enfriamiento repath
var _stuck_timer: float = 0.0                      # Acumula tiempo sin progreso
var _last_dist_to_target: float = INF              # Mide progreso

# ================== ESTADO ==================
var _path_world: PackedVector2Array = PackedVector2Array() # Camino en coordenadas mundo (centro de celdas)
var _path_cells: Array[Vector2i] = []             # Camino en celdas
var _current_target: Vector2 = Vector2.ZERO       # Punto mundo del próximo “waypoint”
var _goal_cell: Vector2i = Vector2i.ZERO          # Meta actual (para replanear si aparece bloqueo)
var _wander_timer: float = 0.0
var _moving: bool = false
var _wander_scheduled: bool = false
var _last_dir: String = "SE"                      # Dirección para idles (“idle_SE”, etc.)
var _bob_phase: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO

const DIRS4: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]

# ================== READY ==================
func _ready() -> void:
	# Margen mínimo para evitar “flotar” en colisiones
	safe_margin = 0.01

	# Resuelve referencias al piso y capas de bloqueo (tolerante a orden de escena)
	_ensure_tile_refs()
	_resolve_block_layers()
	await get_tree().process_frame
	_ensure_tile_refs()
	_resolve_block_layers()

	# Alinea al centro de celda inicial
	if ground_layer != null or ground_tm != null:
		var c: Vector2i = _world_to_cell(global_position)
		global_position = _cell_center_world(c)

	# Inicializa anim y base del bobbing
	if anim != null:
		anim.speed_scale = 1.0
		_play_idle_anim()
		_base_sprite_pos = anim.position

	# Logs de diagnóstico
	var c2: Vector2i = _world_to_cell(global_position)
	print("[NPC] tile refs ok:", _ensure_tile_refs(), " layer?", ground_layer!=null, " tm?", ground_tm!=null)
	print("[NPC] start cell:", c2, " has_floor:", _cell_has_floor(c2), " used:", _used_rect())

	# Arranca ciclo de paseo
	call_deferred("_kickstart_wander")

func _kickstart_wander() -> void:
	# Programa primer objetivo aleatorio si está idle
	if not _moving and not _wander_scheduled:
		_wander_timer = 0.0
		_wander_pick_long_target()

# ================== LOOP ==================
func _process(delta: float) -> void:
	# Si está idle y no hay path, intenta pasear pasado wander_every
	if not _moving and not _wander_scheduled and _path_world.size() == 0:
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = 0.0
			_wander_pick_long_target()
		return

	# Si sigue caminando o ya hay un paseo encolado, no hace nada aquí
	if _moving or _wander_scheduled:
		return

	# Tick de wander cuando corresponde
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = wander_every
		_wander_pick_long_target()

# ========== FÍSICA (COLISIONES + SLIDE + WATCHDOG) ==========
func _physics_process(delta: float) -> void:
	# Enfriamiento de replanificación
	if _replan_cd > 0.0:
		_replan_cd = max(0.0, _replan_cd - delta)

	if not _ensure_tile_refs():
		return
	if not _moving:
		return

	# (A) Si el próximo tile se volvió bloqueado (dinámico/estático), replantea
	var next_cell: Vector2i = _world_to_cell(_current_target)
	if _is_blocked(next_cell):
		_repath_to_goal()
		return

	# (B) Calcula vector deseado hacia el target a velocidad px/s (según tamaño de tile)
	var to_target: Vector2 = _current_target - global_position
	var px_per_sec: float = tiles_per_second * float(_tile_size().x)
	var desired: Vector2 = Vector2.ZERO
	if to_target != Vector2.ZERO:
		desired = to_target.normalized() * px_per_sec

	# (C) Acelera suavemente hacia la velocidad deseada (si acceleration_px>0)
	if acceleration_px > 0.0:
		velocity = velocity.move_toward(desired, acceleration_px * delta)
	else:
		velocity = desired

	# (D) Evita “pasarse” del target en este frame
	var dist: float = to_target.length()
	var wanted_motion: Vector2 = velocity * delta
	if dist <= stop_epsilon:
		wanted_motion = Vector2.ZERO
	elif wanted_motion.length() > dist:
		wanted_motion = wanted_motion.limit_length(dist)

	# (E) Mueve con move_and_collide y hace slide contra normales (hasta max_slide_bounces)
	var remaining: Vector2 = wanted_motion
	var any_collision: bool = false
	var hit_normal: Vector2 = Vector2.ZERO
	var dir_attempt: Vector2 = Vector2.ZERO
	if desired != Vector2.ZERO:
		dir_attempt = desired.normalized()

	for i in range(max_slide_bounces):
		if remaining.length() <= 0.0001:
			break
		var col := move_and_collide(remaining)
		if col:
			any_collision = true
			hit_normal = col.get_normal()
			remaining = col.get_remainder().slide(hit_normal)
			velocity = velocity.slide(hit_normal)
		else:
			break

	# (F) Distancia post-movimiento para medir progreso
	var new_dist: float = (_current_target - global_position).length()

	# (G) Impacto frontal fuerte => replan (respetando cooldown)
	if any_collision and dir_attempt != Vector2.ZERO and hit_normal != Vector2.ZERO:
		var frontal_impact: bool = dir_attempt.dot(-hit_normal) > 0.8
		if frontal_impact and new_dist > float(_tile_size().x) * 0.25:
			_repath_to_goal()

	# (H) Llegada con snap (ligado al tamaño del tile)
	var snap_eps: float = max(stop_epsilon, float(_tile_size().x) * 0.2)
	if new_dist <= snap_eps:
		global_position = _current_target
		_play_walk_anim(to_target)  # último “facing”
		_advance_path_or_stop()
	else:
		# Actualiza anim según velocidad
		if velocity.length() < 5.0:
			_play_idle_anim()
		else:
			_play_walk_anim(velocity)

	# (I) Watchdog anti-atasco (no hay progreso sostenido)
	var progressed: bool = new_dist < (_last_dist_to_target - progress_epsilon)
	if progressed:
		_stuck_timer = 0.0
	else:
		_stuck_timer += delta
	if _stuck_timer >= repath_on_stuck_time:
		_stuck_timer = 0.0
		_repath_to_goal()
	_last_dist_to_target = new_dist

	# (J) Bobbing del sprite
	_apply_walk_bob(delta)

# ================== API ==================
func go_to_cell(target_cell: Vector2i) -> void:
	# Pide una ruta A* hasta target_cell (en celdas) y arranca el movimiento
	print("[NPC] go_to_cell start:", _current_cell(), " -> target:", target_cell)
	if not _ensure_tile_refs():
		return
	_goal_cell = target_cell

	var start: Vector2i = _current_cell()
	if start == target_cell:
		return

	_path_cells = _astar_path_cells(start, target_cell)
	print("[NPC] A* path len:", _path_cells.size())
	if _path_cells.size() <= 1:
		return

	_path_world.clear()
	for cell in _path_cells:
		_path_world.append(_cell_center_world(cell))

	if _path_world.size() > 0:
		_path_world.remove_at(0)   # descarta la celda actual
	_set_next_target_from_path()

# ================== WANDER ==================
func _wander_pick_long_target() -> void:
	# Elige un destino aleatorio “razonable” dentro del used_rect y que tenga ruta A*
	if not _ensure_tile_refs():
		return

	var start: Vector2i = _current_cell()
	var used: Rect2i = _used_rect()

	# Construye lista de celdas libres (tienen piso y no están bloqueadas)
	var libres: Array[Vector2i] = []
	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c: Vector2i = Vector2i(x, y)
			if c == start:
				continue
			if not _cell_has_floor(c):
				continue
			if _is_blocked(c):
				continue
			libres.append(c)

	print("[NPC] wander libres:", libres.size())
	if libres.is_empty():
		return

	# Filtra por distancia Manhattan dentro de [min, max]
	var cand: Array[Vector2i] = []
	for c in libres:
		var d: int = abs(c.x - start.x) + abs(c.y - start.y)
		if d >= max(1, wander_min_steps) and d <= max(wander_min_steps, wander_max_steps):
			cand.append(c)

	if cand.is_empty():
		cand = (libres.duplicate() as Array[Vector2i])

	cand.shuffle()
	print("[NPC] wander cand:", cand.size())

	# Toma el primer destino con ruta válida
	for target in cand:
		var path: Array[Vector2i] = _astar_path_cells(start, target)
		print("[NPC] wander test target:", target, " path_len:", path.size())
		if path.size() > 1:
			go_to_cell(target)
			return

	# Fallback: vecinos 4-dir inmediatos
	for d in DIRS4:
		var nb: Vector2i = start + d
		if used.has_point(nb) and _cell_has_floor(nb) and not _is_blocked(nb):
			var p2: Array[Vector2i] = _astar_path_cells(start, nb)
			if p2.size() > 1:
				print("[NPC] wander fallback vecino:", nb)
				go_to_cell(nb)
				return

	print("[NPC] wander: sin destino alcanzable (idle).")

func _schedule_next_wander() -> void:
	# Programa una pausa aleatoria antes del siguiente wander
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
	# Avanza al siguiente waypoint o pasa a idle y reprograma wander
	if _path_world.size() == 0:
		print("[NPC] path done -> idle")
		_moving = false
		velocity = Vector2.ZERO
		call_deferred("_to_idle_after_frame")
		return
	_set_next_target_from_path()

func _to_idle_after_frame() -> void:
	await get_tree().process_frame
	_play_idle_anim()
	# Dispara wander inmediatamente
	_wander_timer = 0.0
	_schedule_next_wander()

func _set_next_target_from_path() -> void:
	# Consume el primer waypoint y lo define como target actual
	_current_target = _path_world[0]
	_path_world.remove_at(0)
	_moving = true
	print("[NPC] next target:", _world_to_cell(_current_target), " remaining:", _path_world.size())

func _repath_to_goal() -> void:
	# Replanifica respetando cooldown; si ya está en la meta, pasa a idle
	if _replan_cd > 0.0:
		return
	_replan_cd = replan_cooldown

	if _goal_cell == _current_cell():
		_moving = false
		velocity = Vector2.ZERO
		_play_idle_anim()
		return

	# Si ya hay camino y se está moviendo, evita recalcular en ráfaga
	if _moving and _path_world.size() > 0:
		return

	go_to_cell(_goal_cell)

# ================== A* EN GRILLA ==================
func _mark_solid_with_clearance(grid: AStarGrid2D, bounds: Rect2i, c: Vector2i, clr: int) -> void:
	# Marca celdas sólidas con “grosor” (clearance), para simular el tamaño del agente
	if clr <= 0:
		grid.set_point_solid(c, true)
		return
	for dy in range(-clr, clr + 1):
		for dx in range(-clr, clr + 1):
			var p: Vector2i = c + Vector2i(dx, dy)
			if bounds.has_point(p):
				grid.set_point_solid(p, true)

func _nearest_floor_cell(from_cell: Vector2i) -> Vector2i:
	# Busca la celda con piso más cercana (por distancia cuadrática) dentro del used_rect
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
	# Construye un grid A* limitado a una región y devuelve una ruta en celdas sin diagonales
	var result: Array[Vector2i] = []
	if not _ensure_tile_refs():
		result.append(start)
		return result

	var used: Rect2i = _used_rect()

	# 1) Normaliza start/goal: deben estar dentro de used_rect y sobre piso
	if not used.has_point(start) or not _cell_has_floor(start):
		start = _nearest_floor_cell(start)
	if not used.has_point(goal) or not _cell_has_floor(goal):
		goal = _nearest_floor_cell(goal)

	# 2) Define región del A* como bounding con padding
	var minx: int = min(used.position.x, min(start.x, goal.x)) - 1
	var miny: int = min(used.position.y, min(start.y, goal.y)) - 1
	var maxx: int = max(used.position.x + used.size.x - 1, max(start.x, goal.x)) + 1
	var maxy: int = max(used.position.y + used.size.y - 1, max(start.y, goal.y)) + 1
	var region: Rect2i = Rect2i(Vector2i(minx, miny), Vector2i(maxx - minx + 1, maxy - miny + 1))

	var grid: AStarGrid2D = AStarGrid2D.new()
	grid.region = region
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()

	# 3) Marca sólidos: sin piso o bloqueados; aplica clearance para “engordar” obstáculos
	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			var c: Vector2i = Vector2i(x, y)
			if not _cell_has_floor(c):
				grid.set_point_solid(c, true)
				continue
			if _is_blocked(c):
				_mark_solid_with_clearance(grid, region, c, agent_clearance_tiles)

	# 3.5) Asegura que start/goal queden transitables aunque haya clearance
	if region.has_point(start):
		grid.set_point_solid(start, false)
	if region.has_point(goal):
		grid.set_point_solid(goal, false)

	# 4) Si la meta quedó sólida o fuera de región, aborta con log
	if not region.has_point(goal) or grid.is_point_solid(goal):
		print("[NPC][A*] goal sólido o fuera de región. start:", start, " goal:", goal, " region:", region)
		result.append(start)
		return result

	# 5) Pide camino por IDs y valida
	var id_path: PackedVector2Array = grid.get_id_path(start, goal)
	if id_path.size() == 0:
		print("[NPC][A*] get_id_path vacío. start:", start, " goal:", goal, " region:", region)
		result.append(start)
		return result

	# 6) Convierte a Array[Vector2i]
	for i in id_path.size():
		var v: Vector2 = id_path[i]
		result.append(Vector2i(v))
	return result

# ================== BLOQUEOS ==================
func _is_blocked(c: Vector2i) -> bool:
	# Verdadero si: no hay piso, alguna capa de bloqueo tiene tile, o hay obstáculo dinámico en esa celda
	if not _cell_has_floor(c):
		return true
	if _blocked_in_layers(c):
		return true
	if _blocked_by_dynamic(c):
		return true
	return false

func _blocked_in_layers(c: Vector2i) -> bool:
	# Chequea todas las capas extra provistas en block_layers
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
	# Busca nodos en el grupo dynamic_obstacle_group; bloquean su celda (y opcionalmente vecinas 4-dir)
	for nd in get_tree().get_nodes_in_group(dynamic_obstacle_group):
		if nd == self:
			continue
		if !(nd is Node2D):
			continue
		var cell: Vector2i = _world_to_cell((nd as Node2D).global_position)
		if cell == c:
			return true
		if dynamic_block_neighborhood > 0:
			for d in DIRS4:
				if cell == c + d:
					return true
	return false

# ================== RESOLVER NODOS ==================
func _ensure_tile_refs() -> bool:
	# Asegura que ground_layer o ground_tm apunten a un piso válido. Autodescubre si no se asignó.
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
	# Resuelve y cachea nodos reales de block_layers
	_block_layers_nodes.clear()
	for p in block_layers:
		var nn := get_node_or_null(p)
		if nn != null:
			_block_layers_nodes.append(nn)

# ================== WRAPPERS (TileMap/Layer) ==================
func _tile_size() -> Vector2i:
	if ground_layer != null:
		return ground_layer.tile_set.tile_size
	elif ground_tm != null:
		return ground_tm.tile_set.tile_size
	return Vector2i(32, 32)

func _cell_has_floor(c: Vector2i) -> bool:
	# True si algún layer del piso tiene tile en esa celda
	if ground_layer != null:
		return ground_layer.get_cell_source_id(c) != -1
	elif ground_tm != null:
		var lc: int = ground_tm.get_layers_count()
		for layer in range(lc):
			if ground_tm.get_cell_source_id(layer, c) != -1:
				return true
	return false

func _get_tile_data(c: Vector2i) -> TileData:
	# Devuelve TileData de la primera capa que lo tenga
	if ground_layer != null:
		return ground_layer.get_cell_tile_data(c)
	elif ground_tm != null:
		var lc: int = ground_tm.get_layers_count()
		for layer in range(lc):
			var td := ground_tm.get_cell_tile_data(layer, c)
			if td != null:
				return td
	return null

func _world_to_cell(world_pos: Vector2) -> Vector2i:
	# Convierte posición mundo a celda según sea TileMapLayer o TileMap
	if ground_layer != null:
		return ground_layer.local_to_map(ground_layer.to_local(world_pos))
	elif ground_tm != null:
		return ground_tm.local_to_map(ground_tm.to_local(world_pos))
	return Vector2i.ZERO

func _cell_center_world(c: Vector2i) -> Vector2:
	# Centro de celda en coordenadas mundo
	if ground_layer != null:
		return ground_layer.to_global(ground_layer.map_to_local(c))
	elif ground_tm != null:
		return ground_tm.to_global(ground_tm.map_to_local(c))
	return global_position

func _used_rect() -> Rect2i:
	# Rectángulo de uso del TileMap/Layer (límite de wander)
	if ground_layer != null:
		return ground_layer.get_used_rect()
	elif ground_tm != null:
		return ground_tm.get_used_rect()
	return Rect2i(Vector2i.ZERO, Vector2i(1, 1))

func _current_cell() -> Vector2i:
	return _world_to_cell(global_position)

# ================== ANIMACIÓN ==================
func _play_anim_safe(anim_name: String) -> void:
	# Reproduce anim si existe y evita reinicios innecesarios
	if anim == null:
		return
	var frames: SpriteFrames = anim.sprite_frames
	if frames != null and frames.has_animation(anim_name):
		if anim.animation != anim_name:
			anim.play(anim_name)
		elif anim.speed_scale == 0.0:
			anim.speed_scale = 1.0

func _play_walk_anim(move_vec: Vector2) -> void:
	# Decide “NE/NW/SE/SW” por dot product y ajusta speed_scale según velocidad/tiles_per_second
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
	# Idle en la última dirección conocida
	if anim == null:
		return
	anim.speed_scale = 1.0
	_play_anim_safe("idle_%s" % _last_dir)

func _apply_walk_bob(delta: float) -> void:
	# Bobbing vertical cuando se mueve; resetea al frenar
	if anim == null:
		return
	if velocity.length() < 1.0:
		anim.position = _base_sprite_pos
		_bob_phase = 0.0
		return
	_bob_phase += bob_speed * delta
	var y_off: float = -abs(sin(_bob_phase)) * bob_amount
	anim.position = _base_sprite_pos + Vector2(0, y_off)

# ================== DEBUG: CLICK PARA MOVER ==================
func _unhandled_input(event):
	# Click izquierdo: mueve adonde se clickea (útil para debug)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _ensure_tile_refs():
			return
		var cell: Vector2i
		var gp: Vector2 = get_global_mouse_position()

		if ground_layer != null:
			var local_mouse: Vector2 = ground_layer.to_local(gp)
			cell = ground_layer.local_to_map(local_mouse)
		elif ground_tm != null:
			var local_mouse2: Vector2 = ground_tm.to_local(gp)
			cell = ground_tm.local_to_map(local_mouse2)
		else:
			return

		print("[NPC] click cell:", cell, " has_floor:", _cell_has_floor(cell), " blocked:", _is_blocked(cell))
		go_to_cell(cell)
