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
