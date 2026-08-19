class_name Characters
extends RefCounted

# One place that knows what the playable characters are, so the lobby, the
# picker and the player all agree. The order matches Player.PlayerSkin.

const TEXTURES := [
	"res://assets/sprites/whale_orange.png",
	"res://assets/sprites/whale_green.png",
	"res://assets/sprites/whale_blue.png",
	"res://assets/sprites/whale_purple.png",
]

const NAMES := ["Coral", "Kelp", "Tide", "Abyss"]

# The whale sheets are 7x22 frames of 76x66. Frame 1 (top row, second column)
# is the neutral idle pose, which is what the player scene shows at rest.
const SHEET_COLUMNS := 7
const FRAME_SIZE := Vector2(76, 66)
const PORTRAIT_FRAME := 1

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

# A single-frame texture suitable for a UI swatch, cut out of the sheet.
static func get_portrait(index: int) -> AtlasTexture:
	var sheet: Texture2D = load(TEXTURES[clamp_index(index)])
	if sheet == null:
		return null

	var column := PORTRAIT_FRAME % SHEET_COLUMNS
	var row := PORTRAIT_FRAME / SHEET_COLUMNS

	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(
		Vector2(column, row) * FRAME_SIZE,
		FRAME_SIZE)
	return atlas
