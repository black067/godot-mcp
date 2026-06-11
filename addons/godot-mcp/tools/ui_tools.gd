@tool
extends RefCounted
class_name UITools

## UI 工具 — 遍历编辑器 Control 树、查找元素、交互

var _plugin: EditorPlugin = null


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin


func get_tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_editor_ui_tree",
			"description": "获取编辑器 UI 控件树的摘要。返回根节点下的控件列表（含类名、名称、文本、可见性），Agent 可据此定位 UI 元素。首次调用建议不传 path 参数获取顶层概览。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "可选：从根控件出发的 / 分隔索引路径，如 '0/2/1' 表示根的第0个子控件的第2个子控件的第1个子控件。不传则返回顶层摘要。"
					},
					"max_depth": {
						"type": "integer",
						"description": "可选：最大遍历深度，默认 3。设为 1 仅返回直接子节点。"
					},
					"include_hidden": {
						"type": "boolean",
						"description": "可选：是否包含不可见控件，默认 false。"
					}
				}
			}
		},
		{
			"name": "find_editor_ui_element",
			"description": "在编辑器 UI 控件树中按条件搜索元素。支持按类名、文本内容、名称等条件过滤。返回匹配的控件路径列表。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"class_name": {
						"type": "string",
						"description": "可选：控件类名过滤，如 'Button'、'LineEdit'、'Label'。"
					},
					"text_contains": {
						"type": "string",
						"description": "可选：按文本内容模糊匹配（不区分大小写）。"
					},
					"name_contains": {
						"type": "string",
						"description": "可选：按节点名称模糊匹配（不区分大小写）。"
					},
					"max_results": {
						"type": "integer",
						"description": "可选：最大返回结果数，默认 20。"
					}
				}
			}
		},
		{
			"name": "click_editor_button",
			"description": "点击编辑器 UI 中的按钮。通过 find_editor_ui_element 获取路径后调用此工具触发点击。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "从根控件出发的 / 分隔索引路径（由 get_editor_ui_tree 或 find_editor_ui_element 返回）。"
					}
				},
				"required": ["path"]
			}
		},
		{
			"name": "set_editor_text",
			"description": "在编辑器 UI 的文本输入框中设置文本。通过 find_editor_ui_element 获取 LineEdit/TextEdit 路径后调用。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "控件的 / 分隔索引路径。"
					},
					"text": {
						"type": "string",
						"description": "要设置的文本内容。"
					}
				},
				"required": ["path", "text"]
			}
		},
		{
			"name": "get_editor_ui_element_info",
			"description": "获取指定 UI 控件的详细信息，包括属性、信号、子控件数量等。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {
						"type": "string",
						"description": "控件的 / 分隔索引路径。"
					}
				},
				"required": ["path"]
			}
		},
	]


# ------------------------------------------------------------------ 统一 dispatch

func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"get_editor_ui_tree":
			return _get_editor_ui_tree(arguments)
		"find_editor_ui_element":
			return _find_editor_ui_element(arguments)
		"click_editor_button":
			return _click_editor_button(arguments)
		"set_editor_text":
			return _set_editor_text(arguments)
		"get_editor_ui_element_info":
			return _get_editor_ui_element_info(arguments)
		_:
			return MCPProtocol.tool_error("Unknown tool: %s" % tool_name)


# ------------------------------------------------------------------ 工具实现

func _get_editor_ui_tree(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var max_depth: int = arguments.get("max_depth", 3)
	var include_hidden: bool = arguments.get("include_hidden", false)

	var root: Control = _plugin.get_editor_interface().get_base_control()
	if not root:
		return MCPProtocol.tool_error("Unable to access editor base control")

	var current: Control = root

	if not path.is_empty():
		var indices := path.split("/", false)
		for idx_str in indices:
			if not idx_str.is_valid_int():
				return MCPProtocol.tool_error("Invalid path index: %s" % idx_str)
			var idx := idx_str.to_int()
			if idx < 0 or idx >= current.get_child_count():
				return MCPProtocol.tool_error("Path index out of bounds: %d (child count: %d)" % [idx, current.get_child_count()])
			var child := current.get_child(idx)
			if not child is Control:
				return MCPProtocol.tool_error("Path element %d is not a Control" % idx)
			current = child

	var tree := _build_control_tree(current, max_depth, include_hidden)
	return MCPProtocol.tool_success_json(tree)


func _build_control_tree(control: Control, depth: int, include_hidden: bool) -> Dictionary:
	var result := _control_to_dict(control)

	if depth > 0:
		var children: Array = []
		for i in control.get_child_count():
			var child := control.get_child(i)
			if not child is Control:
				continue
			if not include_hidden and not child.is_visible_in_tree():
				continue
			children.append(_build_control_tree(child, depth - 1, include_hidden))
		if not children.is_empty():
			result["children"] = children
		result["child_count"] = children.size()

	return result


func _control_to_dict(control: Control) -> Dictionary:
	var info := {
		"class": control.get_class(),
		"name": control.name,
		"visible": control.is_visible_in_tree(),
	}

	# 获取常见属性
	if control.has_method("get_text") or "text" in control:
		info["text"] = str(control.get("text", ""))

	if "tooltip_text" in control:
		var tt := str(control.get("tooltip_text", ""))
		if not tt.is_empty():
			info["tooltip"] = tt

	if "placeholder_text" in control:
		var pt := str(control.get("placeholder_text", ""))
		if not pt.is_empty():
			info["placeholder"] = pt

	if "pressed" in control:
		info["pressed"] = bool(control.get("pressed", false))

	if "selected" in control:
		info["selected"] = bool(control.get("selected", false))

	if "disabled" in control or "editable" in control:
		info["enabled"] = not bool(control.get("disabled", false))

	info["child_count"] = control.get_child_count()

	return info


func _find_editor_ui_element(arguments: Dictionary) -> Dictionary:
	var class_filter: String = arguments.get("class_name", "")
	var text_filter: String = arguments.get("text_contains", "")
	var name_filter: String = arguments.get("name_contains", "")
	var max_results: int = arguments.get("max_results", 20)

	var root: Control = _plugin.get_editor_interface().get_base_control()
	if not root:
		return MCPProtocol.tool_error("Unable to access editor base control")

	var results: Array = []
	_find_recursive(root, [], class_filter, text_filter, name_filter, max_results, results)

	var output: Array = []
	for entry in results:
		output.append({
			"path": entry.path,
			"class": entry.control.get_class(),
			"name": entry.control.name,
			"text": str(entry.control.get("text", "")) if "text" in entry.control else "",
			"visible": entry.control.is_visible_in_tree(),
		})

	return MCPProtocol.tool_success_json(output)


func _find_recursive(control: Control, path_indices: Array, class_filter: String, text_filter: String, name_filter: String, max_results: int, results: Array) -> void:
	if results.size() >= max_results:
		return

	var matches := true

	if not class_filter.is_empty():
		if control.get_class().to_lower() != class_filter.to_lower():
			matches = false

	if matches and not text_filter.is_empty():
		var text := ""
		if "text" in control:
			text = str(control.get("text", ""))
		if text.to_lower().find(text_filter.to_lower()) == -1:
			matches = false

	if matches and not name_filter.is_empty():
		if control.name.to_lower().find(name_filter.to_lower()) == -1:
			matches = false

	if matches:
		results.append({
			"control": control,
			"path": "/".join(path_indices),
		})

	for i in control.get_child_count():
		var child := control.get_child(i)
		if not child is Control:
			continue
		var child_path := path_indices.duplicate()
		child_path.append(str(i))
		_find_recursive(child, child_path, class_filter, text_filter, name_filter, max_results, results)
		if results.size() >= max_results:
			return


func _get_control_by_path(path: String) -> Control:
	var root: Control = _plugin.get_editor_interface().get_base_control()
	if not root:
		return null

	var current: Control = root
	var indices := path.split("/", false)
	for idx_str in indices:
		if not idx_str.is_valid_int():
			return null
		var idx := idx_str.to_int()
		if idx < 0 or idx >= current.get_child_count():
			return null
		current = current.get_child(idx)
	return current


func _click_editor_button(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var control := _get_control_by_path(path)
	if not control:
		return MCPProtocol.tool_error("Control not found at path: %s" % path)

	if control is BaseButton:
		control.pressed.emit()
		return MCPProtocol.tool_success("Clicked button: %s (%s)" % [control.name, control.get_class()])

	# 尝试调用 pressed 信号（某些自定义控件）
	if control.has_signal("pressed"):
		control.pressed.emit()
		return MCPProtocol.tool_success("Emitted 'pressed' signal on: %s (%s)" % [control.name, control.get_class()])

	return MCPProtocol.tool_error("Control at path '%s' is not a button (class: %s)" % [path, control.get_class()])


func _set_editor_text(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var text: String = arguments.get("text", "")

	var control := _get_control_by_path(path)
	if not control:
		return MCPProtocol.tool_error("Control not found at path: %s" % path)

	if control is LineEdit:
		control.text = text
		control.text_changed.emit(text)
		return MCPProtocol.tool_success("Set text on LineEdit '%s'" % control.name)

	if control is TextEdit:
		control.text = text
		return MCPProtocol.tool_success("Set text on TextEdit '%s'" % control.name)

	if "text" in control:
		control.set("text", text)
		return MCPProtocol.tool_success("Set 'text' property on '%s' (%s)" % [control.name, control.get_class()])

	return MCPProtocol.tool_error("Control at path '%s' does not support text input (class: %s)" % [path, control.get_class()])


func _get_editor_ui_element_info(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var control := _get_control_by_path(path)
	if not control:
		return MCPProtocol.tool_error("Control not found at path: %s" % path)

	var info := _control_to_dict(control)

	# 收集属性列表
	var props: Array = []
	for prop in control.get_property_list():
		var prop_name: String = prop.name
		if prop_name.begins_with("_"):
			continue
		var usage: int = prop.usage
		if usage & PROPERTY_USAGE_EDITOR == 0 and usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		props.append({
			"name": prop_name,
			"type": prop.type,
			"value": str(control.get(prop_name)),
		})
	info["properties"] = props

	# 收集信号列表
	var signals: Array = []
	for sig in control.get_signal_list():
		signals.append(sig.name)
	info["signals"] = signals

	# 子控件摘要（仅名称+类名）
	var children: Array = []
	for i in control.get_child_count():
		var child := control.get_child(i)
		if not child is Control:
			continue
		children.append({
			"index": i,
			"name": child.name,
			"class": child.get_class(),
			"visible": child.is_visible_in_tree(),
		})
	info["children"] = children

	return MCPProtocol.tool_success_json(info)
