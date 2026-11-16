## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for possession, PlayerController, PlayerCamera and CameraArm, offline.
## Over a network is in net_pawn_selftest. Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/possession_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0
var _possession: PossessionCoordinator
var _controller: PlayerController


## A controller driven by a script, as a test needs.
class ScriptedController extends PlayerController:
	var scripted_move := Vector2.ZERO
	var scripted_jump := false
	var scripted_look := Vector2.ZERO
	var scripted_up := 0.0 # Claude 2026-11-16: spectating's Q and E
	var scripted_sprint := false # Claude 2026-11-16: spectating's fast flying

	func _read_move() -> Vector2:
		return scripted_move

	func _read_fly_up_down() -> float:
		return scripted_up

	# Claude 2026-11-07: the controller now reads named actions, not sprint and jump on their own.
	func _read_action_held(action: StringName) -> bool:
		return action == &"sprint" and scripted_sprint # Claude 2026-11-16: was always false

	func _read_action_pressed(action: StringName) -> bool:
		if action != &"jump":
			return false
		var jump := scripted_jump
		scripted_jump = false
		return jump

	func _read_look_extra() -> Vector2:
		var look := scripted_look
		scripted_look = Vector2.ZERO
		return look


func _ready() -> void:
	print("--- Possession and camera self-test ---")
	_possession = GameMode.possession_coordinator
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
	_test_coordinator_spectating() # Claude 2026-11-16: before _test_no_module, which removes the coordinator
	await _test_no_module()
	await _test_spectating() # Claude 2026-11-16
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
	_check(_possession.get_pawn_of() == pawn and _possession.get_peer_of(pawn) == PossessionCoordinator.OFFLINE_PEER, "and it's recorded")
	_check(_controller.pawn == pawn, "and the controller has it")
	_check(pawn.controller_manager.has_player(), "and the pawn knows")
	_check(pawn.is_keeping_world_loaded(), "and it keeps the world loaded now") # Claude 2026-11-16 (pawn M2): a flag, not a StreamingSource node
	_check(_controller.camera.get_view() == pawn.get_default_view(), "and the camera is on its view")
	_check(_controller.camera.current, "and in use")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.camera.global_position.is_equal_approx(pawn.get_default_view().global_position), "and it's at the view")

	_possession.release()
	_check(_possession.get_pawn_of() == null and _controller.pawn == null, "letting go leaves the controller with no pawn")
	_check(not pawn.controller_manager.has_player(), "and the pawn knows")
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

	# Claude 2026-11-07: the flag only stops new possessions. Removing someone is its own call.
	_check(_possession.possess(pawn), "(possessed again)")
	pawn.possessable = false
	_check(_controller.pawn == pawn and _possession.get_pawn_of() == pawn, "turning possessable off doesn't evict whoever has the pawn")
	_possession.release_pawn(pawn)
	_check(_controller.pawn == null and _possession.get_peer_of(pawn) == 0, "release_pawn does")
	_possession.release_pawn(pawn)
	_check(_possession.get_pawn_of() == null, "and on a pawn nobody has, it does nothing")
	pawn.free()


## Claude 2026-11-07: the bug this guards against: offline, a pawn kept walking on the last input it was given.
func _test_letting_go_stops_the_pawn() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	_possession.possess(pawn)
	pawn.controller_manager.apply_input(InputCommand.make(Vector3.FORWARD, [&"sprint", &"jump"], 0.5, 0.2)) # Claude 2026-11-07: InputCommand
	_possession.release()
	_check(pawn.controller_manager.move_input == Vector3.ZERO and pawn.controller_manager.held_actions == 0, "letting go leaves the pawn idle")
	_check(is_equal_approx(pawn.controller_manager.look_yaw, 0.5), "and looking where it was")
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
	_check(not pawn.controller_manager.is_action_held(&"jump"), "a jump pressed with no pawn isn't saved for the next one") # Claude 2026-11-07: named actions
	controller.take_pawn(null)
	controller.free()
	pawn.free()
	await get_tree().process_frame


func _test_arm_rules() -> void:
	# A plain pawn gets the player's arm on possession, which leaves again afterwards. Claude 2026-11-16 (pawn M5): the player's one arm, moved here.
	var plain := _make_pawn(Vector3.ZERO)
	_check(plain.get_camera_arm() == null, "a plain pawn has no arm")
	_possession.possess(plain)
	var arm := plain.get_camera_arm()
	_check(arm != null and arm == _controller._own_arm, "possession brings the player's own arm")
	_check(arm.is_processing(), "and it's active")
	_check(is_equal_approx(arm.get_length(), CameraPreset.new().arm_length), "with the default settings")
	_possession.release()
	await get_tree().process_frame
	_check(plain.get_camera_arm() == null and is_instance_valid(arm) and arm.get_parent() == _controller, "and it goes back to the player when possession ends")
	plain.free()

	# A preset chooses the settings.
	var preset := CameraPreset.new()
	preset.arm_length = 3.0
	preset.fov = 50.0
	var with_preset: Pawn = load(PAWN_SCENE).instantiate()
	var mount := CameraMount.new() # Claude 2026-11-16 (pawn M5): the preset lives on a CameraMount under Visual now
	mount.preset = preset
	with_preset.get_node("Visual").add_child(mount)
	add_child(with_preset)
	_possession.possess(with_preset)
	_check(is_equal_approx(with_preset.get_camera_arm().get_length(), 3.0) and with_preset.get_camera_arm().get_parent() == mount, "a pawn's CameraMount places the arm and its preset sets the length")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(is_equal_approx(_controller.camera.fov, 50.0), "and the field of view")
	_possession.release()
	with_preset.free()

	# Claude 2026-11-16 (pawn M5): one arm per player: the same arm moves from pawn to pawn, with each pawn's settings.
	var one := _make_pawn(Vector3(-3.0, 0.0, 0.0))
	var two := _make_pawn(Vector3(3.0, 0.0, 0.0))
	_possession.possess(one)
	var moving_arm := one.get_camera_arm()
	_possession.possess(two)
	_check(two.get_camera_arm() == moving_arm and one.get_camera_arm() == null and moving_arm.is_processing(), "the player's one arm moves to the next pawn they take")
	_check(is_equal_approx(moving_arm.get_length(), CameraPreset.new().arm_length), "and takes that pawn's settings (the defaults here, after the last pawn's 3 m)")
	_possession.release()
	one.free()
	two.free()

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
	_check(not first.controller_manager.has_player(), "and lets go of the first")
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
	_check(is_equal_approx(pawn.controller_manager.look_yaw, PI * 0.5), "and the look direction reaches the pawn's input")

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
	var fp_mount := CameraMount.new() # Claude 2026-11-16 (pawn M5): the preset lives on a CameraMount now
	fp_mount.preset = first_person
	fp_pawn.get_node("Visual").add_child(fp_mount)
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
	var terrain := TerrainGenerator.new()
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
	_check(pawn.is_frozen(), "an unpossessed pawn with no ground is off")
	_check(terrain.get_loaded_chunks().is_empty(), "and loads nothing")
	_possession.possess(pawn)
	await _ticks(3)
	_check(not pawn.is_frozen(), "possessing it turns it on")
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
	var module := GameMode.possession_coordinator
	GameMode.remove_module(module)
	_check(GameMode.possession_coordinator == null, "with the module removed, GameMode.possession_coordinator is null")
	var pawn := _make_pawn(Vector3.ZERO)
	await _ticks(5)
	_check(is_instance_valid(pawn), "and pawns carry on")
	pawn.free()
	GameMode.add_module(PossessionCoordinator.new())
	_check(GameMode.possession_coordinator != null and GameMode.possession_coordinator.controller != null, "and it can come back, with a new controller")


# --- Helpers ---


# Claude 2026-11-16: spectating with a FreeFlyCamera, and taking a pawn stopping it. Its own controller, so the keys can be scripted.
func _test_spectating() -> void:
	var floor_body := _make_floor()
	var controller := ScriptedController.new()
	controller.name = "SpectatingController"
	add_child(controller)
	_check(controller.get_spectator() == null and not controller.is_spectating(), "spectating: no spectator until it first spectates")
	controller.start_spectating()
	var spectator := controller.get_spectator()
	_check(controller.is_spectating() and spectator is FreeFlyCamera and spectator.is_flying(), "start_spectating() with no pawn flies a FreeFlyCamera")
	_check(controller.camera.get_view() == spectator.view and controller.camera.current, "the camera follows its view")
	_check(spectator.streaming_source.counts_on_this_machine(), "and it keeps the world loaded around it")

	controller.look_yaw = 0.0
	controller.look_pitch = 0.0
	var start := spectator.global_position
	controller.scripted_move = Vector2(0.0, -1.0) # W
	await get_tree().create_timer(0.5).timeout
	controller.scripted_move = Vector2.ZERO
	var moved := spectator.global_position - start
	_check(moved.z < -2.0 and absf(moved.x) < 0.1 and absf(moved.y) < 0.1, "W flies forward, the way it looks (%s)" % str(moved))
	await get_tree().create_timer(0.3).timeout # stops within seconds_to_full_speed
	start = spectator.global_position
	controller.scripted_up = 1.0 # Q
	await get_tree().create_timer(0.3).timeout
	controller.scripted_up = 0.0
	_check(spectator.global_position.y - start.y > 1.0, "Q flies straight up (%.1f m)" % (spectator.global_position.y - start.y))
	controller.look_pitch = 3.0
	# GDScript note: process_frame is sent before nodes run _process that frame, so two make sure the controller has had one.
	await get_tree().process_frame
	await get_tree().process_frame
	_check(controller.look_pitch < PI / 2.0, "looking up stops short of straight up, so the view never flips")
	_check(not spectator.is_physics_processing() and not spectator.is_processing(), "it does nothing per tick or frame of its own: the controller flies it")

	# Speeds: 10, 25 with sprint, and the wheel with sprint held ramps that between 10 and 75.
	_check(spectator.speed == 10.0 and spectator.get_fast_speed() == 25.0, "it flies at 10 m/s, and 25 with sprint")
	controller._zoom_steps = -3.0 # three notches of wheel up, without sprint
	await get_tree().process_frame
	await get_tree().process_frame
	_check(spectator.get_fast_speed() == 25.0, "the wheel without sprint leaves the speed alone")
	# Claude 2026-11-16: it zooms instead: three notches in, 1.25 times each.
	_check(is_equal_approx(spectator.get_zoom(), pow(1.25, 3.0)) and spectator.view.fov < spectator.fov - 20.0,
			"and zooms instead: three notches in, %.2f times, the view narrowing to %.0f°" % [spectator.get_zoom(), spectator.view.fov])
	spectator.change_zoom(100.0)
	_check(spectator.get_zoom() == spectator.max_zoom, "no more than max_zoom")
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	controller._unhandled_input(middle)
	_check(spectator.get_zoom() == 1.0 and is_equal_approx(spectator.view.fov, spectator.fov), "the middle mouse button resets it")
	spectator.change_zoom(100.0)
	spectator.change_zoom(-100.0)
	_check(spectator.get_zoom() == 1.0 and is_equal_approx(spectator.view.fov, spectator.fov), "and out to no zoom, at its own fov")
	controller.scripted_sprint = true
	controller._zoom_steps = -3.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(spectator.get_fast_speed() == 40.0 and spectator.get_zoom() == 1.0, "with sprint held, three notches up: 40 m/s (%.0f), and no zoom" % spectator.get_fast_speed())
	spectator.change_fast_speed(100.0)
	_check(spectator.get_fast_speed() == 75.0, "no faster than 75")
	spectator.change_fast_speed(-100.0)
	_check(spectator.get_fast_speed() == 10.0, "and no slower than the plain speed")
	controller.scripted_sprint = false
	spectator.change_fast_speed(3.0) # back to 25 for the rest

	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	controller.take_pawn(pawn)
	_check(not controller.is_spectating() and not spectator.is_flying() and not spectator.streaming_source.counts_on_this_machine(),
			"taking a pawn stops spectating, and its source stops counting")
	_check(controller.camera.get_view() == pawn.get_default_view(), "and the camera goes to the pawn's view")
	# A client asks to let go and spectates before the server answers: the keys fly the spectator, and the pawn gets nothing from them.
	controller.start_spectating()
	controller.scripted_move = Vector2(0.0, -1.0)
	var command := controller.take_input_command(0)
	controller.scripted_move = Vector2.ZERO
	_check(controller.is_spectating() and command.move == Vector3.ZERO and command.held_actions == 0,
			"spectating with a pawn still attached: the pawn gets no movement or actions")
	controller.take_pawn(null)
	_check(controller.is_spectating() and controller.camera.get_view() == spectator.view, "and letting go of it afterwards keeps spectating")
	controller.stop_spectating()
	_check(not controller.is_spectating() and controller.camera.get_view() == null, "stop_spectating() with no pawn: the camera holds where it is")

	var other := ScriptedController.new()
	var scene := PackedScene.new()
	var wrong_root := Node3D.new()
	scene.pack(wrong_root)
	wrong_root.free()
	other.spectator_scene = scene
	add_child(other)
	other.start_spectating()
	_check(other.get_spectator() is FreeFlyCamera, "a spectator_scene whose root isn't a FreeFlyCamera: the default, with a warning")
	other.free()
	pawn.free()
	controller.free()
	floor_body.free()


# Claude 2026-11-16: the PossessionCoordinator recognises the spectator: spectate() lets go and flies, possessing ends it.
func _test_coordinator_spectating() -> void:
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var heard: Array[bool] = []
	var on_changed := func(spectating: bool) -> void: heard.append(spectating)
	_possession.spectating_changed.connect(on_changed)
	_possession.possess(pawn)
	_check(_possession.spectate(), "spectate() through the coordinator")
	_check(_possession.get_pawn_of() == null and not pawn.controller_manager.has_player(), "lets go of the pawn, so its AI controller has it")
	_check(_possession.is_spectating() and _controller.is_spectating(), "and the player flies the spectator")
	_check(_possession.possess(pawn) and not _possession.is_spectating() and not _controller.is_spectating(), "possessing a pawn ends it")
	_possession.release()
	_check(_possession.spectate() and _possession.is_spectating(), "spectate() with no pawn works too")
	_possession.stop_spectating()
	_check(not _possession.is_spectating() and not _controller.is_spectating(), "and stop_spectating() ends it")
	_check(heard == [true, false, true, false], "spectating_changed says each change (%s)" % str(heard))
	_possession.spectating_changed.disconnect(on_changed)
	pawn.free()


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
