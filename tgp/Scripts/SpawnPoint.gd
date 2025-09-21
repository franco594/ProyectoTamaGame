# SpawnPoint.gd
extends Marker2D
class_name SpawnPoint

@export var id: String = "default"

func _ready() -> void:
	add_to_group("spawnpoint")
