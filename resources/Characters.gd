class_name Characters
extends RefCounted

# One place that knows what the playable characters are, so the lobby, the
# picker and the player all agree. The order matches Player.PlayerSkin.

const TEXTURES := [
	"res://assets/doodle/sprites/char_butter.png",
	"res://assets/doodle/sprites/char_chili.png",
	"res://assets/doodle/sprites/char_moody.png",
	"res://assets/doodle/sprites/char_sprout.png",
]

# Named for their faces: the expression is baked into each colour, so a
# character has a temperament rather than being a palette swap.
const NAMES := ["Butter", "Chili", "Moody", "Sprout"]

# Each character's body colour, MEASURED from the sprite rather than eyeballed
# (tools/style_normalize.py learn: the fill is 52-54% of every character, by far
# its largest flat area). Anything drawn in code that has to match the body --
# the held hand, for one -- reads as a different character if the hue is even
# slightly off, so these are taken from the art and not chosen to look right.
const COLORS := [
	Color("ffb600"),   # Butter
	Color("fc5c65"),   # Chili
	Color("9179ff"),   # Moody
	Color("37d98c"),   # Sprout
]

# The ink these sprites are outlined in. Also measured -- it is #282828 across
# all ten art files, NOT pure black, and a true black border beside it reads as
# a different, harder line.
const INK := Color("282828")

static func body_color(index: int) -> Color:
	return COLORS[clamp_index(index)]

# One sprite per character now, rather than a frame out of an animation sheet:
# the Scribble characters have no animation frames at all, and motion comes from
# squash and stretch in Player.gd instead. FRAME_SIZE is therefore the whole
# image, and the portrait is the image itself.
const SHEET_COLUMNS := 1
const FRAME_SIZE := Vector2(48, 68)
const PORTRAIT_FRAME := 0

static func count() -> int:
	return TEXTURES.size()

static func clamp_index(index: int) -> int:
	if TEXTURES.is_empty():
		return 0
	return posmod(index, TEXTURES.size())

# NOT get_name(): GDScript itself already exposes a zero-argument get_name,
# so a static method of that name is unreachable.
static func character_name(index: int) -> String:
	return NAMES[clamp_index(index)]

# A texture suitable for a UI swatch. Still returns an AtlasTexture so callers
# (the lobby picker, the scoreboard) keep working unchanged; the region is just
# the whole image now.
static func get_portrait(index: int) -> AtlasTexture:
	var sheet: Texture2D = load(TEXTURES[clamp_index(index)])
	if sheet == null:
		return null

	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(Vector2.ZERO, FRAME_SIZE)
	return atlas
