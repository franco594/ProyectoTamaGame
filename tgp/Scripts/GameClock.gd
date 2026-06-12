# GameClock.gd
# Agregar como Autoload en Proyecto → Configuración → Autoload
# Nombre del autoload: GameClock
extends Node

# ================== SEÑALES ==================
signal hour_changed(hour: int, minute: int)
signal day_changed(day: int, weekday: String, is_holiday: bool, holiday_name: String)
signal month_changed(month: int, season: String)
signal year_changed(year: int)

# ================== CONFIGURACIÓN (Inspector) ==================
@export var seconds_per_game_hour: float = 60.0
@export var start_hour: int = 8
@export var start_day: int = 1
@export var start_month: int = 1
@export var start_year: int = 2026

# ================== CALENDARIO ==================
const DAYS_PER_MONTH: int = 28
const MONTHS_PER_YEAR: int = 4
const DAYS_PER_WEEK: int = 7

const SEASON_NAMES: Array[String] = ["Otoño", "Invierno", "Primavera", "Verano"]

# Paths a las imágenes de estación
const SEASON_TEXTURES: Array[String] = [
	"res://Resources/Extras/Estacion 0.PNG",
	"res://Resources/Extras/Estacion 1.PNG",
	"res://Resources/Extras/Estacion 2.PNG",
	"res://Resources/Extras/Estacion 3.PNG"
]

const WEEKDAYS: Array[String] = ["LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM"]

const HOLIDAYS: Dictionary = {
	1: { 7: "Festival de la Cosecha",   21: "Noche de las Sombras"   },
	2: { 5: "Festival del Hielo",        20: "Baile de los Copos"     },
	3: { 6: "Día del Florecimiento",     22: "Festival del Huevo"     },
	4: { 4: "Festival del Sol",          19: "Noche de las Estrellas" },
}

# ================== ESTADO ==================
var current_hour: int = 0
var current_minute: int = 0
var current_day: int = 1
var current_month: int = 1
var current_year: int = 2026
var current_weekday_index: int = 0

var _time_accumulator: float = 0.0
var _seconds_per_minute: float = 0.0

# ================== READY ==================
func _ready() -> void:
	current_hour   = start_hour
	current_minute = 0
	current_day    = start_day
	current_month  = start_month
	current_year   = start_year

	var abs_day: int = (current_year - 1) * MONTHS_PER_YEAR * DAYS_PER_MONTH
	abs_day += (current_month - 1) * DAYS_PER_MONTH + (current_day - 1)
	current_weekday_index = abs_day % DAYS_PER_WEEK

	_seconds_per_minute = seconds_per_game_hour / 60.0

# ================== PROCESS ==================
func _process(delta: float) -> void:
	_time_accumulator += delta
	if _time_accumulator >= _seconds_per_minute:
		_time_accumulator -= _seconds_per_minute
		_advance_minute()

# ================== AVANZAR TIEMPO ==================
func _advance_minute() -> void:
	current_minute += 1
	if current_minute >= 60:
		current_minute = 0
		current_hour += 1
		emit_signal("hour_changed", current_hour, current_minute)

		if current_hour >= 24:
			current_hour = 0
			_advance_day()

func _advance_day() -> void:
	current_day += 1
	current_weekday_index = (current_weekday_index + 1) % DAYS_PER_WEEK

	if current_day > DAYS_PER_MONTH:
		current_day = 1
		current_month += 1
		if current_month > MONTHS_PER_YEAR:
			current_month = 1
			current_year += 1
			emit_signal("year_changed", current_year)
		emit_signal("month_changed", current_month, get_season())

	var holiday: String = get_holiday_name()
	var is_hol: bool = holiday != ""
	emit_signal("day_changed", current_day, get_weekday(), is_hol, holiday)

# ================== GETTERS ==================
func get_season() -> String:
	return SEASON_NAMES[current_month - 1]

func get_season_texture() -> Texture2D:
	var path: String = SEASON_TEXTURES[current_month - 1]
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		push_warning("[GameClock] No se pudo cargar la textura: " + path)
	return tex

func get_weekday() -> String:
	return WEEKDAYS[current_weekday_index]

func get_holiday_name() -> String:
	var month_holidays: Dictionary = HOLIDAYS.get(current_month, {})
	return month_holidays.get(current_day, "")

func is_holiday() -> bool:
	return get_holiday_name() != ""

func get_time_string() -> String:
	return "%02d:%02d" % [current_hour, current_minute]

func get_date_string() -> String:
	return "%s %d - %s Año %d" % [get_season(), current_day, get_weekday(), current_year]

func get_day_progress() -> float:
	return (float(current_hour) * 60.0 + float(current_minute)) / (24.0 * 60.0)
