## Optional HEADLESS PREFLIGHT of the SAME fixtures/commands as capture.mjs.
## Review copy only: install with make_pack.py --driver game, then run
## GEN_REPLAY_CONFIG=/abs/subject-air.json GEN_REPLAY_TRACE=/abs/trace.json
## godot --headless --path <work>/prototype --fixed-fps 60 res://native_trace.tscn
## Actual scene/controllers/physics, NOT raster/visual/platform acceptance.
extends "res://tests/rendered_review/driver.gd"

var _commands: Array = []
var _cursor := 0
var _take := ""
var _record := false
var _takes: Dictionary = {}
var _config: Dictionary = {}
var _sample_step := 3
var _snapshots := 0

func _ready() -> void:
	var config_path := OS.get_environment("GEN_REPLAY_CONFIG")
	_config = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	_sample_step = int(_config.sample_ticks)
	for entry in _config.timeline:
		if entry.has("setup"):
			_commands.append({"data":entry.setup,"take":"","snapshot":false})
		else:
			for tick in range(0,int(entry.ticks),_sample_step):
				var command: Dictionary = entry.get("command",{}).duplicate(true) if tick == 0 else {}
				command["steps"] = mini(_sample_step,int(entry.ticks)-tick)
				_commands.append({"data":command,"take":entry.take,"snapshot":true})
	await super._ready()
	var expected: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_config.hashes))
	if expected != stamps:
		push_error("Native preflight source hashes differ from the selected review pack")
		get_tree().quit(1)
		return
	call_deferred("_next_command")

func _next_command() -> void:
	if _cursor == _commands.size():
		var output := {"fps":60.0/_sample_step,"outfit":"mixed","seeks":{},
			"source":"HEADLESS actual main.tscn/controllers/60Hz physics; SAME explicit subject timeline; no raster, no pose injection, not visual acceptance",
			"config":_config,"takes":_takes,"snapshots":_snapshots,"physics_ticks_last_take":elapsed_ticks}
		output.merge(stamps)
		var path := OS.get_environment("GEN_REPLAY_TRACE")
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file == null:
			push_error("Cannot write native preflight trace: "+path)
			get_tree().quit(1)
			return
		file.store_string(JSON.stringify(output))
		file.close()
		print("GEN native subject trace: %d sampled physics frames / %d actor snapshots; %s" % [_snapshots/2,_snapshots,path])
		get_tree().quit(0)
		return
	var entry: Dictionary = _commands[_cursor]
	_cursor += 1
	_take = entry.take
	_record = entry.snapshot
	var command: Dictionary = entry.data.duplicate(true)
	command["id"] = _cursor
	command["snapshot"] = _record
	apply(command)

func reply() -> void:
	# Override ONLY the raster/IPC response. The inherited command fixtures,
	# production scene, physics priorities and exact stop-at-N-ticks stay.
	if _record:
		for who in ["player","clone"]:
			var key: String = _take+"/"+String(who)
			if not _takes.has(key): _takes[key] = []
			var character: Node3D = scene.player.character if who == "player" else scene.clone.character
			_takes[key].append(actor_state(character,true))
			_snapshots += 1
	call_deferred("_next_command")
