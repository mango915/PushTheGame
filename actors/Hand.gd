extends Node2D

# The hand a carried weapon is held in.
#
# The Scribble characters have no limbs at all -- verified against the whole
# 1408x1408 sheet -- so a carried weapon hung in the air with nothing joining it
# to the body. A full jointed ARM was tried first and read as a scratch across
# the character's face: at 48x68 there is no room for a limb, and this style has
# no linework that fine anywhere in it.
#
# A single filled circle with an ink border does read, because that IS the
# vocabulary here. Every character is one flat shape with an outline and a face;
# a dot with an outline belongs to the same drawing. It costs no art, works for
# all four characters and every weapon, and needs no animation of its own --
# it sits on the carry marker, so it follows a swing for free.

const RADIUS := 4.5
const BORDER := 2.0

var color: Color = Color(1, 1, 1):
	set(value):
		# Redraw on assignment: the colour changes when the skin changes, which
		# is not a frame event, so nothing else would trigger it.
		color = value
		queue_redraw()

var ink: Color = Color(0.157, 0.157, 0.157):
	set(value):
		ink = value
		queue_redraw()

func _draw() -> void:
	# Border first, as a larger disc underneath -- draw_circle has no outline
	# parameter, and stroking an arc leaves a seam at the join.
	draw_circle(Vector2.ZERO, RADIUS + BORDER, ink)
	draw_circle(Vector2.ZERO, RADIUS, color)
