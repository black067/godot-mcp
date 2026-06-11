@tool
extends RefCounted
class_name SceneTools

## 场景工具 — 场景树遍历、节点选择、属性读写

var _plugin: EditorPlugin = null


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin


func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_scene_tree",
			"description": "获取当前编辑场景的完整节点树。返回节点路径、类名、类型及父子关系。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"max_depth": {
						"type": "integer",
						"description": "可选：最大遍历深度，默认 99（全部）。"
					}
				}
			}
		},
		{
			"name": "get_selected_nodes",
			"description": "获取当前在场景面板中选中的节点列表。返回节点路径、类名。",
			"inputSchema": {
				"type": "object",
				"properties": {}
			}
		},
		{
			"name": "select_node",
			"description": "在场景面板中选中指定节点。可通过节点路径或相对于场景根的路径指定。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"node_path": {
						"type": "string",
						"description": "节点在场景中的路径，如 '.' 表示场景根，'Player/Camera' 表示场景根下的 Player/Camera。"
					}
				},
				"required": ["node_path"]
			}
		},
		{
			"name": "get_node_properties",
			"description": "获取指定节点的所有可编辑属性及其当前值。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"node_path": {
						"type": "string",
						"description": "节点在场景中的路径，默认 '.'（当前选中节点）。"
					}
				}
			}
		},
		{
			"name": "set_node_property",
			"description": "修改场景中指定节点的属性值。修改可通过 EditorUndoRedoManager 撤销。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"node_path": {
						"type": "string",
						"description": "节点在场景中的路径。"
					},
					"property": {
						"type": "string",
						"description": "属性名称，如 'position'、'text'、'modulate'。"
					},
					"value": {
						"description": "新的属性值。类型需与属性类型匹配。字符串、数字、布尔值直接传递；Variant 类型用 JSON 对象表示。"
					}
				},
				"required": ["node_path", "property", "value"]
			}
		},
		{
			"name": "call_node_method",
			"description": "调用场景中指定节点的方法。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"node_path": {
						"type": "string",
						"description": "节点在场景中的路径。"
					},
					"method": {
						"type": "string",
						"description": "要调用的方法名。"
					},
					"args": {
						"type": "array",
						"description": "可选：方法参数数组。"
					}
				},
				"required": ["node_path", "method"]
			}
		},
	]


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"get_scene_tree":
			return _get_scene_tree(arguments)
		"get_selected_nodes":
			return _get_selected_nodes(arguments)
		"select_node":
			return _select_node(arguments)
		"get_node_properties":
			return _get_node_properties(arguments)
		"set_node_property":
			return _set_node_property(arguments)
		"call_node_method":
			return _call_node_method(arguments)
		_:
			return MCPProtocol.tool_error("Unknown tool: %s" % tool_name)


# ------------------------------------------------------------------ 辅助

func _resolve_node(node_path: String) -> Node:
	var editor_iface := _plugin.get_editor_interface()
	var scene_root := editor_iface.get_edited_scene_root()
	if not scene_root:
		return null

	if node_path == "." or node_path.is_empty():
		var selection := editor_iface.get_selection()
		var selected := selection.get_selected_nodes()
		if selected.size() > 0:
			return selected[0]
		return scene_root

	if node_path.begins_with("./"):
		var selection := editor_iface.get_selection()
		var selected := selection.get_selected_nodes()
		if selected.size() > 0:
			return selected[0].get_node(node_path.trim_prefix("./"))
		return scene_root.get_node(node_path.trim_prefix("./"))

	return scene_root.get_node_or_null(node_path)


func _node_to_dict(node: Node, depth: int, max_depth: int) -> Dictionary:
	var info := {
		"name": node.name,
		"class": node.get_class(),
		"type": str(typeof(node)),
	}

	# 脚本信息
	var script: Script = node.get_script()
	if script:
		info["script"] = script.resource_path

	# 场景文件来源
	if node.scene_file_path and not node.scene_file_path.is_empty():
		info["scene_file"] = node.scene_file_path

	# 子节点
	if depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(_node_to_dict(child, depth + 1, max_depth))
		info["child_count"] = children.size()
		if not children.is_empty():
			info["children"] = children
	else:
		info["child_count"] = node.get_child_count()

	return info


# ------------------------------------------------------------------ 工具实现

func _get_scene_tree(arguments: Dictionary) -> Dictionary:
	var max_depth: int = arguments.get("max_depth", 99)
	var scene_root := _plugin.get_editor_interface().get_edited_scene_root()
	if not scene_root:
		return MCPProtocol.tool_error("No scene is currently open")

	var tree := _node_to_dict(scene_root, 0, max_depth)
	return MCPProtocol.tool_success_json(tree)


func _get_selected_nodes(_arguments: Dictionary) -> Dictionary:
	var selection := _plugin.get_editor_interface().get_selection()
	var selected := selection.get_selected_nodes()

	var result: Array = []
	for node in selected:
		result.append({
			"name": node.name,
			"class": node.get_class(),
			"path": str(_plugin.get_editor_interface().get_edited_scene_root().get_path_to(node)) if _plugin.get_editor_interface().get_edited_scene_root() else node.name,
		})

	return MCPProtocol.tool_success_json(result)


func _select_node(arguments: Dictionary) -> Dictionary:
	var node_path: String = arguments.get("node_path", "")
	var node := _resolve_node(node_path)
	if not node:
		return MCPProtocol.tool_error("Node not found: %s" % node_path)

	var editor_iface := _plugin.get_editor_interface()
	editor_iface.edit_node(node)

	var selection := editor_iface.get_selection()
	selection.clear()
	selection.add_node(node)

	return MCPProtocol.tool_success("Selected node: %s (%s)" % [node.name, node.get_class()])


func _get_node_properties(arguments: Dictionary) -> Dictionary:
	var node_path: String = arguments.get("node_path", ".")
	var node := _resolve_node(node_path)
	if not node:
		return MCPProtocol.tool_error("Node not found: %s" % node_path)

	var props: Array = []
	for prop in node.get_property_list():
		var prop_name: String = prop.name
		if prop_name.begins_with("_"):
			continue
		var usage: int = prop.usage
		if usage & PROPERTY_USAGE_EDITOR == 0 and usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue

		var val = node.get(prop_name)
		props.append({
			"name": prop_name,
			"type": prop.type,
			"hint": prop.hint,
			"hint_string": prop.hint_string,
			"value": JSON.stringify(val, "", false) if typeof(val) in [TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT] else val,
		})

	return MCPProtocol.tool_success_json({
		"node": node.name,
		"class": node.get_class(),
		"properties": props,
	})


func _set_node_property(arguments: Dictionary) -> Dictionary:
	var node_path: String = arguments.get("node_path", "")
	var prop_name: String = arguments.get("property", "")
	var value = arguments.get("value", null)

	if node_path.is_empty() or prop_name.is_empty():
		return MCPProtocol.tool_error("Missing required parameters: node_path and property")

	var node := _resolve_node(node_path)
	if not node:
		return MCPProtocol.tool_error("Node not found: %s" % node_path)

	# 获取旧值用于撤销
	var old_value = node.get(prop_name)

	# 类型转换
	value = _coerce_value(value, typeof(old_value))

	# 使用 UndoRedo 记录操作
	var undo_redo := _plugin.get_editor_interface().get_editor_undo_redo()
	undo_redo.create_action("Set %s.%s" % [node.name, prop_name])
	undo_redo.add_do_property(node, prop_name, value)
	undo_redo.add_undo_property(node, prop_name, old_value)
	undo_redo.commit_action()

	return MCPProtocol.tool_success("Set '%s.%s' = %s" % [node.name, prop_name, value])


func _coerce_value(value, target_type: int):
	# 尝试将 JSON 值转换为目标类型
	match target_type:
		TYPE_INT:
			if value is String and value.is_valid_int():
				return value.to_int()
			if value is float:
				return int(value)
			return value
		TYPE_FLOAT:
			if value is String and value.is_valid_float():
				return value.to_float()
			if value is int:
				return float(value)
			return value
		TYPE_BOOL:
			if value is String:
				return value.to_lower() in ["true", "1", "yes"]
			return bool(value)
		TYPE_STRING:
			return str(value)
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
			return value
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
			return value
		TYPE_COLOR:
			if value is String and value.begins_with("#"):
				return Color(value)
			if value is Dictionary:
				return Color(
					float(value.get("r", 0)),
					float(value.get("g", 0)),
					float(value.get("b", 0)),
					float(value.get("a", 1)),
				)
			return value
		_:
			return value


func _call_node_method(arguments: Dictionary) -> Dictionary:
	var node_path: String = arguments.get("node_path", "")
	var method: String = arguments.get("method", "")
	var args: Array = arguments.get("args", [])

	var node := _resolve_node(node_path)
	if not node:
		return MCPProtocol.tool_error("Node not found: %s" % node_path)

	if not node.has_method(method):
		return MCPProtocol.tool_error("Node '%s' does not have method '%s'" % [node.name, method])

	var result = node.callv(method, args)
	return MCPProtocol.tool_success("Called '%s.%s()' → %s" % [node.name, method, result])
