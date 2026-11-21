## Ten explicit slots, six real moves. Empty cells are NOT random attacks.
## New kick values come from their baked authoring metadata; old hand values
## remain in tuning.gd and are not silently rebalanced by this selector.
extends RefCounted

const T := preload("res://scripts/tuning.gd")
const MOTIONS: AnimationLibrary = preload("res://assets/heroine/animations/motion_set.tres")
const SLOTS := ["jab", "cross", "hook", "front_kick", "low_kick", "roundhouse", "", "", "", ""]
const KICK_CLIPS := {
	"front_kick": "attack_front_kick",
	"low_kick": "attack_low_kick",
	"roundhouse": "attack_roundhouse",
}
const TITLES := {
	"jab": "Левый джеб", "cross": "Правый кросс", "hook": "Левый хук в корпус",
	"front_kick": "Левый прямой ногой", "low_kick": "Правый лоу-кик",
	"roundhouse": "Сильный правый круговой",
}

static func is_kick(kind: String) -> bool:
	return KICK_CLIPS.has(kind)

static func slot_profile(index: int) -> Dictionary:
	if index < 0 or index >= SLOTS.size() or SLOTS[index].is_empty():
		return {}
	var id: String = SLOTS[index]
	var p := profile("straight" if id in ["jab", "cross"] else id, "R" if id == "cross" else "L")
	p["id"] = id
	p["title"] = TITLES[id]
	return p

static func profile(kind: String = "straight", side: String = "L") -> Dictionary:
	if is_kick(kind):
		var name: String = KICK_CLIPS[kind]
		var clip := MOTIONS.get_animation(name)
		var windup := float(clip.get_meta("windup"))
		var active_end := float(clip.get_meta("active_end"))
		return {"kind": kind, "side": String(clip.get_meta("side")), "clip": name,
			"timing": Vector3(windup, active_end-windup, clip.length-active_end),
			"damage": float(clip.get_meta("damage")), "stamina": float(clip.get_meta("stamina")),
			"reach": float(clip.get_meta("reach")), "cancel_window": float(clip.get_meta("cancel_window")),
			"title": TITLES[kind], "ground_only": true}
	if kind == "hook":
		return {"kind": "hook", "side": "L", "clip": "attack_body_hook", "title": TITLES["hook"],
			"timing": Vector3(T.HOOK_WINDUP,T.HOOK_ACTIVE,T.HOOK_RECOVERY), "damage": T.HOOK_DAMAGE,
			"stamina": T.HOOK_STAMINA, "reach": T.HOOK_REACH, "cancel_window": T.ATTACK_CANCEL_WINDOW,
			"ground_only": false}
	return {"kind": "straight", "side": side, "clip": "attack_right" if side == "R" else "attack_left",
		"title": TITLES["cross" if side == "R" else "jab"],
		"timing": Vector3(T.ATTACK_WINDUP,T.ATTACK_ACTIVE,T.ATTACK_RECOVERY), "damage": T.ATTACK_DAMAGE,
		"stamina": T.ATTACK_STAMINA, "reach": T.ATTACK_REACH, "cancel_window": T.ATTACK_CANCEL_WINDOW,
		"ground_only": false}
