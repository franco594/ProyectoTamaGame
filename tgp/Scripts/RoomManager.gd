# RoomManager.gd (autoload)
extends Node

@export var fade_duration: float = 0.35
@export var start_room_id: String = "comedor"

var _room_paths: Dictionary = {}
var _loaded_rooms: Dictionary = {}
var _active_room_id: String = ""
var _npc_room_id: String = ""
var _room_doors: Dictionary = {}
var _room_activities: Dictionary = {}

var _is_fading := false
var _npc_transitioning := false

var _canvas: CanvasLayer
var _overlay: ColorRect

func _ready() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 200
	add_child(_canvas)

	_overlay = ColorRect.new()
	_overlay.color = Color.BLACK
	_overlay.modulate.a = 0.0
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(_overlay)

	call_deferred("_load_start_room")

func _load_start_room() -> void:
	var room = _ensure_room_loaded(start_room_id)
	if room != null:
		_active_room_id = start_room_id
		_npc_room_id = start_room_id
		_set_room_visible(room, true)

		var npc = get_tree().get_first_node_in_group("npc")
		if npc != null:
			var floor_node = get_floor(start_room_id)
			if floor_node != null:
				npc.ground_layer = null
				npc.ground_tm = null
				npc.tile_node = floor_node.get_path()
				await get_tree().process_frame
				if npc.has_method("_ensure_tile_refs"):
					npc._ensure_tile_refs()
				if npc.has_method("_resolve_block_layers"):
					npc._resolve_block_layers()
				npc._current_cell = npc._world_to_cell(npc.global_position)
				npc.global_position = npc._cell_center_world(npc._current_cell)
				# NPC visible solo en la habitación inicial
				npc.visible = true
				npc.modulate.a = 1.0

# --- Registro ---
func register_room(room_id: String, scene_path: String) -> void:
	_room_paths[room_id] = scene_path

func notify_room_ready(room_id: String, root_node: Node) -> void:
	_loaded_rooms[room_id] = root_node
	_room_doors.erase(room_id)
	_room_activities.erase(room_id)

# --- Carga ---
func _ensure_room_loaded(room_id: String) -> Node:
	if _loaded_rooms.has(room_id):
		return _loaded_rooms[room_id]
	if not _room_paths.has(room_id):
		push_warning("[RoomManager] room no registrado: %s" % room_id)
		return null
	var ps: PackedScene = load(_room_paths[room_id])
	if ps == null:
		push_warning("[RoomManager] no se pudo cargar: %s" % _room_paths[room_id])
		return null
	var inst: Node = ps.instantiate()
	get_tree().root.add_child(inst)
	_loaded_rooms[room_id] = inst
	_set_room_visible(inst, false)
	return inst

# --- Visibilidad ---
func _set_room_visible(room: Node, vis: bool) -> void:
	room.process_mode = Node.PROCESS_MODE_INHERIT if vis else Node.PROCESS_MODE_DISABLED
	if room is CanvasItem:
		(room as CanvasItem).visible = vis
	for c in room.get_children():
		_set_room_visible_recursive(c, vis)

func _set_room_visible_recursive(node: Node, vis: bool) -> void:
	if node is CanvasItem:
		(node as CanvasItem).visible = vis
	for c in node.get_children():
		_set_room_visible_recursive(c, vis)

func _update_npc_visibility() -> void:
	var npc = get_tree().get_first_node_in_group("npc")
	if npc == null:
		return
	var should_be_visible: bool = (_npc_room_id == _active_room_id)
	npc.visible = should_be_visible
	if should_be_visible:
		npc.modulate.a = 1.0

# --- Jugador cambia de habitación ---
func change_player_room(target_room_id: String) -> void:
	if _active_room_id == target_room_id:
		return
	if _is_fading:
		return
	_is_fading = true

	await _fade_to(1.0, fade_duration)

	if _active_room_id != "" and _loaded_rooms.has(_active_room_id):
		_set_room_visible(_loaded_rooms[_active_room_id], false)

	_ensure_room_loaded(target_room_id)
	if _loaded_rooms.has(target_room_id):
		_set_room_visible(_loaded_rooms[target_room_id], true)
		_active_room_id = target_room_id

	# Actualizar visibilidad del NPC según habitación activa
	_update_npc_visibility()

	await _fade_to(0.0, fade_duration)
	_is_fading = false

# --- NPC cambia de habitación ---
func move_npc_to_room(npc: Node, target_room_id: String, spawn_cell: Vector2i) -> void:
	if _npc_transitioning:
		return
	_npc_transitioning = true

	# Ocultar NPC inmediatamente
	npc.visible = false
	npc.modulate.a = 0.0
	if npc.has_method("get") and "_tween" in npc:
		var t = npc._tween
		if t != null and t.is_valid():
			t.kill()

	# Asegurarse que la habitación destino esté cargada
	_ensure_room_loaded(target_room_id)

	# Reasignar piso al NPC
	var floor_node := get_floor(target_room_id)
	if floor_node == null:
		push_warning("[RoomManager] floor no encontrado: %s" % target_room_id)
		_update_npc_visibility()
		_npc_transitioning = false
		return

	npc.ground_layer = null
	npc.ground_tm = null
	npc.tile_node = floor_node.get_path()

	await get_tree().process_frame

	if npc.has_method("_ensure_tile_refs"):
		npc._ensure_tile_refs()
	if npc.has_method("_resolve_block_layers"):
		npc._resolve_block_layers()

	npc.global_position = npc._cell_center_world(spawn_cell)
	npc._current_cell = spawn_cell
	npc._path_cells.clear()
	npc._moving = false
	npc.velocity = Vector2.ZERO
	_npc_room_id = target_room_id

	if npc.has_method("_play_idle_anim"):
		npc._play_idle_anim()

	# Mostrar NPC con fade-in solo si el jugador está viendo esa habitación
	if _active_room_id == target_room_id:
		npc.visible = true
		npc.modulate.a = 0.0
		var tw_in := create_tween()
		tw_in.tween_property(npc, "modulate:a", 1.0, 0.3)
		await tw_in.finished
	else:
		# El NPC está en otra habitación — invisible
		npc.visible = false
		npc.modulate.a = 1.0

	_npc_transitioning = false

	if npc.has_signal("room_changed"):
		npc.emit_signal("room_changed", target_room_id)

# --- Floor ---
func get_floor(room_id: String) -> Node:
	var root: Node = _loaded_rooms.get(room_id, null)
	if root == null:
		return null
	var piso: Node = root.find_child("Piso", true, false)
	if piso != null:
		return piso
	for n in get_tree().get_nodes_in_group("ground"):
		if root.is_ancestor_of(n):
			return n
	return null

# --- Puertas y actividades ---
func get_doors(room_id: String) -> Array:
	if not _room_doors.has(room_id):
		_rebuild_doors(room_id)
	return _room_doors.get(room_id, [])

func get_activities(room_id: String) -> Array:
	if not _room_activities.has(room_id):
		_rebuild_activities(room_id)
	return _room_activities.get(room_id, [])

func _rebuild_doors(room_id: String) -> void:
	var doors: Array = []
	for nd in get_tree().get_nodes_in_group("door"):
		if "room_id" in nd and nd.room_id == room_id:
			doors.append(nd)
	_room_doors[room_id] = doors

func _rebuild_activities(room_id: String) -> void:
	var arr: Array = []
	for nd in get_tree().get_nodes_in_group("activity_point"):
		if "room_id" in nd and nd.room_id == room_id:
			arr.append(nd)
	_room_activities[room_id] = arr

func invalidate_room_cache(room_id: String) -> void:
	_room_doors.erase(room_id)
	_room_activities.erase(room_id)

# --- Fade de pantalla ---
func _fade_to(alpha: float, dur: float) -> void:
	var tw := create_tween()
	tw.tween_property(_overlay, "modulate:a", alpha, dur)
	await tw.finished

func goto_scene_fade(scene_path: String, spawn_id: String = "default") -> void:
	pass
