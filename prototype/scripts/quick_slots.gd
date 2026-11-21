## Original vector move pictograms. No borrowed icon textures or fake items.
## 1..9,0 SELECT a move; LMB performs it. V mode is visibly contextual: the
## existing 1..4 limb selector / cutting controls retain their old meaning.
extends Control

const Moves := preload("res://scripts/move_catalog.gd")
const SLOT_SIZE := 44.0
const SLOT_STEP := 50.0
const SLOT_COUNT := 10
const WIDTH := SLOT_STEP * 9 + SLOT_SIZE
const INK := Color(.84,.91,.91)
const ACCENT := Color(1.0,.62,.30)
var player: Node
var _signature := ""
var _profiles: Array[Dictionary] = []

func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH,72)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in SLOT_COUNT:
		_profiles.append(Moves.slot_profile(i))

func _process(_delta: float) -> void:
	if not is_instance_valid(player): return
	var signature := "%d/%s/%d/%s/%s/%d/%d/%s/%s" % [player.selected_attack_slot,player.training_blade,
		player.training_limb,player._action,player._attack_kind,int(player.stamina),
		int(player._action_time*60) if player._action == "attack" else 0,player.is_on_floor(),player._kick_planting]
	if signature != _signature:
		_signature = signature
		queue_redraw()

func _draw() -> void:
	if not is_instance_valid(player) or _profiles.size() != SLOT_COUNT: return
	var blade: bool = player.training_blade
	var selected: int = player.training_limb if blade else player.selected_attack_slot
	var caption := "КЛИНОК · 1–4 ЧАСТЬ · ЛКМ СРЕЗ · V ВЫХОД" if blade else (
		("%s · ЛКМ" % _profiles[selected].title) if not _profiles[selected].is_empty() else "ПУСТО · ВЫБЕРИТЕ 1–6")
	if not blade and player._kick_planting: caption = "ОПОРА · ТОРМОЖЕНИЕ ПЕРЕД УДАРОМ"
	var font := ThemeDB.fallback_font
	var caption_width := font.get_string_size(caption,HORIZONTAL_ALIGNMENT_LEFT,-1,11).x
	draw_style_box(_caption_style(),Rect2(Vector2((WIDTH-caption_width)*.5-7,0),Vector2(caption_width+14,19)))
	draw_string(font,Vector2((WIDTH-caption_width)*.5,13),caption,HORIZONTAL_ALIGNMENT_LEFT,-1,11,INK)
	for i in SLOT_COUNT:
		var pos := Vector2(i*SLOT_STEP,24)
		var active := i == selected
		var empty := i >= 4 if blade else _profiles[i].is_empty()
		var affordable: bool = true if empty or blade else player.stamina >= float(_profiles[i].stamina)
		var ink := ACCENT if active else INK
		if empty: ink = Color(.39,.48,.50,.65)
		elif not affordable: ink = Color(.76,.42,.30,.9)
		draw_rect(Rect2(pos,Vector2(SLOT_SIZE,SLOT_SIZE)),Color(.10,.17,.18,.93) if active else Color(.025,.045,.052,.84))
		draw_rect(Rect2(pos,Vector2(SLOT_SIZE,SLOT_SIZE)),ACCENT if active else Color(.41,.53,.54,.66),false,1.5 if active else 1.0)
		draw_string(font,pos+Vector2(4,12),str((i+1)%10),HORIZONTAL_ALIGNMENT_LEFT,-1,11,ink)
		if empty:
			draw_line(pos+Vector2(18,25),pos+Vector2(29,25),ink,1.2,true)
		elif blade:
			_limb_icon(pos,i,ink)
		else:
			_icon(pos,String(Moves.SLOTS[i]),ink)
		if active:
			draw_line(pos+Vector2(6,41),pos+Vector2(38,41),ink,2,true)
		var performing: bool = player._action == "attack" and not empty and (
			i == player._attack_blade_limb if blade else
			_profiles[i].kind == player._attack_kind and _profiles[i].side == player._attack_side)
		if performing:
			# A new number may choose the NEXT action during this swing.
			# Keep its selection border, but progress belongs to the move
			# actually captured at click, not the subsequently selected slot.
			var timing: Vector3 = player._attack_timing()
			var total := timing.x+timing.y+timing.z
			draw_rect(Rect2(pos+Vector2(0,42),Vector2(SLOT_SIZE*clampf(player._action_time/total,0,1),2)),INK)

func _caption_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(.025,.045,.052,.88)
	return box

func _line(pos: Vector2, points: Array, ink: Color, width: float = 2.0) -> void:
	var line := PackedVector2Array()
	for point in points: line.append(pos+point)
	draw_polyline(line,ink,width,true)

func _icon(pos: Vector2, id: String, ink: Color) -> void:
	if id in ["jab","cross","hook"]:
		# A closed glove, left/right cuffs and a short directional arrow.
		var p := PackedVector2Array([Vector2(14,23),Vector2(18,19),Vector2(29,19),Vector2(32,23),Vector2(30,30),Vector2(20,31),Vector2(15,28)])
		for i in p.size(): p[i] += pos
		draw_colored_polygon(p,Color(ink, .20))
		draw_polyline(p+PackedVector2Array([p[0]]),ink,1.7,true)
		_line(pos,[Vector2(15,27),Vector2(11,30),Vector2(14,34),Vector2(20,30)],ink,1.5)
		if id == "hook":
			draw_arc(pos+Vector2(25,25),13,-2.7,-.1,16,ink,1.5,true)
			_line(pos,[Vector2(33,10),Vector2(38,14),Vector2(32,16)],ink,1.4)
		else:
			var sign_x := -1.0 if id == "jab" else 1.0
			var tip := pos+Vector2(24+sign_x*14,14)
			draw_line(pos+Vector2(24-sign_x*3,14),tip,ink,1.6,true)
			draw_line(tip,tip+Vector2(-sign_x*4,-3),ink,1.6,true)
			draw_line(tip,tip+Vector2(-sign_x*4,3),ink,1.6,true)
		return
	# Distinct whole-body silhouettes: straight sole / low shin / high arc.
	draw_circle(pos+Vector2(17,13),3,ink)
	_line(pos,[Vector2(17,17),Vector2(19,25),Vector2(15,36),Vector2(20,36)],ink)
	_line(pos,[Vector2(18,19),Vector2(12,22),Vector2(10,19)],ink,1.5)
	_line(pos,[Vector2(18,19),Vector2(24,18),Vector2(24,14)],ink,1.5)
	if id == "front_kick":
		_line(pos,[Vector2(19,25),Vector2(27,23),Vector2(35,23),Vector2(35,19)],ink,2.2)
		_line(pos,[Vector2(26,30),Vector2(36,30),Vector2(33,28)],ink,1.2)
	elif id == "low_kick":
		_line(pos,[Vector2(19,25),Vector2(27,29),Vector2(35,31),Vector2(38,30)],ink,2.2)
		draw_arc(pos+Vector2(26,27),11,-.1,1.5,12,ink,1.3,true)
	else:
		_line(pos,[Vector2(19,25),Vector2(27,21),Vector2(35,18),Vector2(38,19)],ink,2.4)
		draw_arc(pos+Vector2(25,25),14,-1.3,.8,14,ink,1.7,true)
		_line(pos,[Vector2(39,13),Vector2(39,19),Vector2(34,16)],ink,1.6)

func _limb_icon(pos: Vector2, index: int, ink: Color) -> void:
	draw_circle(pos+Vector2(24,14),3,ink)
	_line(pos,[Vector2(24,18),Vector2(24,27)],ink,1.5)
	_line(pos,[Vector2(15,28),Vector2(18,21),Vector2(30,21),Vector2(33,28)],ink,1.2)
	_line(pos,[Vector2(18,36),Vector2(24,27),Vector2(30,36)],ink,1.2)
	var limbs := [[Vector2(18,21),Vector2(15,28)],[Vector2(30,21),Vector2(33,28)],
		[Vector2(24,27),Vector2(18,36)],[Vector2(24,27),Vector2(30,36)]]
	_line(pos,limbs[index],ACCENT,3)
