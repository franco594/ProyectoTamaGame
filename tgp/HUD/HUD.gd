
# HUD.gd (adjuntalo al Control o al CanvasLayer)
extends Control

@export var player_path: NodePath
@onready var player = get_node(player_path)

@onready var portrait: TextureRect = %TextureRect
@onready var life_bar: TextureProgressBar = %LifeBar
@onready var stamina_bar: TextureProgressBar = %StaminaBar
@onready var hunger_bar: TextureProgressBar = %HungerBar
@onready var sanity_bar: TextureProgressBar = %SanityBar

func _ready():
	# Configurar rangos
	life_bar.max_value = player.max_health
	stamina_bar.max_value = player.max_stamina
	hunger_bar.max_value = player.max_hunger
	sanity_bar.max_value = player.max_sanity

	# Set inicial
	_update_all()

	# Conectar señales del Player (definilas en el Player)
	player.health_changed.connect(_on_health_changed)
	player.stamina_changed.connect(_on_stamina_changed)
	player.hunger_changed.connect(_on_hunger_changed)
	player.sanity_changed.connect(_on_sanity_changed)
	player.portrait_changed.connect(_on_portrait_changed)

func _update_all():
	life_bar.value = player.health
	stamina_bar.value = player.stamina
	hunger_bar.value = player.hunger
	sanity_bar.value = player.sanity
	if player.portrait_texture:
		portrait.texture = player.portrait_texture

# Opcional: suavizar con Tween
func _tween_to(bar: TextureProgressBar, target: float):
	var tw := create_tween()
	tw.tween_property(bar, "value", target, 0.25)

func _on_health_changed(v: float):
	_tween_to(life_bar, clamp(v, 0.0, life_bar.max_value))
	# feedback de bajo HP
	if v / life_bar.max_value < 0.2:
		life_bar.modulate = Color(1, 0.6, 0.6)
	else:
		life_bar.modulate = Color(1, 1, 1)

func _on_stamina_changed(v: float):
	_tween_to(stamina_bar, clamp(v, 0.0, stamina_bar.max_value))

func _on_hunger_changed(v: float):
	_tween_to(hunger_bar, clamp(v, 0.0, hunger_bar.max_value))

func _on_sanity_changed(v: float):
	_tween_to(sanity_bar, clamp(v, 0.0, sanity_bar.max_value))

func _on_portrait_changed(tex: Texture2D):
	portrait.texture = tex
