## Written by Claude (claude-opus-5-5), 2026-11-23: headless self-test of the four-faction mass battle's archers (the owner's test of
## behaviour switching, pawn spec 10.13): they shoot until their magazine is empty (archer_bolt_attack.tres, 6 bolts), then fight in
## melee, and go back to keeping their distance once all 6 come back. It checks the switch happens both ways, that no archer keeps
## its distance with an empty magazine, and that the has-ammo tag follows the charges.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/samples/tests/archer_switch_selftest.tscn"
extends SelfTest

const SECONDS := 32

var _arena: Node = null
var _watched := {}
var _went_dry := 0 # a magazine ran out
var _chased_dry := 0 # Chase chosen with no bolts left
var _kept_distance_dry := 0 # Keep Distance chosen with no bolts left: should never happen
var _back := 0 # Keep Distance chosen again after a refill
var _tag_wrong := 0 # the has-ammo tag disagreeing with the charges, at a switch


func _ready() -> void:
	print("--- Archer switch self-test ---")
	TickDriver.load_step_override = 1 # every pawn every tick, whatever the machine's load
	_arena = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	_arena.team_size = 25
	add_child(_arena)
	await get_tree().physics_frame
	_arena._start_offline()
	for i in SECONDS * TickDriver.get_tick_rate():
		await get_tree().physics_frame
		if i % 30 == 0:
			_watch_new_archers()
	print("  archers %d: magazines ran dry %d, Chase chosen dry %d, back to Keep Distance after a refill %d" % [_watched.size(), _went_dry, _chased_dry, _back])
	_check(_watched.size() >= 20, "archers spawned with a magazine (%d)" % _watched.size())
	_check(_went_dry >= 5 and _chased_dry >= 5, "archers run out of bolts and close in to melee (%d dry, %d chases)" % [_went_dry, _chased_dry])
	_check(_back >= 3, "and go back to keeping their distance once the magazine is full again (%d)" % _back)
	_check_equal(_kept_distance_dry, 0, "no archer keeps its distance with an empty magazine")
	_check_equal(_tag_wrong, 0, "the has-ammo tag always matches the charges")
	TickDriver.load_step_override = 0
	_finish()


func _watch_new_archers() -> void:
	for pawn: Pawn in get_tree().get_nodes_in_group(Pawn.GROUP):
		if _watched.has(pawn) or not pawn.scene_file_path.contains("archer") or pawn.ai == null:
			continue
		var bolts: AbilityBase = pawn.ability_manager.get_node_or_null(^"RangedAttack")
		if bolts == null or not bolts.uses_charges():
			continue
		_watched[pawn] = true
		# [dry at the last switch, has run dry since it last kept its distance]
		var seen := [false, false]
		pawn.ai.behaviour_manager.behaviour_changed.connect(func(_old: AIBehaviourBase, new: AIBehaviourBase, _reason: String) -> void:
			var dry := bolts.charges_left() == 0
			if pawn.owned_tags.has(Tags.STATUS.HAS_AMMO_RANGED) == dry:
				_tag_wrong += 1
			if dry and not seen[0]:
				_went_dry += 1
			seen[0] = dry
			seen[1] = seen[1] or dry
			if new and new.name == &"Chase" and dry:
				_chased_dry += 1
			if new and new.name == &"KeepDistance":
				if dry:
					_kept_distance_dry += 1
				elif seen[1]:
					_back += 1
				seen[1] = false)
