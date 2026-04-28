# RoomRegistry.gd
# Autoload que registra todas las habitaciones en el RoomManager.
extends Node

func _ready() -> void:
	print("[Registry] registrando habitaciones...")
	RoomManager.register_room("balcon",     "res://Scenes/Mapa/MapaBalconPrueba.tscn")
	RoomManager.register_room("baño",       "res://Scenes/Mapa/MapaBañoPrueba.tscn")
	RoomManager.register_room("cocina",     "res://Scenes/Mapa/MapaCocinaPrueba.tscn")
	RoomManager.register_room("comedor",    "res://Scenes/Mapa/MapaComedorPrueba.tscn")
	RoomManager.register_room("dormitorio", "res://Scenes/Mapa/MapaDormitorioPrueba.tscn")
	RoomManager.register_room("entrada",    "res://Scenes/Mapa/MapaEntradaPrueba.tscn")
	RoomManager.register_room("lavadero",   "res://Scenes/Mapa/MapaLavaderoPrueba.tscn")
	RoomManager.register_room("recreativo", "res://Scenes/Mapa/MapaRecreativoPrueba.tscn")
	print("[Registry] listo")
