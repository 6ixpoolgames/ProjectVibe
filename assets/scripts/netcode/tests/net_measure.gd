## Written by Claude (claude-opus-5-5), 2026-11-04: measures multiplayer at set pings, over real connections between
## separate Godot processes. Prints a table; it doesn't pass or fail. Takes several minutes.
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_measure.tscn"
## Add -- --compare to run just the comparison of what other pawns do during a rollback, repeated, with an average per kind.
## Add -- --dilation to compare time dilation with a fixed lead, on bad connections. Each client's conditions apply both ways.
##
## Two clients walk toward the middle of a small arena, changing direction at random every 10 ticks, so they bump often. That's
## far more contact than normal play, and a worst case for prediction. Each row runs with 5 ms of jitter and 1% packet loss.
##
## The columns:
##   own avg/worst   how far your own pawn was from the server on the same tick, as first predicted, before any correction
##   corr/s          how often a client corrected itself
##   corr size       how wrong the prediction was when corrected
##   jump avg/worst  how far the pawn's body moved at each correction, which the visible model hides over about 100 ms
##   jump/s          those added up per second, for one client
##   view            how far a remote pawn was from where it really was at the moment being drawn
##   behind          how many ticks behind the client's own tick remote pawns are drawn
##   missed          inputs that didn't reach the server in time, of about 1200
##   down/up         kilobytes per second received and sent by a client
##   touching        share of ticks the two pawns were within reach of each other
extends Node

const SECONDS := 22
const ROWS := [
	{"label": "0 ms", "latency": 0, "extra": {}},
	{"label": "50 ms", "latency": 25, "extra": {}},
	{"label": "100 ms", "latency": 50, "extra": {}},
	{"label": "200 ms", "latency": 100, "extra": {}},
	{"label": "100 ms, others follow server", "latency": 50, "extra": {"follow": 1}},
	{"label": "200 ms, others follow server", "latency": 100, "extra": {"follow": 1}},
	{"label": "100 ms, others predicted", "latency": 50, "extra": {"predicted": 1}},
	{"label": "200 ms, others predicted", "latency": 100, "extra": {"predicted": 1}},
]

const COMPARE_ROWS := [
	{"label": "100 ms, others stay", "latency": 50, "extra": {}},
	{"label": "100 ms, others follow", "latency": 50, "extra": {"follow": 1}},
	{"label": "200 ms, others stay", "latency": 100, "extra": {}},
	{"label": "200 ms, others follow", "latency": 100, "extra": {"follow": 1}},
]
const COMPARE_REPEATS := 3
const DILATION_SCENARIOS := [
	{"label": "steady 100 ms", "client": {"latency": 50, "jitter": 5}},
	{"label": "wifi", "client": {"preset": "wifi", "conditions-seed": 21}},
	{"label": "mobile", "client": {"preset": "mobile", "conditions-seed": 22}},
	{"label": "worst", "client": {"preset": "worst", "conditions-seed": 23}},
	{"label": "ramp 10 to 200 ms", "client": {"timeline": "0:5,5:5,10:100,14:100,19:5,24:5"}},
]

var _port := NetRun.first_port()
var _totals: Dictionary = {} # label -> {"own": cm, "worst": cm, "jump_per_second": cm, "corrections": per s, "touching": %, "runs": n}


func _ready() -> void:
	print("--- Multiplayer measurement (physics engine: %s) ---" % ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	print("ping | own avg/worst cm | corr/s | corr size cm | jump avg/worst cm | jump/s cm | view cm | behind | missed | down/up KB/s | touching")
	if OS.get_cmdline_user_args().has("--dilation"):
		await _measure_dilation()
	elif OS.get_cmdline_user_args().has("--compare"):
		for i in COMPARE_REPEATS:
			for row: Dictionary in COMPARE_ROWS:
				await _measure(row)
		print("Averages:")
		for label: String in _totals:
			var t: Dictionary = _totals[label]
			var runs: float = t["runs"]
			print("%s | own %.1f cm, worst %.0f cm | %.2f corrections/s | %.0f cm of jump/s | touching %.0f%%" % [label, t["own"] / runs, t["worst"] / runs, t["corrections"] / runs, t["jump_per_second"] / runs, t["touching"] / runs])
	else:
		for row: Dictionary in ROWS:
			await _measure(row)
	print("--- DONE ---")
	get_tree().quit(0)


func _measure(row: Dictionary) -> void:
	_port += 1
	var shared := {"seconds": SECONDS, "latency": row["latency"], "jitter": 5, "loss": 0.01}
	var machines := {"server": {"role": "server"}, "a": {"role": "client", "mode": "seek"}, "b": {"role": "client", "mode": "seek"}}
	for machine_name: String in machines:
		machines[machine_name].merge(shared)
		machines[machine_name].merge(row["extra"])
	machines["server"]["seconds"] = SECONDS + 1
	var results := await NetRun.run(self, "measure_%d" % _port, machines, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	var b: Dictionary = results["b"]
	if server.has("timed_out") or a.has("timed_out") or b.has("timed_out"):
		print("%s | didn't finish" % row["label"])
		return
	var id_a := int(NetRun.own_entity(a)["id"])
	var id_b := int(NetRun.own_entity(b)["id"])
	var own_a := NetRun.prediction_error(a, server, id_a)
	var own_b := NetRun.prediction_error(b, server, id_b)
	var view_a := NetRun.view_error(a, server, id_b)
	var view_b := NetRun.view_error(b, server, id_a)
	var seconds: float = (float(a["measure_end_usec"]) - float(a["measure_start_usec"])) / 1000000.0
	var corrections := _since_start(a, "corrections") + _since_start(b, "corrections")
	var correction_total := _since_start(a, "correction_total") + _since_start(b, "correction_total")
	var jump_total := _since_start(a, "jump_total") + _since_start(b, "jump_total")
	var jump_worst := maxf(float(a["stats"]["jump_worst"]), float(b["stats"]["jump_worst"]))
	var missed := int(NetRun.summary_of(server, id_a).get("missed_inputs", 0)) + int(NetRun.summary_of(server, id_b).get("missed_inputs", 0))
	var band_a := NetRun.bandwidth(a)
	var view_text := "n/a" if view_a["ticks"] == 0 else "%.1f" % (50.0 * (view_a["average"] + view_b["average"]))
	var behind_text := "n/a" if view_a["ticks"] == 0 else "%.1f" % (0.5 * (view_a["behind_ticks"] + view_b["behind_ticks"]))
	var own_average: float = 50.0 * (own_a["average"] + own_b["average"])
	var own_worst: float = 100.0 * maxf(own_a["worst"], own_b["worst"])
	var corrections_per_second := corrections / (2.0 * maxf(seconds, 0.001))
	var jump_per_second := 100.0 * jump_total / (2.0 * maxf(seconds, 0.001))
	var touching := 100.0 * _touching_share(server, id_a, id_b)
	var total: Dictionary = _totals.get(row["label"], {"own": 0.0, "worst": 0.0, "jump_per_second": 0.0, "corrections": 0.0, "touching": 0.0, "runs": 0})
	total["own"] += own_average
	total["worst"] += own_worst
	total["jump_per_second"] += jump_per_second
	total["corrections"] += corrections_per_second
	total["touching"] += touching
	total["runs"] += 1
	_totals[row["label"]] = total
	print("%s | %.1f / %.1f | %.1f | %.1f | %.1f / %.1f | %.0f | %s | %s | %d | %.1f / %.1f | %d%%" % [
		row["label"],
		own_average, own_worst,
		corrections_per_second,
		100.0 * correction_total / maxf(corrections, 1.0),
		100.0 * jump_total / maxf(corrections, 1.0), 100.0 * jump_worst,
		jump_per_second,
		view_text, behind_text, missed,
		band_a["received"] / 1000.0, band_a["sent"] / 1000.0,
		roundi(touching),
	])


## Time dilation on and off, under the same conditions, with the same random seed.
func _measure_dilation() -> void:
	print("conditions, lead | missed inputs | resyncs | margin avg/lowest ticks | speed | own avg/worst cm | corr/s | jump/s cm | late drawing | bursts+spikes")
	for scenario: Dictionary in DILATION_SCENARIOS:
		for dilation_on: bool in [false, true]:
			_port += 1
			var client: Dictionary = {"role": "client", "seconds": SECONDS, "mode": "seek"}
			client.merge(scenario["client"])
			if not dilation_on:
				client["off"] = "time_dilation_enabled"
			var results := await NetRun.run(self, "dilation_%d" % _port, {"server": {"role": "server", "seconds": SECONDS + 1}, "a": client.duplicate(), "b": client.duplicate()}, _port)
			_print_dilation_row("%s, %s" % [scenario["label"], "dilation" if dilation_on else "fixed"], results)


func _print_dilation_row(label: String, results: Dictionary) -> void:
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	var b: Dictionary = results["b"]
	if server.has("timed_out") or a.has("timed_out") or b.has("timed_out"):
		print("%s | didn't finish" % label)
		return
	var id_a := int(NetRun.own_entity(a)["id"])
	var id_b := int(NetRun.own_entity(b)["id"])
	var own_a := NetRun.prediction_error(a, server, id_a)
	var own_b := NetRun.prediction_error(b, server, id_b)
	var seconds: float = (float(a["measure_end_usec"]) - float(a["measure_start_usec"])) / 1000000.0
	var missed := int(a["missed_inputs"]) - int(a["missed_inputs_start"]) + int(b["missed_inputs"]) - int(b["missed_inputs_start"])
	var margin_reports: float = float(a["stats"]["margin_reports"]) + float(b["stats"]["margin_reports"])
	var margin_average: float = (float(a["stats"]["margin_total"]) + float(b["stats"]["margin_total"])) / maxf(margin_reports, 1.0)
	print("%s | %d | %d | %.1f / %d | %.3f-%.3f | %.1f / %.0f | %.1f | %.0f | %d | %d" % [
		label, missed,
		_since_start(a, "resyncs") + _since_start(b, "resyncs"),
		margin_average, mini(int(a["stats"]["margin_lowest"]), int(b["stats"]["margin_lowest"])),
		minf(a["stats"]["speed_lowest"], b["stats"]["speed_lowest"]), maxf(a["stats"]["speed_highest"], b["stats"]["speed_highest"]),
		50.0 * (own_a["average"] + own_b["average"]), 100.0 * maxf(own_a["worst"], own_b["worst"]),
		(_since_start(a, "corrections") + _since_start(b, "corrections")) / (2.0 * maxf(seconds, 0.001)),
		100.0 * (_since_start(a, "jump_total") + _since_start(b, "jump_total")) / (2.0 * maxf(seconds, 0.001)),
		_since_start(a, "interpolation_underruns") + _since_start(b, "interpolation_underruns"),
		int(a["bursts"]) + int(a["spikes"]) + int(b["bursts"]) + int(b["spikes"]),
	])


func _since_start(machine: Dictionary, key: String) -> float:
	return float(machine["stats"][key]) - float(machine.get(key + "_start", 0))


func _touching_share(server: Dictionary, id_a: int, id_b: int) -> float:
	var path_a: Dictionary = server["positions"].get(str(id_a), {})
	var path_b: Dictionary = server["positions"].get(str(id_b), {})
	var touching := 0
	var count := 0
	for tick_text: String in path_a:
		if not path_b.has(tick_text):
			continue
		var a: Array = path_a[tick_text]
		var b: Array = path_b[tick_text]
		count += 1
		if Vector2(a[0] - b[0], a[2] - b[2]).length() < 0.9:
			touching += 1
	return float(touching) / maxi(count, 1)
