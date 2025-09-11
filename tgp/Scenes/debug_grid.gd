# DebugGrid.gd — Godot 4.x
extends Node2D

@export var floor_node: NodePath                # TileMap o TileMapLayer del PISO
@export var block_layers: Array[NodePath] = []  # Capas que bloquean (Pared, Objetos…)
@export var refresh_every := 0.25               # segundos entre repintados
@export var show_empty := false                 # dibujar celdas sin piso (gris)
@export var alpha := 0.28                       # transparencia del overlay

# Tecla para alternar overlay (puedes mapear "F3" a esta acción en Input Map)
@export var toggle_action := "toggle_grid_debug"

var _floor_tm: TileMap = null
var _floor_layer: TileMapLayer = null
var _blocks: Array = []
var _enabled := true
var _acc := 0.0

func _ready() -> void:
	_resolve_nodes()
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	if toggle_action != "" and Input.is_action_just_pressed(toggle_action):
		_enabled = !_enabled
		queue_redraw()
	if not _enabled:
		return
	_acc += delta
	if _acc >= refresh_every:
		_acc = 0.0
		queue_redraw()

func _draw() -> void:
	if not _enabled: return
	if not _resolve_nodes(): return

	var used := _used_rect()
	var ts := _tile_size()
	for y in range(used.position.y, used.position.y + used.size.y):
		for x in range(used.position.x, used.position.x + used.size.x):
			var c := Vector2i(x, y)
			var has_floor := _floor_has(c)
			var blocked := has_floor and _blocked_cell(c)

			var col := Color(0,0,0,0)
			if blocked:
				col = Color(1,0,0,alpha)     # rojo: bloqueado
			elif has_floor:
				col = Color(0,1,0,alpha)     # verde: caminable
			elif show_empty:
				col = Color(0.5,0.5,0.5,alpha)  # gris: sin piso

			if col.a > 0.0:
				# Dibujamos un rombo isométrico (4 vértices) centrado en la celda
				var center_local := _map_to_local(c)
				var oE := Vector2(ts.x * 0.5, 0)
				var oW := -oE
				var oS := Vector2(0, ts.y * 0.5)
				var oN := -oS
				var pts := PackedVector2Array([
					_to_global(center_local + oN),
					_to_global(center_local + oE),
					_to_global(center_local + oS),
					_to_global(center_local + oW),
				])
				draw_colored_polygon(pts, col)

func _resolve_nodes() -> bool:
	if _floor_layer == null and _floor_tm == null:
		var n := get_node_or_null(floor_node)
		if n is TileMapLayer:
			_floor_layer = n
		elif n is TileMap:
			_floor_tm = n
	for p in block_layers:
		var n2 := get_node_or_null(p)
		if n2 != null and not _blocks.has(n2):
			_blocks.append(n2)
	return (_floor_layer != null) or (_floor_tm != null)

func _tile_size() -> Vector2i:
	if _floor_layer != null:
		return _floor_layer.tile_set.tile_size
	elif _floor_tm != null:
		return _floor_tm.tile_set.tile_size
	return Vector2i(32,16)

func _used_rect() -> Rect2i:
	if _floor_layer != null:
		return _floor_layer.get_used_rect()
	else:
		return _floor_tm.get_used_rect()

func _map_to_local(c: Vector2i) -> Vector2:
	if _floor_layer != null:
		return _floor_layer.map_to_local(c)
	else:
		return _floor_tm.map_to_local(c)

func _to_global(p_local: Vector2) -> Vector2:
	if _floor_layer != null:
		return _floor_layer.to_global(p_local)
	else:
		return _floor_tm.to_global(p_local)

func _floor_has(c: Vector2i) -> bool:
	if _floor_layer != null:
		return _floor_layer.get_cell_source_id(c) != -1
	else:
		return _floor_tm.get_cell_source_id(0, c) != -1

func _blocked_cell(c: Vector2i) -> bool:
	# Cualquier tile en capas de bloqueo cuenta como obstáculo.
	for n in _blocks:
		if n is TileMapLayer:
			var lyr: TileMapLayer = n
			if lyr.get_cell_source_id(c) != -1:
				var td := lyr.get_cell_tile_data(c)
				# Si hay Custom Data, respétalo (Blocked/blocked). Si no hay, bloquea por estar pintado.
				if td == null: return true
				if td.get_custom_data("Blocked") == true or td.get_custom_data("blocked") == true:
					return true
		elif n is TileMap:
			var tm: TileMap = n
			if tm.get_cell_source_id(0, c) != -1:
				var td2 := tm.get_cell_tile_data(0, c)
				if td2 == null: return true
				if td2.get_custom_data("Blocked") == true or td2.get_custom_data("blocked") == true:
					return true
	return false
