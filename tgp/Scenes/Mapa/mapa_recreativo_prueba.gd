extends Node

func _ready() -> void:
	RoomManager.notify_room_ready("recreativo", self)
