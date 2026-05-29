# ClockHUD.gd
# Asigná este script al nodo CanvasLayer del reloj
extends CanvasLayer

# ================== REFERENCIAS (asignar en Inspector) ==================
@export var lbl_clock: NodePath        # Label con el reloj digital  "08:00"
@export var lbl_day: NodePath          # Label con día del mes       "Día 1"
@export var lbl_weekday: NodePath      # Label con nombre del día    "Lunes"
@export var lbl_season: NodePath       # Label con estación          "Otoño"
@export var lbl_year: NodePath         # Label con año               "Año 1"
@export var lbl_holiday: NodePath      # Label festivo (se oculta si no hay)
@export var day_buttons: Array[NodePath] = []  # Los 7 botones de días de la semana

var _lbl_clock: Label
var _lbl_day: Label
var _lbl_weekday: Label
var _lbl_season: Label
var _lbl_year: Label
var _lbl_holiday: Label
var _day_buttons: Array[Button] = []

# ================== READY ==================
func _ready() -> void:
	_lbl_clock   = get_node_or_null(lbl_clock)   as Label
	_lbl_day     = get_node_or_null(lbl_day)      as Label
	_lbl_weekday = get_node_or_null(lbl_weekday)  as Label
	_lbl_season  = get_node_or_null(lbl_season)   as Label
	_lbl_year    = get_node_or_null(lbl_year)     as Label
	_lbl_holiday = get_node_or_null(lbl_holiday)  as Label

	for p in day_buttons:
		var b: Button = get_node_or_null(p) as Button
		if b != null:
			_day_buttons.append(b)

	# Conectar señales del GameClock
	if GameClock:
		GameClock.hour_changed.connect(_on_hour_changed)
		GameClock.day_changed.connect(_on_day_changed)
		GameClock.month_changed.connect(_on_month_changed)
		GameClock.year_changed.connect(_on_year_changed)

	# Mostrar estado inicial
	_refresh_all()

# ================== ACTUALIZACIÓN ==================
func _process(_delta: float) -> void:
	# Actualizar el reloj cada frame para mostrar los minutos fluidamente
	if _lbl_clock != null and GameClock:
		_lbl_clock.text = GameClock.get_time_string()

func _refresh_all() -> void:
	if not GameClock:
		return

	if _lbl_clock   != null: _lbl_clock.text   = GameClock.get_time_string()
	if _lbl_day     != null: _lbl_day.text      = "Día %d" % GameClock.current_day
	if _lbl_weekday != null: _lbl_weekday.text  = GameClock.get_weekday()
	if _lbl_season  != null: _lbl_season.text   = GameClock.get_season()
	if _lbl_year    != null: _lbl_year.text      = "Año %d" % GameClock.current_year

	_update_holiday()
	_update_day_buttons()

func _update_holiday() -> void:
	if _lbl_holiday == null:
		return
	var holiday: String = GameClock.get_holiday_name()
	if holiday != "":
		_lbl_holiday.text    = "🎉 " + holiday
		_lbl_holiday.visible = true
	else:
		_lbl_holiday.visible = false

func _update_day_buttons() -> void:
	# Resalta el botón del día de la semana actual
	# Los botones deben estar en orden Lunes→Domingo
	for i in range(_day_buttons.size()):
		var btn: Button = _day_buttons[i]
		if btn == null:
			continue
		# El botón activo es el del weekday actual
		if i == GameClock.current_weekday_index:
			btn.modulate = Color(1.0, 0.85, 0.2)   # amarillo dorado = día actual
		else:
			btn.modulate = Color(1.0, 1.0, 1.0)     # blanco = inactivo

# ================== SEÑALES DEL GAMECLOCK ==================
func _on_hour_changed(_hour: int, _minute: int) -> void:
	pass  # el reloj se actualiza en _process

func _on_day_changed(day: int, weekday: String, is_holiday: bool, holiday_name: String) -> void:
	if _lbl_day     != null: _lbl_day.text     = "Día %d" % day
	if _lbl_weekday != null: _lbl_weekday.text = weekday
	_update_holiday()
	_update_day_buttons()

func _on_month_changed(_month: int, season: String) -> void:
	if _lbl_season != null: _lbl_season.text = season

func _on_year_changed(year: int) -> void:
	if _lbl_year != null: _lbl_year.text = "Año %d" % year
