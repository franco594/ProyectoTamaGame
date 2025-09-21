extends Node
func _ready() -> void:
	RoomM.register_room("baño", $Piso) # o $TileMap
