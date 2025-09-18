extends Node

func _ready():
	var tex = preload("res://cursor.png")  # poné tu imagen
	# Vector2 es el hotspot (dónde "pincha" el cursor)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(8, 8))
