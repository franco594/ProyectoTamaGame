# DoorToScene.gd
# El jugador hace click para cambiar la habitación visible.
# No afecta al NPC.
extends Area2D

@export var target_room_id: String = ""
@export var clickable: bool = true

func _ready() -> void:
	if clickable:
		input_pickable = true
		self.input_event.connect(_on_input_event)

func _on_input_event(_viewport, event, _shape_idx) -> void:
	#print("[Door] input event:", event)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		activate()

func activate() -> void:
	print("[Door] activate target_room_id:", target_room_id)
	if target_room_id == "":
		push_warning("DoorToScene '%s': target_room_id no asignado." % name)
		return
	var rm: Node = get_node_or_null("/root/RoomManager")
	print("[Door] rm:", rm)
	if rm != null and rm.has_method("change_player_room"):
		rm.change_player_room(target_room_id)
