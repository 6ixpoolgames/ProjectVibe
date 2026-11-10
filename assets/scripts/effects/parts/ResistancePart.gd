## Written by Claude (claude-opus-5-5), 2026-11-10: adds to the pawn's resistance to a kind of effect while its effect lasts, such as
## +0.5 against damage.elemental.fire for a fire ward. A held part (EffectPart). Pawn spec 8.11.
##
## Added to the pawn's own resistances (EffectManager.resistances). How resistances count, there: every resistance whose tag is one
## of an effect's tags, or a level above one, adds up, so 0.2 against damage.elemental and 0.3 against damage.elemental.fire make 0.5
## against fire. Negative is a weakness. 1 or more and the pawn ignores those effects entirely.
class_name ResistancePart
extends EffectPart

## The kind of effect, by effect tag (EffectTags), such as &"damage.elemental.fire".
@export var tag: StringName = &""
## How much resistance it adds: 0.25 takes a quarter off. Negative is a weakness.
@export_range(-10.0, 1.0, 0.01, "or_greater", "or_less") var amount := 0.25


func is_held() -> bool:
	return true
