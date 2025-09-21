# DoorToScene.gd
extends Area2D

@export_file("*.tscn") var target_scene: String
@export var target_spawn_id: String = "default"

func _ready() -> void:
	input_pickable = true
	self.input_event.connect(_on_input_event)

func _on_input_event(viewport, event, shape_idx) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if target_scene == "":
			push_warning("DoorToScene: target_scene sin asignar.")
			return
		await RoomM.goto_scene_fade(target_scene, target_spawn_id)
