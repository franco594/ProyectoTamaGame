# objeto_layer.gd
# Asignar a cada TileMapLayer de objeto grande.
# Ajusta su propio z_index comparándose con el NPC.
extends TileMapLayer

# Fila Y del frente visible del objeto (la fila más baja con píxeles)
@export var front_row: int = 0

# Columnas X que ocupa el objeto
@export var cols: Array[int] = []

# Cuántas filas de alto ocupa visualmente el objeto
@export var height_rows: int = 1	

var _npc: Node2D = null

func _ready() -> void:
	await get_tree().process_frame
	_npc = get_tree().get_first_node_in_group("npc")

func _process(_delta: float) -> void:
	if _npc == null:
		_npc = get_tree().get_first_node_in_group("npc")
		return

	var npc_cell: Vector2i = local_to_map(to_local(_npc.global_position))
	var npc_row: int = npc_cell.y
	var npc_col: int = npc_cell.x

	# El NPC está detrás si:
	# - Su columna está dentro del objeto
	# - Su fila está dentro del rango vertical del objeto
	#   (entre el frente y la parte trasera: front_row - height_rows)
	var back_row: int = front_row - height_rows
	var npc_behind: bool = (
		cols.has(npc_col) and
		npc_row < front_row and
		npc_row >= back_row
	)

	# El objeto tapa al NPC cuando este está detrás
	# z_index alto = objeto encima del NPC
	z_index = 5 if npc_behind else 0
