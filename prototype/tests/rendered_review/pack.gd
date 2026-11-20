## External review copy only; this is not a production export preset.
extends SceneTree
var packer := PCKPacker.new()
var failed := false

func _initialize() -> void:
	var output := OS.get_environment("PACK_OUTPUT")
	if output.is_empty() or packer.pck_start(output) != OK:
		push_error("Cannot create review PCK: "+output)
		quit(1)
		return
	add_directory("res://")
	add_directory("res://.godot/imported")
	for file in ["res://.godot/global_script_class_cache.cfg", "res://.godot/uid_cache.bin"]:
		if FileAccess.file_exists(file): add_file(file)
	if failed or packer.flush() != OK:
		push_error("Review PCK packing failed")
		quit(1)
		return
	print("PACKED ", output)
	quit()

func add_file(path: String) -> void:
	if packer.add_file(path, path) != OK:
		failed = true
		push_error("Cannot pack "+path)

func add_directory(path: String) -> void:
	for file in DirAccess.get_files_at(path):
		if file.ends_with(".tmp") or file.ends_with(".pyc"):
			continue
		add_file(path.path_join(file))
	for sub in DirAccess.get_directories_at(path):
		if sub in ["node_modules", ".git", ".godot", "animation_preview", "tools", "output", "__pycache__"]:
			continue
		add_directory(path.path_join(sub))
