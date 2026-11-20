## Visible prop for the existing mannequin-only test blade.
## It does not supply hitboxes, damage or new attacks.
extends RefCounted

const SwordScene: PackedScene = preload("res://assets/weapons/quaternius-medieval/sword.glb")
# Model origin is the pommel; the centre of the grip lies about 0.13 m
# above it. This places that centre about 0.055 m along the hand bone.
const GRIP_OFFSET := Vector3(0, -.075, 0)

var skeleton: Skeleton3D
var sockets: Dictionary = {}
var visual: Node3D
var side := "R"


func setup(rig: Skeleton3D) -> bool:
	if not is_instance_valid(rig):
		return false
	skeleton = rig
	for hand in ["L", "R"]:
		if rig.find_bone("hand." + hand) < 0:
			return false
	for hand in ["L", "R"]:
		var socket := BoneAttachment3D.new()
		socket.name = "TrainingSwordSocket_" + hand
		socket.bone_name = "hand." + hand
		rig.add_child(socket)
		sockets[hand] = socket
	visual = SwordScene.instantiate() as Node3D
	visual.name = "TrainingSwordVisual"
	_mark_weapon(visual)
	sockets[side].add_child(visual)
	_apply_grip()
	visual.visible = false
	return true


func set_display(visible: bool, hand: String) -> void:
	if not is_instance_valid(visual):
		return
	var selected := "L" if hand == "L" else "R"
	if side != selected:
		side = selected
		visual.reparent(sockets[side], false)
		_apply_grip()
	visual.visible = visible


func _apply_grip() -> void:
	# The tip is along +Y. Hand-local +Y follows the fingers/forearm
	# for this exact rig; the offset puts the grip inside the closed hand.
	visual.position = GRIP_OFFSET
	visual.rotation = Vector3.ZERO
	visual.scale = Vector3.ONE


func _mark_weapon(node: Node) -> void:
	if node is MeshInstance3D:
		node.set_meta("weapon_visual", true)
		node.layers = 2
	for child in node.get_children():
		_mark_weapon(child)
