## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for possession, PlayerController, PlayerCamera and CameraArm, offline.
## Over a network is in net_pawn_selftest. Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/possession_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0
var _possession: PossessionModule
var _controller: PlayerController


## A controller driven by a script, as a test needs.
class ScriptedController extends PlayerController:
	var scripted_move := Vector2.ZERO
	var scripted_jump := false
	var scripted_look := Vector2.ZERO

	func _read_move() -> Vector2:
		return scripted_move

	func _read_sprint() -> bool:
		return false

	func _read_jump_pressed() -> bool:
		var jump := scripted_jump
		scripted_jump = false
		return jump

	func _read_look_extra() -> Vector2:
		var look := scripted_look
		scripted_look = Vector2.ZERO
		return look


func _ready() -> void:
	print("--- Possession and camera self-test ---")
	_possession = GameMode.possession
	_controller = _possession.controller
	await _test_new_scene_camera_works()
	_test_starts_ready()
	await _test_possessing()
	await _test_refusals()
	await _test_letting_go_stops_the_pawn()
	await _test_jump_with_no_pawn()
	await _test_arm_rules()
	await _test_swapping()
	await _test_pawn_removed()
	await _test_driving()
	await _test_camera_arm()
	await _test_streaming_and_ai()
	await _test_scene_camera_left_alone()
	await _test_no_module()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## The bug this guards against: a Camera3D that doesn't ask to be current only becomes current if it's the first one there.
func _test_new_scene_camera_works() -> void:
	var scene_camera := Camera3D.new()
	add_child(scene_camera)
	await get_tree().process_frame
	_check(get_viewport().get_camera_3d() == scene_camera, "a level's camera that doesn't ask to be current still gets used")
	scene_camera.free()


func _test_starts_ready() -> void:
	_check(_possession != null, "the module starts by default")
	_check(_controller is PlayerController, "and creates a controller")
	_check(_controller.pawn == null, "which has no pawn, and survives without one")
	_check(_controller.camera != null and not _controller.camera.is_inside_tree(), "and a camera that stays out of the scene until it's needed")
	_check(_possession.get_pawn_of() == null, "(nobody has anything)")


func _test_possessing() -> void:
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var heard := [0]
	var on_possessed := func(_p: int, _pawn: Pawn) -> void: heard[0] += 1
	_possession.possessed.connect(on_possessed)
	_check(_possession.possess(pawn), "a pawn can be possessed")
	_possession.possessed.disconnect(on_possessed)
	_check(heard[0] == 1, "and it's announced")
	_check(_possession.get_pawn_of() == pawn and _possession.get_peer_of(pawn) == PossessionModule.OFFLINE_PEER, "and it's recorded")
	_check(_controller.pawn == pawn, "and the controller has it")
	_check(pawn.has_player(), "and the pawn knows")
	_check(pawn.get_node_or_null("StreamingSource") != null, "and it has a source now")
	_check(_controller.camera.get_view() == pawn.get_default_view(), "and the camera is on its view")
	_check(_controller.camera.current, "and in use")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.camera.global_position.is_equal_approx(pawn.get_default_view().global_position), "and it's at the view")

	_possession.release()
	_check(_possession.get_pawn_of() == null and _controller.pawn == null, "letting go leaves the controller with no pawn")
	_check(not pawn.has_player(), "and the pawn knows")
	_check(is_instance_valid(_controller), "and the controller is still here")
	pawn.free()


func _test_refusals() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	pawn.possessable = false
	var reason := [""]
	var on_refused := func(_p: int, _pawn: Pawn, why: String) -> void: reason[0] = why
	_possession.refused.connect(on_refused)
	_check(not _possession.possess(pawn), "a pawn with possessable off refuses")
	_check(reason[0] != "", "and says why (%s)" % reason[0])
	_check(_controller.pawn == null, "and nothing changes")
	pawn.possessable = true
	_check(_possession.possess_for(7, pawn), "(another player takes it)")
	reason[0] = ""
	_check(not _possession.possess(pawn), "a pawn someone else has refuses")
	_check(reason[0].contains("another"), "and says so")
	_possession.release_for(7)
	_check(not _possession.possess(null), "nothing at all is refused too")
	_possession.refused.disconnect(on_refused)
	pawn.free()


## Claude 2026-11-07: the bug this guards against: offline, a pawn kept walking on the last input it was given.
func _test_letting_go_stops_the_pawn() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	_possession.possess(pawn)
	pawn.apply_player_input(Vector3.FORWARD, 0.5, 0.2, true, true)
	_possession.release()
	_check(pawn.move_input == Vector3.ZERO and not pawn.wants_sprint and not pawn.wants_jump, "letting go leaves the pawn idle")
	_check(is_equal_approx(pawn.look_yaw, 0.5), "and looking where it was")
	pawn.free()
	await get_tree().process_frame


## Claude 2026-11-07: the bug this guards against: a press with no pawn waited, and jumped the next pawn the controller got.
func _test_jump_with_no_pawn() -> void:
	var controller := ScriptedController.new()
	add_child(controller)
	await get_tree().process_frame
	controller.scripted_jump = true
	await get_tree().process_frame
	var pawn := _make_pawn(Vector3.ZERO)
	controller.take_pawn(pawn)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(not pawn.wants_jump, "a jump pressed with no pawn isn't saved for the next one")
	controller.take_pawn(null)
	controller.free()
	pawn.free()
	await get_tree().process_frame


func _test_arm_rules() -> void:
	# A plain pawn gets one on possession, which goes again afterwards.
	var plain := _make_pawn(Vector3.ZERO)
	_check(plain.get_camera_arm() == null, "a plain pawn has no arm")
	_possession.possess(plain)
	var arm := plain.get_camera_arm()
	_check(arm != null, "possession makes one")
	_check(arm.is_processing(), "and it's active")
	_check(is_equal_approx(arm.get_length(), CameraPreset.new().arm_length), "with the default settings")
	_possession.release()
	await get_tree().process_frame
	_check(plain.get_camera_arm() == null, "and it goes when possession ends")
	plain.free()

	# A preset chooses the settings.
	var preset := CameraPreset.new()
	preset.arm_length = 3.0
	preset.fov = 50.0
	var with_preset: Pawn = load(PAWN_SCENE).instantiate()
	with_preset.camera_preset = preset
	add_child(with_preset)
	_possession.possess(with_preset)
	_check(is_equal_approx(with_preset.get_camera_arm().get_length(), 3.0), "a pawn's preset sets the arm's length")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(_controller.camera.fov, 50.0), "and the field of view")
	_possession.release()
	with_preset.free()

	# A hero keeps its arm.
	var hero: Pawn = load(PAWN_SCENE).instantiate()
	hero.always_has_camera_arm = true
	add_child(hero)
	var hero_arm := hero.get_camera_arm()
	_check(hero_arm != null and not hero_arm.is_processing(), "a hero's arm is there, idle")
	_possession.possess(hero)
	_check(hero.get_camera_arm() == hero_arm and hero_arm.is_processing(), "taking it uses that arm")
	_possession.release()
	await get_tree().process_frame
	_check(hero.get_camera_arm() == hero_arm and not hero_arm.is_processing(), "and it stays, idle again")
	hero.free()

	# An arm placed in the scene is used, and stays.
	var placed: Pawn = load(PAWN_SCENE).instantiate()
	var placed_arm := CameraArm.new()
	placed.get_node("Visual").add_child(placed_arm)
	add_child(placed)
	_possession.possess(placed)
	_check(placed.get_camera_arm() == placed_arm, "an arm placed in the scene is used")
	_possession.release()
	await get_tree().process_frame
	_check(placed.get_camera_arm() == placed_arm, "and it stays")
	placed.free()

	# A view placed by itself, such as at the eyes, with no arm at all.
	var eyes: Pawn = load(PAWN_SCENE).instantiate()
	var eye_view := VirtualCamera.new()
	eye_view.position = Vector3(0.0, 1.6, 0.0)
	eyes.get_node("Visual").add_child(eye_view)
	add_child(eyes)
	_possession.possess(eyes)
	_check(eyes.get_camera_arm() == null, "a pawn with its own view gets no arm")
	_check(_controller.camera.get_view() == eye_view, "and the camera uses that view")
	_possession.release()
	eyes.free()


func _test_swapping() -> void:
	var first := _make_pawn(Vector3(-5.0, 0.1, 0.0))
	var second := _make_pawn(Vector3(5.0, 0.1, 0.0))
	_possession.possess(first)
	_controller.look_yaw = 1.0
	_possession.possess(second)
	_check(_controller.pawn == second and _possession.get_pawn_of() == second, "taking another pawn swaps to it")
	_check(not first.has_player(), "and lets go of the first")
	await get_tree().process_frame
	_check(first.get_camera_arm() == null, "and its arm goes")
	_check(is_equal_approx(_controller.look_yaw, 1.0), "and the player keeps looking the same way")
	_possession.release()
	first.free()
	second.free()


func _test_pawn_removed() -> void:
	var pawn := _make_pawn(Vector3(3.0, 4.0, 5.0))
	_possession.possess(pawn)
	await get_tree().process_frame
	await get_tree().process_frame
	var camera_at := _controller.camera.global_position
	pawn.free()
	_check(_controller.pawn == null, "a possessed pawn being freed leaves the controller with no pawn")
	_check(_possession.get_pawn_of() == null, "and the record is cleared")
	_check(is_instance_valid(_controller.camera), "and the camera isn't freed with it")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.camera.global_position.is_equal_approx(camera_at), "and it holds where it was")


func _test_driving() -> void:
	var scripted := ScriptedController.new()
	add_child(scripted)
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(10)
	# Not through the module, so that this test's controller drives it.
	scripted.take_pawn(pawn)
	scripted.scripted_move = Vector2(0.0, -1.0) # forward
	await _ticks(60)
	_check(pawn.position.z < -3.0 and absf(pawn.position.x) < 0.01, "forward goes along -Z when looking ahead (%.1f m)" % pawn.position.z)

	# Looking a quarter turn to the left: forward is now -X.
	var start := pawn.position
	scripted.look_yaw = PI * 0.5
	await _ticks(60)
	var moved := pawn.position - start
	_check(moved.x < -2.0, "forward follows where the player looks (%.1f m)" % moved.x)
	_check(is_equal_approx(pawn.look_yaw, PI * 0.5), "and the look direction reaches the pawn's input")

	scripted.scripted_move = Vector2.ZERO
	await _ticks(30)
	_check(pawn.grounded, "(it's on the ground)")
	scripted.scripted_jump = true
	await get_tree().process_frame
	await _ticks(3)
	_check(not pawn.grounded, "a jump press reaches the pawn")

	scripted.scripted_look = Vector2(0.5, 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(scripted.look_yaw, wrapf(PI * 0.5 + 0.5, -PI, PI)), "turning changes the look direction")
	scripted.scripted_look = Vector2(0.0, 100.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var limit := deg_to_rad(pawn.get_camera_arm().preset.max_pitch)
	_check(is_equal_approx(scripted.look_pitch, limit), "and looking up stops at the arm's limit (%.2f)" % scripted.look_pitch)

	scripted.take_pawn(null)
	scripted.scripted_look = Vector2(0.25, 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(scripted.look_yaw, wrapf(PI * 0.5 + 0.75, -PI, PI)), "with no pawn, looking still works")
	await _ticks(5)
	_check(true, "and nothing breaks")
	pawn.free()
	floor_body.free()
	scripted.free()


func _test_camera_arm() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var scripted := ScriptedController.new()
	add_child(scripted)
	await _ticks(10)
	scripted.take_pawn(pawn)
	var arm := pawn.get_camera_arm()
	await get_tree().process_frame
	await get_tree().process_frame
	var view := arm.get_view()
	_check(absf(view.global_position.distance_to(arm.global_position) - arm.get_length()) < 0.01, "the view is on the end of the arm")
	var behind := pawn.get_visual().global_position - view.global_position
	_check(behind.z < -3.0, "behind the pawn when looking ahead (%.1f m)" % -behind.z)
	_check(view.global_position.y > arm.global_position.y, "and above it, looking down")
	_check(absf(view.global_basis.z.dot((view.global_position - arm.global_position).normalized()) - 1.0) < 0.01, "and pointing at it")

	var start_length := arm.get_length()
	arm.zoom(2.0)
	_check(is_equal_approx(arm.get_length(), start_length + 2.0 * arm.preset.zoom_step), "zooming changes its length")
	arm.zoom(1000.0)
	_check(is_equal_approx(arm.get_length(), arm.preset.max_length), "up to the limit")
	arm.zoom(-1000.0)
	_check(is_equal_approx(arm.get_length(), arm.preset.min_length), "and down to the other")
	arm.zoom(1000.0)

	# A wall behind the pawn pulls the camera in.
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 40.0, 1.0)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0.0, 0.0, 4.0)
	add_child(wall)
	await _ticks(3)
	await get_tree().process_frame
	await get_tree().process_frame
	var pulled_in := arm.get_current_length()
	_check(pulled_in < 6.0, "a wall behind pulls the camera in (%.1f m, wanted %.1f m)" % [pulled_in, arm.get_length()])
	_check(view.global_position.z < 3.6, "and it stays this side of the wall (%.2f m)" % view.global_position.z)
	var right_after := view.global_position
	wall.free()
	await _ticks(3)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(arm.get_current_length() < arm.get_length() - 1.0, "when the wall's gone it doesn't snap back (%.1f m)" % arm.get_current_length())
	_check(view.global_position.distance_to(right_after) < 3.0, "(so the camera moved smoothly)")
	for i in 3000:
		if is_equal_approx(arm.get_current_length(), arm.get_length()):
			break
		await get_tree().process_frame
	_check(is_equal_approx(arm.get_current_length(), arm.get_length()), "and it eases back out")
	_check(arm.get_current_length() > 10.0, "(the pawn's own body doesn't pull it in)")

	# First person: no length.
	# Another pawn walking between doesn't move the camera, because the arm only minds the ground.
	var passer: Pawn = load(PAWN_SCENE).instantiate()
	passer.position = Vector3(0.0, 0.1, 3.0)
	add_child(passer)
	var before_passer := arm.get_current_length()
	await _ticks(3)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(arm.get_current_length(), before_passer), "a pawn walking between doesn't pull the camera in")
	passer.free()

	var first_person := CameraPreset.new()
	first_person.arm_length = 0.0
	first_person.min_length = 0.0
	first_person.max_length = 0.0
	first_person.mount_height = 1.6
	var fp_pawn: Pawn = load(PAWN_SCENE).instantiate()
	fp_pawn.camera_preset = first_person
	add_child(fp_pawn)
	scripted.take_pawn(fp_pawn)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(fp_pawn.get_default_view().global_position.distance_to(fp_pawn.get_visual().global_position + Vector3(0.0, 1.6, 0.0)) < 0.01, "an arm length of 0 is first person, at the set height")
	scripted.take_pawn(null)
	fp_pawn.free()
	pawn.free()
	floor_body.free()
	scripted.free()


func _test_streaming_and_ai() -> void:
	var terrain := Terrain.new()
	terrain.name = "PossessionTerrain"
	terrain.build_on_start = false
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 4
	add_child(terrain)
	var streamer := ChunkStreamer.new()
	streamer.terrain = terrain
	add_child(streamer)
	var pawn := _make_pawn(Vector3(200.0, 30.0, 200.0))
	await _ticks(3)
	_check(not pawn.is_simulation_active(), "an unpossessed pawn with no ground is off")
	_check(terrain.get_loaded_chunks().is_empty(), "and loads nothing")
	_possession.possess(pawn)
	await _ticks(3)
	_check(pawn.is_simulation_active(), "possessing it turns it on")
	_check(terrain.has_chunk(terrain.chunk_of(pawn.global_position)), "and brings ground under it straight away")
	await _ticks(240)
	_check(pawn.position.y < 25.0 and pawn.grounded, "so it lands (at %.1f m)" % pawn.position.y)
	_possession.release()
	pawn.free()
	streamer.free()
	terrain.free()


func _test_scene_camera_left_alone() -> void:
	var scene_camera := Camera3D.new()
	add_child(scene_camera)
	scene_camera.make_current()
	await get_tree().process_frame
	_check(scene_camera.current, "a scene's own camera stays in use while nobody is possessed")
	var pawn := _make_pawn(Vector3.ZERO)
	_possession.possess(pawn)
	_check(_controller.camera.current, "possession takes over from it")
	_possession.release()
	pawn.free()
	scene_camera.free()


func _test_no_module() -> void:
	var module := GameMode.possession
	GameMode.remove_module(module)
	_check(GameMode.possession == null, "with the module removed, GameMode.possession is null")
	var pawn := _make_pawn(Vector3.ZERO)
	await _ticks(5)
	_check(is_instance_valid(pawn), "and pawns carry on")
	pawn.free()
	GameMode.add_module(PossessionModule.new())
	_check(GameMode.possession != null and GameMode.possession.controller != null, "and it can come back, with a new controller")


# --- Helpers ---


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _make_pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
