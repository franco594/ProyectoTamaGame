# RoomManager.gd (autoload)
extends Node
class_name RoomManager

@export var fade_duration: float = 0.35

# Piso por sala (TileMap o TileMapLayer)
var rooms_floor: Dictionary = {}         # { room_id: NodePath }
# Puertas por sala
var room_doors: Dictionary = {}          # { room_id: Array[Door] }
# Puntos de actividad por sala
var room_activities: Dictionary = {}     # { room_id: Array[ActivityPoint] }

var _is_fading := false
var _canvas: CanvasLayer
var _overlay: ColorRect

func _ready() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 100
	add_child(_canvas)

	_overlay = ColorRect.new()
	_overlay.color = Color.BLACK
	_overlay.modulate.a = 0.0
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.anchor_left = 0.0
	_overlay.anchor_top = 0.0
	_overlay.anchor_right = 1.0
	_overlay.anchor_bottom = 1.0
	_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.add_child(_overlay)

# --- Registro de salas ---
func register_room(room_id: String, floor_node: Node) -> void:
	rooms_floor[room_id] = floor_node.get_path()
	_rebuild_room_doors(room_id)
	_rebuild_room_activities(room_id)

func _rebuild_room_doors(room_id: String) -> void:
	var doors: Array = []
	for nd in get_tree().get_nodes_in_group("door"):
		if nd is Door and nd.room_id == room_id:
			doors.append(nd)
	room_doors[room_id] = doors

func _rebuild_room_activities(room_id: String) -> void:
	var arr: Array = []
	for nd in get_tree().get_nodes_in_group("activity_point"):
		if nd is ActivityPoint and nd.room_id == room_id:
			arr.append(nd)
	room_activities[room_id] = arr

func get_floor_node(room_id: String) -> Node:
	var p: NodePath = rooms_floor.get(room_id, NodePath(""))
	if p.is_empty():
		return null
	return get_tree().root.get_node_or_null(p)

func get_doors(room_id: String) -> Array:
	if not room_doors.has(room_id):
		_rebuild_room_doors(room_id)
	return room_doors.get(room_id, [])

func get_activities(room_id: String) -> Array:
	if not room_activities.has(room_id):
		_rebuild_room_activities(room_id)
	return room_activities.get(room_id, [])

# --- Cambio de sala sin cambiar de escena (teleport dentro del mundo) ---
func move_npc_to_room(npc: Node, target_room_id: String, spawn_cell: Vector2i) -> void:
	var floor := get_floor_node(target_room_id)
	if floor == null:
		push_warning("[RoomManager] floor no encontrado para room: %s" % target_room_id)
		return
	npc.tile_node = floor.get_path()
	if npc.has_method("_ensure_tile_refs"):
		npc._ensure_tile_refs()
	if npc.has_method("_cell_center_world"):
		var spawn_world: Vector2 = npc._cell_center_world(spawn_cell)
		npc.global_position = spawn_world
	if "velocity" in npc:
		npc.velocity = Vector2.ZERO
	if "_path_world" in npc:
		npc._path_world.clear()
	if "_moving" in npc:
		npc._moving = false
	if npc.has_method("_play_idle_anim"):
		npc._play_idle_anim()
	if npc.has_signal("room_changed"):
		npc.emit_signal("room_changed", target_room_id)

# --- Cambio de escena con fade (y spawn del player) ---
func goto_scene_fade(scene_path: String, spawn_id: String = "default") -> void:
	if _is_fading:
		return
	_is_fading = true

	await _fade_to(1.0, fade_duration)

	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_warning("No pude cargar: " + scene_path)
		await _fade_to(0.0, 0.2)
		_is_fading = false
		return

	await get_tree().process_frame

	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		push_warning("No hay nodo en grupo 'player' en la escena destino.")
	else:
		var spawn := _find_spawn(spawn_id)
		if spawn != null:
			player.global_position = spawn.global_position
		else:
			push_warning("SpawnPoint id='%s' no encontrado; usando el primero disponible." % spawn_id)
			var fallback := _find_spawn("")
			if fallback != null:
				player.global_position = fallback.global_position

	await _fade_to(0.0, fade_duration)
	_is_fading = false

func _fade_to(alpha: float, dur: float) -> void:
	var tw := create_tween()
	tw.tween_property(_overlay, "modulate:a", alpha, dur)
	await tw.finished

func _find_spawn(spawn_id: String) -> Node2D:
	var candidates := get_tree().get_nodes_in_group("spawnpoint")
	if candidates.is_empty():
		return null
	if spawn_id != "":
		for n in candidates:
			if n is SpawnPoint and (n as SpawnPoint).id == spawn_id:
				return n as Node2D
			if n.has_method("get") and n.get("id") == spawn_id:
				return n as Node2D
	return candidates[0] as Node2D
