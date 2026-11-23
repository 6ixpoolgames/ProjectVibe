## Written by Claude (claude-opus-5-5), 2026-11-17: replays recorded AI decisions through the C++ AIBatchDecider and counts where it
## agrees with what GDScript decided (scaling spec 6.2, the shadow decider). Test code: ai_batch_decider_selftest and
## ai_batch_decider_compare use it; nothing that ships does.
##
## The input is what AIDecisionRecorder holds: brain descriptions by pawn number, and decision records as plain dictionaries (from a
## live recorder, or from a saved file). Each decision becomes a row for the decider, built only from what GDScript saw: the hard rules
## a behaviour failed (cooldown, action), the availability GDScript asked for, the persistence and scores it had. The decider then
## makes the decision itself: the interrupt rule, the masks, the ranges, the early stop, jitter and ties. Agreeing means it chose the
## same behaviour, kept the running one when GDScript did, and asked is_available() of exactly the same behaviours.
##
## Rows are grouped by tick, one decide() call a tick, as a live batch would be, and the time spent in decide() is measured.
extends RefCounted

## The most mismatches described in a result's "examples".
const EXAMPLES_KEPT := 8


## The brains and decisions in a recorder, as compare() takes them.
static func from_recorder(recorder: AIDecisionRecorder) -> Dictionary:
	var brains := {}
	var decisions: Array = []
	for record in recorder.get_records():
		decisions.append(record.to_dict())
		if not brains.has(record.pawn_number):
			brains[record.pawn_number] = recorder.get_brain(record.pawn_number)
	return {"brains": brains, "decisions": decisions}


## The brains and decisions in a file AIDecisionRecorder.save() wrote. Empty with an "error" if it can't be read.
static func from_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "can't open %s (error %d)" % [path, FileAccess.get_open_error()]}
	var brains := {}
	var decisions: Array = []
	while not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not parsed is Dictionary:
			continue
		if parsed["kind"] == "brain":
			brains[int(parsed["pawn_number"])] = parsed
		elif parsed["kind"] == "decision":
			decisions.append(parsed)
	return {"brains": brains, "decisions": decisions}


## Replays every decision through a new AIBatchDecider. Returns counts: decisions, agreed, chosen_differs, kept_differs,
## asked_differs, asked_unknown (it asked a behaviour GDScript never answered for), brains (distinct brains added), batches
## (decide() calls), decide_usec (time inside them), and examples (the first few mismatches, as text).
static func compare(data: Dictionary) -> Dictionary:
	var decider: Object = ClassDB.instantiate(&"AIBatchDecider")
	var result := {"decisions": 0, "agreed": 0, "chosen_differs": 0, "kept_differs": 0, "asked_differs": 0, "asked_unknown": 0,
		"brains": 0, "batches": 0, "decide_usec": 0, "examples": []}
	if decider == null:
		result["error"] = "the navcore library has no AIBatchDecider"
		return result
	# Pawns with identical brains share one, as live pawns using the same behaviour set will.
	var brain_of_pawn := {} # pawn number -> brain number
	var brain_by_text := {} # the description without the pawn's own fields -> brain number
	var seed_of_pawn := {}
	var slots := [] # brain number -> {behaviour name -> slot}
	for pawn_number: Variant in data["brains"]:
		var description: Dictionary = data["brains"][pawn_number]
		var shared := description.duplicate()
		for own: String in ["pawn", "pawn_number", "kind", "random_seed"]:
			shared.erase(own)
		var text := JSON.stringify(shared, "", true, true)
		if not brain_by_text.has(text):
			var number: int = decider.add_brain(_with_words_now(description))
			brain_by_text[text] = number
			var names := {}
			for slot in decider.get_behaviour_count(number):
				names[String(decider.get_behaviour_name(number, slot))] = slot
			slots.append(names)
		brain_of_pawn[int(pawn_number)] = brain_by_text[text]
		seed_of_pawn[int(pawn_number)] = int(description.get("random_seed", 0))
	result["brains"] = brain_by_text.size()
	var stride: int = decider.get_stride()
	# One batch per tick, in the order they were recorded.
	var by_tick := {}
	var ticks: Array = []
	for decision: Dictionary in data["decisions"]:
		var tick := int(decision["tick"])
		if not by_tick.has(tick):
			by_tick[tick] = []
			ticks.append(tick)
		by_tick[tick].append(decision)
	for tick: int in ticks:
		_compare_batch(decider, by_tick[tick], brain_of_pawn, seed_of_pawn, slots, stride, result)
	return result


## One line for a result.
static func describe(result: Dictionary) -> String:
	if result.has("error"):
		return "error: " + result["error"]
	var decisions: int = result["decisions"]
	return "%d of %d decisions agree (%.3f%%): chosen differs %d, kept differs %d, asked differs %d, asked without an answer %d; %d brain(s), %d batches, %.2f us a decision in decide()" % [
		result["agreed"], decisions, 100.0 * result["agreed"] / maxf(decisions, 1.0), result["chosen_differs"], result["kept_differs"],
		result["asked_differs"], result["asked_unknown"], result["brains"], result["batches"], float(result["decide_usec"]) / maxf(decisions, 1.0)]


static func _compare_batch(decider: Object, decisions: Array, brain_of_pawn: Dictionary, seed_of_pawn: Dictionary, slots: Array,
		stride: int, result: Dictionary) -> void:
	var rows := decisions.size()
	var brain := PackedInt32Array()
	var pawn := PackedInt64Array()
	var random_seed := PackedInt64Array()
	var tick := PackedInt64Array()
	var tag_words := TagRegistry.get_categories().size()
	var owned := PackedInt64Array() # each row's owned tags, tag_words words a row, from the names it recorded
	var modifier := PackedFloat64Array()
	var blocked := PackedInt64Array()
	var has_target := PackedByteArray()
	var normal := PackedByteArray()
	var priority := PackedInt32Array()
	var running := PackedInt32Array()
	var started := PackedInt64Array()
	var cooling := PackedInt64Array()
	var can_press := PackedInt64Array()
	var known := PackedInt64Array()
	var available := PackedInt64Array()
	var persistence := PackedFloat64Array()
	var score := PackedFloat64Array()
	persistence.resize(rows * stride)
	persistence.fill(0.0)
	score.resize(rows * stride)
	score.fill(NAN)
	modifier.resize(rows * stride)
	modifier.fill(0.0)
	var expected_chosen := PackedInt32Array()
	var expected_asked := PackedInt64Array()
	# Claude 2026-11-17 (scaling spec 6.2, step 5b): each decision's AI inputs, for behaviours judged by their conditions, flattened
	# with one stride (the most inputs any decision had; older records without inputs read 0).
	var input_stride := 0
	for d: Dictionary in decisions:
		input_stride = maxi(input_stride, (d.get("inputs", []) as Array).size())
	var inputs := PackedFloat64Array()
	inputs.resize(rows * input_stride)
	inputs.fill(0.0)
	for r in rows:
		var d: Dictionary = decisions[r]
		var pawn_number := int(d["pawn_number"])
		var b: int = brain_of_pawn[pawn_number]
		var names: Dictionary = slots[b]
		var row_inputs: Array = d.get("inputs", [])
		for i in row_inputs.size():
			inputs[r * input_stride + i] = float(row_inputs[i])
		brain.append(b)
		pawn.append(pawn_number)
		random_seed.append(seed_of_pawn[pawn_number])
		tick.append(int(d["tick"]))
		var words := TagQuery.words_of(d.get("owned_tags", []))
		for i in tag_words:
			owned.append(words[i] if i < words.size() else 0)
		has_target.append(1 if d["has_target"] else 0)
		normal.append(1 if d["event_is_normal"] else 0)
		priority.append(int(d["event_priority"]))
		running.append(names.get(d["running_before"], -1))
		started.append(int(d["running_started_tick"]))
		var cooling_mask := 0
		var press_mask := -1 # every action could start, unless GDScript found otherwise
		var known_mask := 0
		var available_mask := 0
		var asked_mask := 0
		var blocked_mask := 0
		for entry: Dictionary in d["behaviours"]:
			var slot: int = names.get(entry["name"], -1)
			if slot < 0:
				continue
			var bit := 1 << slot
			modifier[r * stride + slot] = float(entry.get("modifier", 0.0))
			match entry["rule"]:
				"blocked", "off": # switched off can change during a run, and a recording keeps one brain: passed per decision, as a block
					blocked_mask |= bit
				"cooldown":
					cooling_mask |= bit
				"action":
					press_mask &= ~bit
				"":
					persistence[r * stride + slot] = float(entry["persistence"])
					if entry["score"] != null:
						score[r * stride + slot] = float(entry["score"])
					var answer := int(entry["available"])
					if answer >= 0:
						known_mask |= bit
						asked_mask |= bit
						if answer == 1:
							available_mask |= bit
		blocked.append(blocked_mask)
		cooling.append(cooling_mask)
		can_press.append(press_mask)
		known.append(known_mask)
		available.append(available_mask)
		expected_chosen.append(names.get(d["chosen"], -1))
		expected_asked.append(asked_mask)
	var columns := {"brain": brain, "pawn_number": pawn, "random_seed": random_seed, "tick": tick, "owned": owned, "tag_words": tag_words,
		"modifier": modifier, "blocked": blocked,
		"has_target": has_target, "event_normal": normal, "event_priority": priority, "running": running, "running_started": started,
		"cooling": cooling, "can_press": can_press, "available_known": known, "available": available, "persistence": persistence,
		"score": score, "inputs": inputs, "input_stride": input_stride}
	var started_usec := Time.get_ticks_usec()
	var answer: Dictionary = decider.decide(columns)
	result["decide_usec"] += Time.get_ticks_usec() - started_usec
	result["batches"] += 1
	if answer.is_empty():
		result["error"] = "decide() refused the columns"
		return
	var chosen: PackedInt32Array = answer["chosen"]
	var kept: PackedByteArray = answer["kept"]
	var asked: PackedInt64Array = answer["asked"]
	var unknown: PackedInt64Array = answer["unknown"]
	for r in rows:
		var d: Dictionary = decisions[r]
		result["decisions"] += 1
		var chosen_ok := chosen[r] == expected_chosen[r]
		var kept_ok := (kept[r] == 1) == bool(d["kept_by_interrupt"])
		var asked_ok := asked[r] == expected_asked[r]
		result["chosen_differs"] += 0 if chosen_ok else 1
		result["kept_differs"] += 0 if kept_ok else 1
		result["asked_differs"] += 0 if asked_ok else 1
		result["asked_unknown"] += 1 if unknown[r] != 0 else 0
		if chosen_ok and kept_ok and asked_ok:
			result["agreed"] += 1
		elif result["examples"].size() < EXAMPLES_KEPT:
			var b: int = brain[r]
			result["examples"].append("tick %d pawn %s (%s): GDScript chose %s%s, C++ chose %s%s; asked GDScript %s, C++ %s" % [
				int(d["tick"]), d["pawn"], d["cause"], d["chosen"], " (kept)" if d["kept_by_interrupt"] else "",
				decider.get_behaviour_name(b, chosen[r]) if chosen[r] >= 0 else "nothing", " (kept)" if kept[r] == 1 else "",
				_names(decider, b, expected_asked[r]), _names(decider, b, asked[r])])


static func _names(decider: Object, brain: int, mask: int) -> String:
	var names := PackedStringArray()
	for slot in decider.get_behaviour_count(brain):
		if mask & (1 << slot):
			names.append(String(decider.get_behaviour_name(brain, slot)))
	return "[" + ", ".join(names) + "]"


# A brain description with its tag requirements' words worked out in this run (the names stay; the bits may differ from the run that
# recorded it).
static func _with_words_now(description: Dictionary) -> Dictionary:
	var out := description.duplicate(true)
	out["tag_words"] = TagRegistry.get_categories().size()
	for behaviour: Dictionary in out.get("behaviours", []):
		behaviour["enabled"] = true # each decision says which were switched off (its "off" rules)
		var described: Variant = behaviour.get("tag_requirements")
		if described is Dictionary:
			behaviour["tag_requirements"] = TagQuery.make(described.get("all_of", []), described.get("any_of", []),
				described.get("none_of", [])).describe_words()
	return out
