extends Node

func _ready() -> void:
	RoomManager.notify_room_ready("baño", self)
