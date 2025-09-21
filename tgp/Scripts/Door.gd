# Door.gd
@tool
extends Area2D
class_name Door

@export var room_id: String = ""
@export var entry_cell: Vector2i = Vector2i.ZERO
@export var target_room_id: String = ""
@export var target_spawn_cell: Vector2i = Vector2i.ZERO
@export var locked: bool = false
@export var wander_weight: float = 1.0

@export var debug_tile_size: Vector2i = Vector2i(32, 32) 
@export var show_gizmo_in_editor: bool = true 

func _ready() -> void:
	if not is_in_group("door"):
		add_to_group("door")
	if Engine.is_editor_hint():
		queue_redraw()
	else:
		set_process(false)

func _set_debug_tile(v: Vector2i) -> void:
	debug_tile_size = v
	if Engine.is_editor_hint():
		queue_redraw()

func _set_show(v: bool) -> void:
	show_gizmo_in_editor = v
	if Engine.is_editor_hint():
		queue_redraw()

func _draw() -> void:
	if not Engine.is_editor_hint() or not show_gizmo_in_editor:
		return
	var ts := Vector2(debug_tile_size)
	var origin := Vector2(entry_cell) * ts
	var rect := Rect2(origin, ts)
	draw_rect(rect, Color(0, 1, 0, 0.2), true)
	draw_rect(rect, Color(0, 0.8, 0), false, 2.0)
	var c := origin + ts * 0.5
	draw_line(c + Vector2(-6, 0), c + Vector2(6, 0), Color(0, 0.8, 0), 2.0)
	draw_line(c + Vector2(0, -6), c + Vector2(0, 6), Color(0, 0.8, 0), 2.0)
	var font: Font = ThemeDB.fallback_font
	var fsize: int = ThemeDB.fallback_font_size
	var text := "%s → %s" % [room_id, target_room_id]
	draw_string(font, c + Vector2(8, -8), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize, Color(0, 0.8, 0))
