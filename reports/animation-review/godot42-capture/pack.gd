extends SceneTree
var packer := PCKPacker.new()
func _initialize() -> void:
	var output := OS.get_environment("PACK_OUTPUT")
	if packer.pck_start(output) != OK:
		quit(1)
		return
	add_directory("res://")
	add_directory("res://.godot/imported")
	packer.add_file("res://.godot/global_script_class_cache.cfg", "res://.godot/global_script_class_cache.cfg")
	packer.add_file("res://.godot/uid_cache.bin", "res://.godot/uid_cache.bin")
	packer.flush()
	print("PACKED ", output)
	quit()
func add_directory(path: String) -> void:
	for file in DirAccess.get_files_at(path):
		if file.ends_with(".tmp"):
			continue
		packer.add_file(path.path_join(file), path.path_join(file))
	for sub in DirAccess.get_directories_at(path):
		if sub in ["node_modules", ".git", "animation_preview", "tools"]:
			continue
		if path == "res://.godot" and sub != "imported":
			continue
		add_directory(path.path_join(sub))
