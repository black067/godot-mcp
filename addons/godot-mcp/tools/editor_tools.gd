@tool
extends RefCounted
class_name EditorTools

## 编辑器工具 — 运行控制、脚本编辑、视口操作

var _plugin: EditorPlugin = null


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin


func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "play_scene",
			"description": "运行当前编辑的场景（相当于按 F6）。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "stop_scene",
			"description": "停止当前正在运行的场景（相当于按 F8）。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "is_playing",
			"description": "检查当前是否正在运行场景。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "open_script",
			"description": "在脚本编辑器中打开指定脚本文件，可跳转到指定行。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"script_path": {
						"type": "string",
						"description": "脚本文件路径，如 'res://player.gd'。"
					},
					"line": {
						"type": "integer",
						"description": "可选：跳转到指定行号。"
					}
				},
				"required": ["script_path"]
			}
		},
		{
			"name": "get_editor_layout",
			"description": "获取当前编辑器布局信息（已打开的 Dock、面板可见性等）。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "get_viewport_screenshot",
			"description": "获取 2D 或 3D 视口的截图信息（返回视口名称和尺寸，暂不直接返回图片数据）。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"viewport_type": {
						"type": "string",
						"enum": ["2d", "3d"],
						"description": "视口类型：'2d' 或 '3d'。"
					}
				},
				"required": ["viewport_type"]
			}
		},
		{
			"name": "get_open_scenes",
			"description": "获取当前在编辑器中打开的所有场景列表。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "inspect_object",
			"description": "在 Inspector 面板中显示指定对象的属性。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"node_path": {
						"type": "string",
						"description": "场景中节点的路径。"
					}
				},
				"required": ["node_path"]
			}
		},
	]


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"play_scene":
			return _play_scene(arguments)
		"stop_scene":
			return _stop_scene(arguments)
		"is_playing":
			return _is_playing(arguments)
		"open_script":
			return _open_script(arguments)
		"get_editor_layout":
			return _get_editor_layout(arguments)
		"get_viewport_screenshot":
			return _get_viewport_screenshot(arguments)
		"get_open_scenes":
			return _get_open_scenes(arguments)
		"inspect_object":
			return _inspect_object(arguments)
		_:
			return MCPProtocol.tool_error("Unknown tool: %s" % tool_name)


# ------------------------------------------------------------------ 工具实现

func _play_scene(_arguments: Dictionary) -> Dictionary:
	var editor_iface := _plugin.get_editor_interface()
	if editor_iface.is_playing_scene():
		return MCPProtocol.tool_error("Scene is already playing")

	editor_iface.play_current_scene()
	return MCPProtocol.tool_success("Playing current scene")


func _stop_scene(_arguments: Dictionary) -> Dictionary:
	var editor_iface := _plugin.get_editor_interface()
	if not editor_iface.is_playing_scene():
		return MCPProtocol.tool_error("No scene is currently playing")

	editor_iface.stop_playing_scene()
	return MCPProtocol.tool_success("Stopped playing scene")


func _is_playing(_arguments: Dictionary) -> Dictionary:
	var playing := _plugin.get_editor_interface().is_playing_scene()
	return MCPProtocol.tool_success_json({"playing": playing})


func _open_script(arguments: Dictionary) -> Dictionary:
	var script_path: String = arguments.get("script_path", "")
	var line: int = arguments.get("line", -1)

	if script_path.is_empty():
		return MCPProtocol.tool_error("Missing required parameter: script_path")

	if not ResourceLoader.exists(script_path):
		return MCPProtocol.tool_error("Script not found: %s" % script_path)

	var script: Resource = load(script_path)
	if not script is Script:
		return MCPProtocol.tool_error("File is not a script: %s" % script_path)

	# 使用 EditorInterface.edit_script
	var editor_iface := _plugin.get_editor_interface()
	if line > 0:
		editor_iface.edit_script(script, line, 0)
	else:
		editor_iface.edit_script(script)

	return MCPProtocol.tool_success("Opened script: %s%s" % [script_path, " at line %d" % line if line > 0 else ""])


func _get_editor_layout(_arguments: Dictionary) -> Dictionary:
	var base := _plugin.get_editor_interface().get_base_control()
	if not base:
		return MCPProtocol.tool_error("Unable to access editor base control")

	# 查找主要的 Dock/面板
	var panels: Dictionary = {}
	var dock_names := [
		"Scene", "Inspector", "FileSystem", "Node",
		"Import", "History", "Audio",
	]

	for dock_name in dock_names:
		var dock := base.find_child(dock_name, true, false)
		if dock:
			panels[dock_name] = {
				"visible": dock.is_visible_in_tree(),
				"class": dock.get_class(),
			}

	var layout := {
		"panels": panels,
		"editor_scale": EditorInterface.get_editor_scale(),
	}

	return MCPProtocol.tool_success_json(layout)


func _get_viewport_screenshot(arguments: Dictionary) -> Dictionary:
	var vp_type: String = arguments.get("viewport_type", "2d")
	var editor_iface := _plugin.get_editor_interface()
	var viewport: SubViewport = null

	if vp_type == "2d":
		viewport = editor_iface.get_editor_viewport_2d()
	elif vp_type == "3d":
		viewport = editor_iface.get_editor_viewport_3d()
	else:
		return MCPProtocol.tool_error("Invalid viewport_type: %s. Must be '2d' or '3d'." % vp_type)

	if not viewport:
		return MCPProtocol.tool_error("Unable to access %s viewport" % vp_type)

	# 返回视口基本信息。完整的图片数据传输需要额外处理
	var info := {
		"viewport_type": vp_type,
		"size": {"x": viewport.size.x, "y": viewport.size.y},
		"has_texture": viewport.get_texture() != null,
	}

	# 如果能获取到 texture，提取图像信息
	var texture := viewport.get_texture()
	if texture:
		var image := texture.get_image()
		if image:
			info["image"] = {
				"width": image.get_width(),
				"height": image.get_height(),
				"format": image.get_format(),
			}

	return MCPProtocol.tool_success_json(info)


func _get_open_scenes(_arguments: Dictionary) -> Dictionary:
	var scenes := _plugin.get_editor_interface().get_open_scenes()
	var result: Array = []
	for scene_path in scenes:
		result.append(str(scene_path))

	return MCPProtocol.tool_success_json({
		"open_scenes": result,
		"current_scene": str(_plugin.get_editor_interface().get_edited_scene_root().scene_file_path) if _plugin.get_editor_interface().get_edited_scene_root() else "",
	})


func _inspect_object(arguments: Dictionary) -> Dictionary:
	var node_path: String = arguments.get("node_path", "")
	var editor_iface := _plugin.get_editor_interface()
	var scene_root := editor_iface.get_edited_scene_root()

	var node: Node = null
	if node_path == "." or node_path.is_empty():
		var selection := editor_iface.get_selection()
		var selected := selection.get_selected_nodes()
		if selected.size() > 0:
			node = selected[0]
		else:
			node = scene_root
	else:
		node = scene_root.get_node_or_null(node_path) if scene_root else null

	if not node:
		return MCPProtocol.tool_error("Node not found: %s" % node_path)

	editor_iface.inspect_object(node)
	return MCPProtocol.tool_success("Inspecting: %s (%s)" % [node.name, node.get_class()])
