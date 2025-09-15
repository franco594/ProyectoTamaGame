# RoomManager.gd (Godot 4.x)
extends Node

@export var fade_duration: float = 0.35

var _is_fading: bool = false
var _canvas: CanvasLayer
var _overlay: ColorRect

func _ready() -> void:
	# Capa de UI por encima de todo
	_canvas = CanvasLayer.new()
	_canvas.layer = 100  # bien arriba
	add_child(_canvas)

	# Rectángulo negro que cubre la pantalla
	_overlay = ColorRect.new()
	_overlay.color = Color.BLACK
	_overlay.modulate.a = 0.0  # transparente al inicio
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.position = Vector2.ZERO
	_overlay.anchor_left = 0.0
	_overlay.anchor_top = 0.0
	_overlay.anchor_right = 1.0
	_overlay.anchor_bottom = 1.0
	_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_canvas.add_child(_overlay)

# Cambia de escena con fundido y coloca al jugador en un SpawnPoint
func goto_scene_fade(scene_path: String, spawn_id: String = "default") -> void:
	if _is_fading:
		return
	_is_fading = true

	await _fade_to(1.0, fade_duration)  # fade OUT

	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_warning("No pude cargar: " + scene_path)
		await _fade_to(0.0, 0.2)
		_is_fading = false
		return

	await get_tree().process_frame  # asegura que la nueva escena esté lista

	# Encontrar player en la nueva escena (o uno persistente)
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		push_warning("No hay nodo en grupo 'player' en la escena destino.")
	else:
		var spawn := _find_spawn(spawn_id)
		if spawn != null:
			player.global_position = spawn.global_position
		else:
			push_warning("No se encontró SpawnPoint con id='" + spawn_id + "'; usando la primera opción disponible.")
			var fallback := _find_spawn("")  # devuelve cualquiera si hay
			if fallback != null:
				player.global_position = fallback.global_position

	await _fade_to(0.0, fade_duration)  # fade IN
	_is_fading = false

func _fade_to(alpha: float, dur: float) -> void:
	var tw := create_tween()
	tw.tween_property(_overlay, "modulate:a", alpha, dur)
	await tw.finished

# Busca un SpawnPoint por id (grupo "spawnpoint")
func _find_spawn(spawn_id: String) -> Node2D:
	var candidates := get_tree().get_nodes_in_group("spawnpoint")
	if candidates.is_empty():
		return null

	if spawn_id != "":
		for n in candidates:
			if "id" in n and (n.id as String) == spawn_id:
				return n as Node2D

	# Si no se pidió uno específico o no existe, devolvemos el primero
	return candidates[0] as Node2D
