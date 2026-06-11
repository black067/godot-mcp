@tool
extends RefCounted
class_name ProjectTools

## 项目工具 — 文件系统操作、场景保存、项目设置

var _plugin: EditorPlugin = null


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin


func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_file_system",
			"description": "获取文件系统面板中当前选中的文件和目录。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "list_directory",
			"description": "列出指定项目目录下的文件和子目录。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "目录路径，如 'res://' 或 'res://scenes/'。默认 'res://'。"
					},
					"recursive": {
						"type": "boolean",
						"description": "是否递归列出，默认 false。"
					},
					"filter": {
						"type": "string",
						"description": "可选：文件扩展名过滤，如 '.gd,.tscn'。"
					}
				}
			}
		},
		{
			"name": "save_scene",
			"description": "保存当前编辑的场景。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "save_all_scenes",
			"description": "保存所有已打开的场景。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "get_project_info",
			"description": "获取当前项目的基本信息（名称、路径、主场景、Godot 版本等）。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "read_file",
			"description": "读取项目中的文件内容（文本文件）。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "文件路径，如 'res://player.gd'。"
					},
					"start_line": {
						"type": "integer",
						"description": "可选：起始行号（1-based）。"
					},
					"end_line": {
						"type": "integer",
						"description": "可选：结束行号（1-based）。"
					}
				},
				"required": ["path"]
			}
		},
		{
			"name": "write_file",
			"description": "写入文本内容到项目文件。使用 EditorUndoRedoManager 记录以便撤销。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "文件路径，如 'res://new_script.gd'。"
					},
					"content": {
						"type": "string",
						"description": "要写入的文件内容。"
					}
				},
				"required": ["path", "content"]
			}
		},
		{
			"name": "create_script",
			"description": "在项目中创建新的脚本文件。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "脚本文件路径，如 'res://characters/enemy.gd'。"
					},
					"extends_class": {
						"type": "string",
						"description": "父类名，默认 'Node'。支持 'Node2D'、'Node3D'、'Control'、'Resource' 等。"
					},
					"template": {
						"type": "string",
						"description": "可选：自定义脚本模板内容。如果不提供则使用 Godot 默认模板。"
					}
				},
				"required": ["path"]
			}
		},
	]


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"get_file_system":
			return _get_file_system(arguments)
		"list_directory":
			return _list_directory(arguments)
		"save_scene":
			return _save_scene(arguments)
		"save_all_scenes":
			return _save_all_scenes(arguments)
		"get_project_info":
			return _get_project_info(arguments)
		"read_file":
			return _read_file(arguments)
		"write_file":
			return _write_file(arguments)
		"create_script":
			return _create_script(arguments)
		_:
			return MCPProtocol.tool_error("Unknown tool: %s" % tool_name)


# ------------------------------------------------------------------ 工具实现

func _get_file_system(_arguments: Dictionary) -> Dictionary:
	var editor_iface := _plugin.get_editor_interface()
	var selected_paths := editor_iface.get_selected_paths()

	var result: Array = []
	for path in selected_paths:
		result.append(str(path))

	return MCPProtocol.tool_success_json({
		"selected_paths": result,
	})


func _list_directory(arguments: Dictionary) -> Dictionary:
	var dir_path: String = arguments.get("path", "res://")
	var recursive: bool = arguments.get("recursive", false)
	var filter_str: String = arguments.get("filter", "")

	if not dir_path.begins_with("res://") and not dir_path.begins_with("user://"):
		return MCPProtocol.tool_error("Path must start with 'res://' or 'user://'")

	var dir := DirAccess.open(dir_path)
	if not dir:
		return MCPProtocol.tool_error("Cannot open directory: %s" % dir_path)

	var filters: Array = []
	if not filter_str.is_empty():
		filters = filter_str.split(",", false)

	var files: Array = []
	var dirs: Array = []
	_list_recursive(dir, dir_path, filters, recursive, 0, files, dirs)

	return MCPProtocol.tool_success_json({
		"path": dir_path,
		"directories": dirs,
		"files": files,
	})


func _list_recursive(dir: DirAccess, base_path: String, filters: Array, recursive: bool, depth: int, files: Array, dirs: Array) -> void:
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name == "." or file_name == ".":
			file_name = dir.get_next()
			continue

		var full_path := base_path + file_name
		if dir.current_is_dir():
			dirs.append(full_path + "/")
			if recursive:
				var sub_dir := DirAccess.open(full_path)
				if sub_dir:
					_list_recursive(sub_dir, full_path + "/", filters, recursive, depth + 1, files, dirs)
		else:
			var include := true
			if not filters.is_empty():
				include = false
				for f in filters:
					if file_name.ends_with(f.strip_edges()):
						include = true
						break
			if include:
				files.append(full_path)

		file_name = dir.get_next()
	dir.list_dir_end()


func _save_scene(_arguments: Dictionary) -> Dictionary:
	var err := _plugin.get_editor_interface().save_scene()
	if err != OK:
		return MCPProtocol.tool_error("Failed to save scene (error: %d)" % err)

	var root := _plugin.get_editor_interface().get_edited_scene_root()
	var scene_name := root.scene_file_path if root else "untitled"
	return MCPProtocol.tool_success("Scene saved: %s" % scene_name)


func _save_all_scenes(_arguments: Dictionary) -> Dictionary:
	_plugin.get_editor_interface().save_all_scenes()
	return MCPProtocol.tool_success("All scenes saved")


func _get_project_info(_arguments: Dictionary) -> Dictionary:
	var info := {
		"project_name": ProjectSettings.get_setting("application/config/name", "Unknown"),
		"project_path": ProjectSettings.globalize_path("res://"),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"godot_version": Engine.get_version_info(),
		"rendering_method": ProjectSettings.get_setting("rendering/renderer/rendering_method", "Unknown"),
	}

	return MCPProtocol.tool_success_json(info)


func _read_file(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var start_line: int = arguments.get("start_line", 0)
	var end_line: int = arguments.get("end_line", -1)

	if path.is_empty():
		return MCPProtocol.tool_error("Missing required parameter: path")

	if not FileAccess.file_exists(path):
		return MCPProtocol.tool_error("File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return MCPProtocol.tool_error("Cannot open file: %s" % path)

	var content: String
	if start_line > 0:
		var lines: Array[String] = []
		var line_num := 0
		while not file.eof_reached():
			line_num += 1
			var line := file.get_line()
			if line_num >= start_line and (end_line < 0 or line_num <= end_line):
				lines.append(line)
		content = "\n".join(lines)
	else:
		content = file.get_as_text()

	return MCPProtocol.tool_success_json({
		"path": path,
		"content": content,
	})


func _write_file(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var content: String = arguments.get("content", "")

	if path.is_empty():
		return MCPProtocol.tool_error("Missing required parameter: path")

	# 读取旧内容以支持撤销
	var old_content := ""
	if FileAccess.file_exists(path):
		var old_file := FileAccess.open(path, FileAccess.READ)
		if old_file:
			old_content = old_file.get_as_text()

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return MCPProtocol.tool_error("Cannot write to file: %s" % path)

	file.store_string(content)

	# 通知文件系统刷新
	_plugin.get_editor_interface().get_resource_filesystem().scan()

	return MCPProtocol.tool_success("File written: %s (%d bytes)" % [path, content.to_utf8_buffer().size()])


func _create_script(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var extends_class: String = arguments.get("extends_class", "Node")
	var template: String = arguments.get("template", "")

	if path.is_empty():
		return MCPProtocol.tool_error("Missing required parameter: path")

	# 确保目录存在
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return MCPProtocol.tool_error("Cannot create directory: %s" % dir_path)

	if FileAccess.file_exists(path):
		return MCPProtocol.tool_error("File already exists: %s" % path)

	if template.is_empty():
		# 使用 Godot 内置模板或简单默认模板
		template = """extends %s


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
""" % extends_class

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return MCPProtocol.tool_error("Cannot create file: %s" % path)

	file.store_string(template)

	# 通知文件系统刷新
	_plugin.get_editor_interface().get_resource_filesystem().scan()

	# 如果是 .gd 文件，加载并打开
	if path.ends_with(".gd"):
		var script: Script = load(path)
		_plugin.get_editor_interface().edit_script(script)

	return MCPProtocol.tool_success("Script created: %s" % path)
