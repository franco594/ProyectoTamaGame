extends Node
func _ready() -> void:
	RoomM.register_room("entrada", $Piso) # o $TileMap
