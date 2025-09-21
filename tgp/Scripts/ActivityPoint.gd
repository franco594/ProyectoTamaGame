# ActivityPoint.gd
extends Marker2D
class_name ActivityPoint

@export var room_id: String = "kitchen"
@export var entry_cell: Vector2i = Vector2i.ZERO
@export var kind: String = "eat"                             # "eat","sleep","fun"...
@export var need_effect := {"hunger": -0.5}                  # reduce necesidades (valores negativos)
@export var duration: float = 3.0
@export var cooldown: float = 5.0
@export var priority_bias: float = 0.0

var _cool_until: float = 0.0

func _ready() -> void:
	add_to_group("activity_point")

func is_available(now: float) -> bool:
	return now >= _cool_until

func reserve(now: float) -> void:
	_cool_until = now + cooldown
