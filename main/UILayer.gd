extends CanvasLayer
class_name UILayer

const HudScript := preload("res://main/Hud.gd")
const PauseMenuScript := preload("res://main/PauseMenu.gd")

@onready var screens = $Screens
@onready var message_label = $Overlay/Message
@onready var back_button = $Overlay/BackButton
@onready var round_timer_label: Label = $RoundTimer

# HUD colours for the round clock. It goes red once sudden death is close, so
# the player is warned before the arena starts trying to kill them.
const ROUND_TIMER_COLOR_NORMAL := Color(0.976, 0.949, 0.855)
const ROUND_TIMER_COLOR_WARNING := Color(1.0, 0.42, 0.32)

# The in-match scoreboard (main/Hud.gd). Created here rather than in Main.tscn
# so the whole thing lives in one script, and parented under Overlay so it is
# NOT part of the Screens stack -- hide_screen()/hide_all() must not take the
# scoreboard down mid-round. Main shows and hides it around the round.
var hud: Control

# The big centred number counting a round in. Also created here rather than in
# Main.tscn, and also parented under Overlay so the screen stack does not own it.
var countdown_label: Label

# The in-match pause menu (main/PauseMenu.gd). Runs with PROCESS_MODE_ALWAYS and
# owns the pause key itself -- see the note at the top of that file for why it
# cannot live on Main.
var pause_menu: Control

signal change_screen (name, screen)
signal back_button_pressed ()

# Remaining seconds below which the round clock turns red. Kept in step with
# Game.SUDDEN_DEATH_WARNING_SECONDS -- the warning is the only notice the player
# gets before the arena turns lethal.
const ROUND_TIMER_WARNING_SECONDS := 10.0

# NOTE: these carried `set = _set_readonly_variable` -- an empty setter -- to
# make them read-only from outside. GDScript setters also intercept writes from
# INSIDE the class, so `current_screen = screen` in show_screen() was silently
# discarded and current_screen_name was always ''. That broke the Back button in
# online play: Main._on_UILayer_back_button tests the screen name, never matched,
# and fell through to showing MatchScreen again -- so you could never get back to
# the title screen. Same bug class as the one that made OnlineMatch inert.
# Treat them as read-only from outside.
var current_screen: Control = null
var current_screen_name: String = '': get = get_current_screen_name

var _is_ready := false

func _ready() -> void:
	hud = HudScript.new()
	hud.name = "Hud"
	$Overlay.add_child(hud)

	countdown_label = Label.new()
	countdown_label.name = "Countdown"
	countdown_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.add_theme_font_size_override("font_size", 64)
	countdown_label.add_theme_color_override("font_color", Color(0.976, 0.949, 0.855))
	countdown_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	countdown_label.add_theme_constant_override("outline_size", 10)
	countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_label.visible = false
	$Overlay.add_child(countdown_label)

	pause_menu = PauseMenuScript.new()
	pause_menu.name = "PauseMenu"
	$Overlay.add_child(pause_menu)

	for screen in screens.get_children():
		if screen.has_method('_setup_screen'):
			screen._setup_screen(self)

	show_screen("TitleScreen")
	_is_ready = true

func get_current_screen_name() -> String:
	if current_screen:
		return current_screen.name
	return ''

func show_screen(name: String, info: Dictionary = {}) -> void:
	var screen = screens.get_node(name)
	if not screen:
		return
	
	hide_screen()
	screen.visible = true
	if screen.has_method("_show_screen"):
		screen.callv("_show_screen", [info])
	current_screen = screen
	
	if _is_ready:
		emit_signal("change_screen", name, screen)

func hide_screen() -> void:
	if current_screen and current_screen.has_method('_hide_screen'):
		current_screen._hide_screen()
	
	for screen in screens.get_children():
		screen.visible = false
	current_screen = null

func show_message(text: String) -> void:
	message_label.text = text
	message_label.visible = true

func hide_message() -> void:
	message_label.visible = false

func show_back_button() -> void:
	back_button.visible = true

func hide_back_button() -> void:
	back_button.visible = false

func show_countdown(text: String) -> void:
	countdown_label.text = text
	countdown_label.visible = true

func hide_countdown() -> void:
	countdown_label.visible = false

func hide_all() -> void:
	hide_screen()
	hide_message()
	hide_back_button()
	hide_round_timer()

#####
# Round clock HUD
#
# Sits at the top CENTRE of the 640x360 viewport, in the 20px strip above the
# message label (which starts at y=20) and between the mute button (x 0..24) and
# the back button (x 610..638). Those three are the only other things the
# overlay ever draws, so this is the one place nothing has to move.
#####

# The whole HUD state in one call, so the visibility rule lives in exactly one
# place and cannot get out of step with the clock.
#
#   running       the round clock is alive (Game.round_clock_running)
#   sudden_death  the clock has expired and the arena is going lethal
#
# Hidden whenever a screen is up, which covers every menu AND the lobby: those
# are precisely the times a screen is showing and the round is not running.
func set_round_time(seconds_left: float, running: bool, sudden_death: bool = false) -> void:
	if round_timer_label == null:
		return

	if not running or current_screen != null:
		round_timer_label.visible = false
		return

	if sudden_death:
		round_timer_label.text = "SUDDEN DEATH"
		round_timer_label.add_theme_color_override("font_color", ROUND_TIMER_COLOR_WARNING)
	else:
		round_timer_label.text = format_round_time(seconds_left)
		var warning: bool = seconds_left <= ROUND_TIMER_WARNING_SECONDS
		round_timer_label.add_theme_color_override("font_color",
			ROUND_TIMER_COLOR_WARNING if warning else ROUND_TIMER_COLOR_NORMAL)

	round_timer_label.visible = true

func show_round_timer() -> void:
	if round_timer_label != null:
		round_timer_label.visible = true

func hide_round_timer() -> void:
	if round_timer_label != null:
		round_timer_label.visible = false

func is_round_timer_visible() -> bool:
	return round_timer_label != null and round_timer_label.visible

# M:SS, rounded UP: a clock that shows 0:00 while there is still most of a
# second left reads as broken, and 0:00 must mean "expired".
static func format_round_time(seconds_left: float) -> String:
	var total := int(ceil(maxf(0.0, seconds_left)))
	return "%d:%02d" % [total / 60, total % 60]

func _on_BackButton_pressed() -> void:
	emit_signal("back_button_pressed")

func _on_MuteButton_toggled(button_pressed: bool) -> void:
	AudioServer.set_bus_mute(0, button_pressed)
