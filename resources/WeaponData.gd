class_name WeaponData
extends Resource

# Tunables for one weapon, so that adding a weapon is a .tres file (plus the
# scene art) instead of a copy-pasted scene with numbers baked into it.
#
# How the values are applied:
#   - Every field is OPTIONAL. A weapon scene with no `weapon_data` assigned
#     keeps the @export defaults declared in Pickup.gd / Gun.gd, i.e. it behaves
#     exactly as it did before this resource existed.
#   - Pickup._apply_weapon_data() copies the shared fields; each subclass
#     extends that method (via `super`) for the fields it understands. A Sword
#     simply ignores the projectile block.
#
# Adding a new weapon:
#   1. duplicate an existing .tres here, retune the numbers;
#   2. make the scene (art/collision/animations) and give it a script that
#      `extends Pickup` and overrides `use()`;
#   3. set `weapon_data` on the scene root to the new .tres.
# Only add a field here when a *number* differs between weapons -- node names
# and animation tracks are scene structure, not tuning data.

# Purely informational; handy in the inspector and in tests.
@export var weapon_name: String = ""

# --- Shared pickup behaviour (Pickup.gd) -----------------------------------

# Where the player carries it. Mirrors Pickup.PickupPosition; declared as a
# plain int enum here so that WeaponData does not depend on Pickup (which
# depends on WeaponData) and create a cyclic reference.
@export_enum("Front:0", "Back:1") var pickup_position: int = 0

# Fraction of speed kept when a thrown weapon hits geometry.
@export_range(0.0, 1.0, 0.01) var bounce: float = 0.1

# --- Ranged weapons (Gun.gd) -----------------------------------------------
# Ignored by weapons that never fire anything.

# Left null to keep whatever the weapon script preloads.
@export var projectile_scene: PackedScene = null
@export var projectile_velocity: float = 1200.0
@export var projectile_range: float = 400.0

# Seconds between shots (drives the weapon's CooldownTimer).
@export var cooldown_time: float = 0.3

# Shots before the weapon is spent; a spent gun disintegrates when thrown.
@export var max_ammo: int = 3

# ---------------------------------------------------------------------------
# Everything below was added for the Duck-Game-style weapon set. All of it uses
# the same convention as `projectile_scene` above:
#
#     a value of 0 means "leave whatever the weapon script/scene already has".
#
# That matters because the two weapons that shipped first (gun_weapon.tres and
# sword_weapon.tres) predate these fields and therefore serialize them as their
# defaults. If 0 were applied literally, adding a field here would silently
# switch a behaviour off on every existing weapon. The no-op default for each
# field is chosen so that a weapon which never sets it plays exactly as before.
# ---------------------------------------------------------------------------

# --- Thrown-weapon damage (Pickup.gd) --------------------------------------

## Speed (px/s) a THROWN weapon must still be travelling at to kill on contact.
## Lower = deadlier, because the weapon stays lethal further into its arc: a
## heavy sword should sit well below a light gun. A thrown weapon that has
## slowed below this -- or come to rest -- is harmless, so weapons lying on the
## floor are not instant death.
@export var throw_damage_speed: float = 0.0

## Seconds after release during which the THROWER cannot be hit by their own
## throw. Mirrors the "you cannot cut yourself with your own sword" rule in
## Player.hurt(), which only covers a weapon still in your hands.
@export var throw_self_immunity: float = 0.0

# --- Spread weapons (Gun.gd) -----------------------------------------------

## Projectiles per shot. 1 (the default) is an ordinary single-shot gun.
@export var pellet_count: int = 0

## Total width of the pellet fan, in degrees.
@export var spread_degrees: float = 0.0

## Horizontal shove applied to a player hit by one of this weapon's
## projectiles, on top of GameSettings.push_back_speed. This is what makes a
## shotgun able to push someone into a pit.
@export var knockback: float = 0.0

## Upward component of that shove, so victims are lofted rather than scraped
## along the floor.
@export var knockback_up: float = 0.0

## Backwards shove applied to the SHOOTER when the weapon fires.
@export var recoil: float = 0.0

# --- Charged weapons (Bow.gd) ----------------------------------------------
# Ignored by weapons that fire the instant you press the button.

## Seconds of holding "use" to reach a full draw.
@export var draw_seconds: float = 0.75

## Launch speed at zero draw. Draw force buys REACH, not damage: this game is
## one hit, so a tapped shot should drop short and embarrass you rather than be
## a slightly weaker kill.
@export var min_projectile_velocity: float = 260.0

# --- Explosives (Explosive.gd / Grenade.gd / Mine.gd) ----------------------

## Seconds from the fuse being lit to the blast.
@export var fuse_time: float = 0.0

## Radius (px) inside which the blast kills, thrower included.
@export var blast_radius: float = 0.0

## Seconds a dropped mine spends inert before it can trigger, so it cannot be
## used as a suicide-place weapon.
@export var arm_delay: float = 0.0

## Radius (px) at which an armed mine notices a player and detonates.
@export var trigger_radius: float = 0.0

# --- Hitscan (Laser.gd) ----------------------------------------------------

## How far the beam reaches, in px. Should span the arena.
@export var beam_range: float = 0.0

## How long the beam graphic stays on screen, in seconds.
@export var beam_duration: float = 0.0
