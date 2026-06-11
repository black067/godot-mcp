@tool
extends RefCounted

## godot-mcp MCP 协议处理器
##
## 职责：
##   - 管理多个 TCP 客户端连接
##   - Content-Length 帧协议解析
##   - JSON-RPC 2.0 路由分发
##   - 工具实现（Perception / Action / Escape Hatch / Scene 四层共 12 个工具）
##
## 由 plugin.gd 驱动：plugin 接受连接后调用 accept()，并通过 poll() 定时处理数据。

const PROTOCOL_VERSION := "2025-03-26"

# 客户端列表：{ peer: StreamPeerTCP, buffer: String }
var _clients: Array = []

# 延迟响应：{ request_id: { peer: StreamPeerTCP, id: Variant } }
var _pending_requests: Dictionary = {}
var _next_pending_key: int = 0

# 当前正在处理的客户端 peer（用于延迟响应）
var _current_peer: StreamPeerTCP = null


# ============================================================================
# Public API（供 plugin.gd 调用）
# ============================================================================

func accept(peer: StreamPeerTCP) -> void:
	_clients.append({"peer": peer, "buffer": ""})


func poll() -> void:
	var disconnected: Array[int] = []

	for i in range(_clients.size()):
		var client: Dictionary = _clients[i]
		var peer: StreamPeerTCP = client.peer

		# 检测断线
		if not is_instance_valid(peer) or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			disconnected.append(i)
			continue

		# 读数据
		var avail := peer.get_available_bytes()
		if avail > 0:
			client.buffer += peer.get_string(avail)
			_process_buffer(client)

	# 清理断线客户端（倒序删除）
	disconnected.reverse()
	for idx in disconnected:
		_clients.remove_at(idx)


func teardown() -> void:
	_cancel_pending_requests()
	for client in _clients:
		var peer: StreamPeerTCP = client.peer
		if is_instance_valid(peer):
			peer.disconnect_from_host()
	_clients.clear()


# ============================================================================
# Content-Length 帧解析
# ============================================================================

func _process_buffer(client: Dictionary) -> void:
	while true:
		var buf: String = client.buffer
		var header_end := buf.find("\r\n\r\n")
		if header_end == -1:
			break

		var header := buf.substr(0, header_end)
		var content_length := _parse_content_length(header)
		if content_length < 0:
			client.buffer = ""  # 无效帧头，丢弃整个缓冲区
			break

		var body_start := header_end + 4
		var total_needed := body_start + content_length
		if buf.length() < total_needed:
			break  # 数据不完整，等待下个 poll

		var body := buf.substr(body_start, content_length)
		client.buffer = buf.substr(total_needed)

		# 解析 JSON 并分发
		var json := JSON.new()
		var err := json.parse(body)
		if err == OK:
			_current_peer = client.peer
			var response := _dispatch(json.data)
			_current_peer = null
			if not response.is_empty():
				_send(client.peer, JSON.stringify(response))
		else:
			_send_error(client.peer, null, -32700, "Parse error: %s" % json.get_error_message())


func _parse_content_length(header: String) -> int:
	for line in header.split("\r\n"):
		if line.begins_with("Content-Length:"):
			return int(line.substr(15).strip_edges())
	return -1


# ============================================================================
# JSON-RPC 2.0 路由
# ============================================================================

func _dispatch(msg: Dictionary) -> Dictionary:
	var method: String = msg.get("method", "")
	var id = msg.get("id", null)
	var params: Dictionary = msg.get("params", {})

	if id != null:
		return _handle_request(id, method, params)

	# 通知 — 静默接受（notifications/initialized 等）
	return {}


func _handle_request(id, method: String, params: Dictionary) -> Dictionary:
	match method:
		"initialize":
			return _mk_resp(id, {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {"tools": {"listChanged": true}},
				"serverInfo": {"name": "godot-mcp", "version": "0.1.0"},
			})

		"tools/list":
			return _mk_resp(id, {"tools": _list_tools()})

		"tools/call":
			return _call_tool(id, params)

		"ping":
			return _mk_resp(id, {})

		_:
			return _mk_err(id, -32601, "Method not found: " + method)


# ============================================================================
# 工具实现
# ============================================================================

func _list_tools() -> Array:
	return [
		# ---- Perception 层 ----
		{
			"name": "get_scene_tree",
			"description": "获取当前编辑场景的完整节点树结构，包含每个节点的名称、类型和子节点列表。需要 Godot 编辑器已打开一个场景。",
			"inputSchema": {"type": "object", "properties": {}},
		},
		{
			"name": "get_editor_ui_tree",
			"description": "获取 Godot 编辑器 UI 控件树结构（菜单栏、面板、按钮、Inspector 等所有 Control 节点）。" +
				"返回每个控件的名称、类型、可见性、文本、全局位置和尺寸。用于 Agent 感知编辑器界面布局。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"max_depth": {"type": "integer", "description": "最大遍历深度，默认 8", "default": 8},
					"include_hidden": {"type": "boolean", "description": "是否包含不可见控件，默认 false", "default": false},
				},
			},
		},
		{
			"name": "find_editor_ui_element",
			"description": "在编辑器 UI 控件树中按名称/类名/文本模糊搜索 Control 节点。" +
				"返回匹配控件的名称、类型、文本、位置、尺寸和从根到该控件的路径。可用于定位按钮、输入框等。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"pattern": {"type": "string", "description": "搜索模式，对控件的 name / class / text 做大小写不敏感的包含匹配"},
					"filter_class": {"type": "string", "description": "可选：按类名过滤（如 Button、LineEdit、Panel）"},
				},
				"required": ["pattern"],
			},
		},
		{
			"name": "pick_ui_element",
			"description": "启用 UI 拾取模式：调用后在 Godot 编辑器中点击任意控件，自动将其 path 复制到剪贴板并返回。" +
				"用于快速获取控件的精确定位路径，无需手动搜索。点击后自动退出拾取模式。",
			"inputSchema": {"type": "object", "properties": {}},
		},
		{
			"name": "screenshot",
			"description": "截取当前编辑器视口（2D/3D）的屏幕截图，返回 Base64 编码的 PNG 图像。" +
				"用于 Agent '看到'编辑器当前状态以验证操作结果。",
			"inputSchema": {"type": "object", "properties": {}},
		},

		# ---- Action 层 ----
		{
			"name": "click_element",
			"description": "点击编辑器 UI 中的指定控件。通过 find_editor_ui_element 获取控件路径后调用。" +
				"支持左键/右键/中键和双击。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"ref": {"type": "string", "description": "控件路径（来自 find_editor_ui_element 返回的 path 字段）"},
					"button": {"type": "string", "description": "左键 left / 右键 right / 中键 middle，默认 left", "default": "left"},
					"dblclick": {"type": "boolean", "description": "是否双击，默认 false", "default": false},
				},
				"required": ["ref"],
			},
		},
		{
			"name": "type_text",
			"description": "向指定控件输入文本（逐字符模拟键盘输入）。可先通过 ref 参数聚焦目标控件再输入。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"text": {"type": "string", "description": "要输入的文本"},
					"ref": {"type": "string", "description": "可选，目标控件路径（先聚焦该控件）"},
				},
				"required": ["text"],
			},
		},
		{
			"name": "press_key",
			"description": "模拟按键操作，支持组合键（如 Control+S、Shift+Tab 等）。" +
				"单个按键也可直接使用（如 Enter、Escape、F5 等）。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"key": {"type": "string", "description": "按键名，支持组合键如 Control+S、Shift+Tab，或单键如 Enter、Escape、F5"},
				},
				"required": ["key"],
			},
		},
		{
			"name": "hover_element",
			"description": "将鼠标悬停在指定编辑器 UI 控件上，用于触发 tooltip、hover 预览等。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"ref": {"type": "string", "description": "控件路径（来自 find_editor_ui_element 返回的 path 字段）"},
				},
				"required": ["ref"],
			},
		},
		{
			"name": "drag_element",
			"description": "将一个编辑器 UI 控件拖拽到另一个控件上。用于调整面板位置、Dock 重新排列等。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"from_ref": {"type": "string", "description": "拖拽起点控件路径"},
					"to_ref": {"type": "string", "description": "拖拽终点控件路径"},
				},
				"required": ["from_ref", "to_ref"],
			},
		},

		# ---- Escape Hatch ----
		{
			"name": "run_gdscript",
			"description": "在 Godot 编辑器上下文中执行任意 GDScript 表达式，作为「逃逸舱」覆盖所有未封装的复杂操作。" +
				"使用 Expression 引擎，仅支持表达式（不能有 if/for/函数定义）。" +
				"可访问 EditorInterface、ProjectSettings 等编辑器单例。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"code": {"type": "string", "description": "GDScript 表达式，如 EditorInterface.get_edited_scene_root().name"},
				},
				"required": ["code"],
			},
		},

		# ---- 场景操作 ----
		{
			"name": "select_node",
			"description": "在当前编辑的场景中按名称或路径选中节点。选中后可在 Inspector 中编辑其属性。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"name": {"type": "string", "description": "按节点名称查找（模糊匹配）"},
					"path": {"type": "string", "description": "按节点路径查找（相对于场景根，如 Node2D/Player）"},
				},
			},
		},
		{
			"name": "get_node_properties",
			"description": "读取场景节点的属性列表（名称、类型、当前值）。不指定 path 时使用当前选中节点。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "节点路径（相对于场景根），留空则使用当前选中节点"},
				},
			},
		},
		{
			"name": "set_node_property",
			"description": "修改场景节点的属性值，自动尝试类型转换（int/float/bool/Vector2/Vector3/Color）。" +
				"修改后自动标记场景为未保存。",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "节点路径（相对于场景根），留空则使用当前选中节点"},
					"property": {"type": "string", "description": "属性名称"},
					"value": {"description": "新属性值（字符串或对应类型值均可）"},
				},
				"required": ["property", "value"],
			},
		},
	]


func _call_tool(id, params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	var arguments: Dictionary = params.get("arguments", {})
	match name:
		# Perception
		"get_scene_tree":
			return _tool_get_scene_tree(id)
		"get_editor_ui_tree":
			return _tool_get_editor_ui_tree(id, arguments)
		"find_editor_ui_element":
			return _tool_find_editor_ui_element(id, arguments)
		"pick_ui_element":
			return _tool_pick_ui_element(id, arguments)
		"screenshot":
			return _tool_screenshot(id, arguments)

		# Actions
		"click_element":
			return _tool_click_element(id, arguments)
		"type_text":
			return _tool_type_text(id, arguments)
		"press_key":
			return _tool_press_key(id, arguments)
		"hover_element":
			return _tool_hover_element(id, arguments)
		"drag_element":
			return _tool_drag_element(id, arguments)

		# Escape Hatch
		"run_gdscript":
			return _tool_run_gdscript(id, arguments)

		# Scene operations
		"select_node":
			return _tool_select_node(id, arguments)
		"get_node_properties":
			return _tool_get_node_properties(id, arguments)
		"set_node_property":
			return _tool_set_node_property(id, arguments)

		_:
			return _mk_err(id, -32602, "Unknown tool: " + name)


func _tool_get_scene_tree(id) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return _tool_err(id, "当前没有打开的场景。请在 Godot 中打开一个场景后重试。")

	var tree := _serialize_node(root)
	return _tool_ok(id, JSON.stringify(tree, "  "))


func _serialize_node(node: Node) -> Dictionary:
	var children: Array = []
	for child in node.get_children():
		children.append(_serialize_node(child))

	return {
		"name": node.name,
		"type": node.get_class(),
		"children": children,
	}


# ---- 编辑器 UI 树工具 ----

func _tool_get_editor_ui_tree(id, args: Dictionary) -> Dictionary:
	var base := EditorInterface.get_base_control()
	if not base:
		return _tool_err(id, "无法获取编辑器 UI 根节点。")

	var max_depth := args.get("max_depth", 8)
	var include_hidden := args.get("include_hidden", false)

	var tree := _serialize_control(base, 0, max_depth, include_hidden)
	return _tool_ok(id, JSON.stringify(tree, "  "))


func _serialize_control(ctrl: Control, depth: int, max_depth: int, include_hidden: bool) -> Dictionary:
	var result := {
		"name": ctrl.name,
		"class": ctrl.get_class(),
	}

	# 可见性
	if not ctrl.visible:
		result["visible"] = false

	# 文本内容（Label / Button / LineEdit 等）
	var text := _get_control_text(ctrl)
	if not text.is_empty():
		result["text"] = text

	# 全局位置和尺寸
	var rect := ctrl.get_global_rect()
	result["rect"] = {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}

	# 递归子控件
	if depth < max_depth:
		var children: Array = []
		for child in ctrl.get_children():
			if child is Control:
				if not include_hidden and not child.visible:
					continue
				children.append(_serialize_control(child, depth + 1, max_depth, include_hidden))
		if not children.is_empty():
			result["children"] = children

	return result


func _get_control_text(ctrl: Control) -> String:
	if ctrl is Button:
		return ctrl.text
	if ctrl is Label:
		return ctrl.text
	if ctrl is LineEdit:
		return ctrl.text
	if ctrl is RichTextLabel:
		return ctrl.text
	if ctrl is TextEdit:
		return ctrl.text.substr(0, 200)
	if ctrl is TabBar:
		var parts = []
		for i in ctrl.get_tab_count():
			parts.append(ctrl.get_tab_title(i))
		return ", ".join(parts)
	if "text" in ctrl:
		return str(ctrl.text)
	return ""


# ---- 编辑器 UI 元素查找工具 ----

func _tool_find_editor_ui_element(id, args: Dictionary) -> Dictionary:
	var pattern: String = args.get("pattern", "")
	if pattern.is_empty():
		return _tool_err(id, "缺少必填参数 pattern")

	var filter_class: String = args.get("filter_class", "")
	var base := EditorInterface.get_base_control()
	if not base:
		return _tool_err(id, "无法获取编辑器 UI 根节点。")

	var results: Array = []
	_find_controls(base, pattern.to_lower(), filter_class, [], results)

	if results.is_empty():
		return _tool_ok(id, "未找到匹配 '%s' 的控件。" % pattern)

	# 限制返回数量，避免过大
	var max_results := 30
	var trimmed := results.slice(0, max_results)
	var summary := {
		"pattern": pattern,
		"filter_class": filter_class,
		"total": results.size(),
		"shown": trimmed.size(),
		"matches": trimmed,
	}
	return _tool_ok(id, JSON.stringify(summary, "  "))


func _find_controls(ctrl: Control, pattern: String, filter_class: String, path: Array, out_results: Array) -> void:
	if out_results.size() >= 50:
		return

	var name_lower := ctrl.name.to_lower()
	var cls := ctrl.get_class()
	var cls_lower := cls.to_lower()
	var ctrl_text := _get_control_text(ctrl).to_lower()

	# 检查是否匹配
	var cls_ok := true
	if not filter_class.is_empty():
		cls_ok = (cls == filter_class)

	var text_match := false
	if pattern in name_lower or pattern in cls_lower or pattern in ctrl_text:
		text_match = true

	if cls_ok and text_match:
		var rect := ctrl.get_global_rect()
		var info = {
			"name": ctrl.name,
			"class": cls,
			"visible": ctrl.visible,
			"rect": {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y},
			"path": "/".join(path + [ctrl.name]),
		}
		if not ctrl_text.is_empty():
			info["text"] = ctrl_text
		out_results.append(info)

	# 递归搜索子控件
	var child_path := path + [ctrl.name]
	for child in ctrl.get_children():
		if child is Control:
			_find_controls(child, pattern, filter_class, child_path, out_results)


# ---- UI 拾取工具（点击任意控件复制路径） ----

func _tool_pick_ui_element(id, args: Dictionary) -> Dictionary:
	var base := EditorInterface.get_base_control()
	if not base:
		return _tool_err(id, "无法获取编辑器 UI 根节点。")

	if not _current_peer:
		return _tool_err(id, "内部错误：无法获取客户端连接。")

	# 注册延迟响应
	var pending_key := _defer_response(_current_peer, id)

	# 使用 PickerOverlay 工厂方法
	PickerOverlay.create(base,
		func(path_str: String):
			DisplayServer.clipboard_set(path_str)
			_send_deferred_ok(pending_key, "[已复制到剪贴板] " + path_str),
		func():
			_send_deferred_err(pending_key, "拾取已取消（右键点击）")
	)

	return {}  # 延迟响应


func _mk_resp(id, result) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _mk_err(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _tool_ok(id, text: String) -> Dictionary:
	return _mk_resp(id, {
		"content": [{"type": "text", "text": text}],
		"isError": false,
	})


func _tool_err(id, message: String) -> Dictionary:
	return _mk_resp(id, {
		"content": [{"type": "text", "text": message}],
		"isError": true,
	})


# ============================================================================
# 延迟响应：支持需要用户交互才能完成的工具（如 pick_ui_element）
# ============================================================================

func _defer_response(peer: StreamPeerTCP, id) -> int:
	"""注册延迟响应，返回 pending_key。工具返回 {} 表示稍后响应。"""
	var key := _next_pending_key
	_next_pending_key += 1
	_pending_requests[key] = {"peer": peer, "id": id}
	return key


func _send_deferred_ok(pending_key: int, text: String) -> void:
	"""发送延迟成功响应并清理。"""
	if not _pending_requests.has(pending_key):
		return
	var req = _pending_requests[pending_key]
	_pending_requests.erase(pending_key)
	_send(req.peer, JSON.stringify(_tool_ok(req.id, text)))


func _send_deferred_err(pending_key: int, message: String) -> void:
	"""发送延迟错误响应并清理。"""
	if not _pending_requests.has(pending_key):
		return
	var req = _pending_requests[pending_key]
	_pending_requests.erase(pending_key)
	_send(req.peer, JSON.stringify(_tool_err(req.id, message)))


func _cancel_pending_requests() -> void:
	"""清理所有未完成的延迟请求。"""
	for req in _pending_requests.values():
		_send(req.peer, JSON.stringify(_tool_err(req.id, "请求已取消（服务器关闭）")))
	_pending_requests.clear()


# ============================================================================
# 辅助：控件路径解析
# ============================================================================

func _resolve_control_by_path(path_str: String) -> Control:
	## 根据 find_editor_ui_element 返回的 path 解析 Control 节点。
	var base := EditorInterface.get_base_control()
	if not base:
		return null

	var parts := path_str.split("/")
	if parts.is_empty():
		return base

	# 如果路径第一段与 base 名称相同则跳过
	var start_idx := 0
	if parts[0] == base.name:
		start_idx = 1

	var current: Control = base
	for i in range(start_idx, parts.size()):
		var found := false
		for child in current.get_children():
			if child is Control and child.name == parts[i]:
				current = child
				found = true
				break
		if not found:
			return null
	return current


# ============================================================================
# 辅助：输入模拟
# ============================================================================

func _get_editor_viewport() -> Viewport:
	## 获取当前活跃的编辑器场景视口 (2D 或 3D)。仅用于截图。
	var vp := EditorInterface.get_editor_viewport_2d()
	if vp:
		return vp
	vp = EditorInterface.get_editor_viewport_3d()
	if vp:
		return vp
	return EditorInterface.get_base_control().get_viewport()


func _get_main_viewport() -> Viewport:
	## 获取编辑器主窗口视口。用于 UI 交互（点击控件、按键等）。
	var base := EditorInterface.get_base_control()
	if base:
		return base.get_viewport()
	return null


func _simulate_mouse_click(global_pos: Vector2, button: String, double_click: bool) -> void:
	var vp := _get_main_viewport()
	if not vp:
		return

	var btn_index := MOUSE_BUTTON_LEFT
	match button:
		"right":  btn_index = MOUSE_BUTTON_RIGHT
		"middle": btn_index = MOUSE_BUTTON_MIDDLE

	# Mouse down
	var down := InputEventMouseButton.new()
	down.button_index = btn_index
	down.pressed = true
	down.global_position = global_pos
	down.position = global_pos
	vp.push_input(down)

	# 微小延迟（通过等待一帧无法实现，直接发 up）
	var up := InputEventMouseButton.new()
	up.button_index = btn_index
	up.pressed = false
	up.global_position = global_pos
	up.position = global_pos
	vp.push_input(up)

	if double_click:
		var down2 := InputEventMouseButton.new()
		down2.button_index = btn_index
		down2.pressed = true
		down2.global_position = global_pos
		down2.position = global_pos
		down2.double_click = true
		vp.push_input(down2)

		var up2 := InputEventMouseButton.new()
		up2.button_index = btn_index
		up2.pressed = false
		up2.global_position = global_pos
		up2.position = global_pos
		vp.push_input(up2)


func _simulate_mouse_move(global_pos: Vector2) -> void:
	var vp := _get_main_viewport()
	if not vp:
		return

	var motion := InputEventMouseMotion.new()
	motion.global_position = global_pos
	motion.position = global_pos
	vp.push_input(motion)


func _simulate_key_char(ch: String) -> void:
	## 发送单个字符的按键事件。
	var vp := _get_main_viewport()
	if not vp:
		return

	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.keycode = KEY_NONE
	key_event.physical_keycode = KEY_NONE
	key_event.key_label = KEY_NONE
	if not ch.is_empty():
		key_event.unicode = ch.unicode_at(0)
	vp.push_input(key_event)

	var up_event := InputEventKey.new()
	up_event.pressed = false
	up_event.keycode = KEY_NONE
	up_event.physical_keycode = KEY_NONE
	up_event.key_label = KEY_NONE
	if not ch.is_empty():
		up_event.unicode = ch.unicode_at(0)
	vp.push_input(up_event)


# 常用按键名 → KEY_ 常量映射
const _KEY_MAP := {
	"Enter": KEY_ENTER,
	"Return": KEY_ENTER,
	"Escape": KEY_ESCAPE,
	"Esc": KEY_ESCAPE,
	"Tab": KEY_TAB,
	"Backspace": KEY_BACKSPACE,
	"Delete": KEY_DELETE,
	"Insert": KEY_INSERT,
	"Home": KEY_HOME,
	"End": KEY_END,
	"PageUp": KEY_PAGEUP,
	"PageDown": KEY_PAGEDOWN,
	"Left": KEY_LEFT,
	"Right": KEY_RIGHT,
	"Up": KEY_UP,
	"Down": KEY_DOWN,
	"Space": KEY_SPACE,
	"F1": KEY_F1,
	"F2": KEY_F2,
	"F3": KEY_F3,
	"F4": KEY_F4,
	"F5": KEY_F5,
	"F6": KEY_F6,
	"F7": KEY_F7,
	"F8": KEY_F8,
	"F9": KEY_F9,
	"F10": KEY_F10,
	"F11": KEY_F11,
	"F12": KEY_F12,
	"Shift": KEY_SHIFT,
	"Alt": KEY_ALT,
	"Control": KEY_CTRL,
	"Ctrl": KEY_CTRL,
	"Meta": KEY_META,
}


func _parse_key_combo(key: String) -> Dictionary:
	## 解析组合键字符串，如 'Control+S' → {keycode=KEY_S, ctrl_pressed=true}
	var result := {
		"keycode": KEY_NONE,
		"unicode": 0,
		"ctrl_pressed": false,
		"shift_pressed": false,
		"alt_pressed": false,
		"meta_pressed": false,
	}

	var parts := key.split("+")
	for part in parts:
		var trimmed := part.strip_edges()
		match trimmed.to_lower():
			"control", "ctrl":
				result.ctrl_pressed = true
			"shift":
				result.shift_pressed = true
			"alt":
				result.alt_pressed = true
			"meta", "super", "cmd", "windows", "win":
				result.meta_pressed = true
			_:
				# 尝试按键名映射
				if _KEY_MAP.has(trimmed):
					result.keycode = _KEY_MAP[trimmed]
				elif trimmed.length() == 1:
					result.keycode = KEY_NONE
					result.unicode = trimmed.unicode_at(0)
				else:
					# 尝试通过 OS 查找
					var kc := OS.find_keycode_from_string(trimmed)
					if kc != KEY_NONE:
						result.keycode = kc
					else:
						result.unicode = trimmed.unicode_at(0)

	return result


func _simulate_key_combo(key: String) -> void:
	var parsed := _parse_key_combo(key)
	var vp := _get_main_viewport()
	if not vp:
		return

	# 如果有修饰键，先按下修饰键
	var mod_events: Array = []
	if parsed.ctrl_pressed:
		var ev := InputEventKey.new()
		ev.keycode = KEY_CTRL
		ev.pressed = true
		mod_events.append(ev)
	if parsed.shift_pressed:
		var ev := InputEventKey.new()
		ev.keycode = KEY_SHIFT
		ev.pressed = true
		mod_events.append(ev)
	if parsed.alt_pressed:
		var ev := InputEventKey.new()
		ev.keycode = KEY_ALT
		ev.pressed = true
		mod_events.append(ev)

	for ev in mod_events:
		vp.push_input(ev)

	# 主按键
	var key_ev := InputEventKey.new()
	key_ev.pressed = true
	key_ev.keycode = parsed.keycode
	key_ev.physical_keycode = parsed.keycode
	key_ev.key_label = parsed.keycode
	key_ev.unicode = parsed.unicode
	key_ev.ctrl_pressed = parsed.ctrl_pressed
	key_ev.shift_pressed = parsed.shift_pressed
	key_ev.alt_pressed = parsed.alt_pressed
	key_ev.meta_pressed = parsed.meta_pressed
	vp.push_input(key_ev)

	# 释放主按键
	var key_up := InputEventKey.new()
	key_up.pressed = false
	key_up.keycode = parsed.keycode
	key_up.physical_keycode = parsed.keycode
	key_up.key_label = parsed.keycode
	key_up.unicode = parsed.unicode
	key_up.ctrl_pressed = parsed.ctrl_pressed
	key_up.shift_pressed = parsed.shift_pressed
	key_up.alt_pressed = parsed.alt_pressed
	key_up.meta_pressed = parsed.meta_pressed
	vp.push_input(key_up)

	# 释放修饰键（倒序）
	mod_events.reverse()
	for ev in mod_events:
		var up_ev := InputEventKey.new()
		up_ev.keycode = ev.keycode
		up_ev.pressed = false
		vp.push_input(up_ev)


# ============================================================================
# 新增工具实现
# ============================================================================

# ---- screenshot ----

func _tool_screenshot(id, _args: Dictionary) -> Dictionary:
	var vp := _get_editor_viewport()
	if not vp:
		return _tool_err(id, "无法获取编辑器视口，请在 Godot 中打开一个场景。")

	var img := vp.get_texture().get_image()
	if not img:
		return _tool_err(id, "无法从视口获取纹理图像。")

	var png_data := img.save_png_to_buffer()
	var b64 := Marshalls.raw_to_base64(png_data)
	return _tool_ok(id, b64)


# ---- click_element ----

func _tool_click_element(id, args: Dictionary) -> Dictionary:
	var ref: String = args.get("ref", "")
	if ref.is_empty():
		return _tool_err(id, "缺少必填参数 ref（控件路径）")

	var ctrl := _resolve_control_by_path(ref)
	if not ctrl:
		return _tool_err(id, "未找到控件: " + ref)

	var rect := ctrl.get_global_rect()
	var center := rect.position + rect.size / 2.0

	_simulate_mouse_click(center, args.get("button", "left"), args.get("dblclick", false))
	return _tool_ok(id, "已点击: %s @ (%.0f, %.0f)" % [ref, center.x, center.y])


# ---- type_text ----

func _tool_type_text(id, args: Dictionary) -> Dictionary:
	var text: String = args.get("text", "")
	var ref: String = args.get("ref", "")

	if not ref.is_empty():
		var ctrl := _resolve_control_by_path(ref)
		if not ctrl:
			return _tool_err(id, "未找到控件: " + ref)
		ctrl.grab_focus()

	for ch in text:
		_simulate_key_char(ch)

	return _tool_ok(id, "已输入 %d 个字符" % text.length())


# ---- press_key ----

func _tool_press_key(id, args: Dictionary) -> Dictionary:
	var key: String = args.get("key", "")
	if key.is_empty():
		return _tool_err(id, "缺少必填参数 key（如 Enter、Escape、Control+S）")

	_simulate_key_combo(key)
	return _tool_ok(id, "已按键: " + key)


# ---- run_gdscript ----

func _tool_run_gdscript(id, args: Dictionary) -> Dictionary:
	var code: String = args.get("code", "")
	if code.is_empty():
		return _tool_err(id, "缺少必填参数 code")

	# 阶段 1：无命名输入 → 全局作用域完整（可访问 GDScript/FileAccess 等全局类）
	var expr := Expression.new()
	var err := expr.parse(code, [])
	if err == OK:
		var result = expr.execute([], EditorInterface)
		if not expr.has_execute_failed():
			if typeof(result) == TYPE_OBJECT:
				return _tool_ok(id, str(result))
			return _tool_ok(id, str(result))

	# 阶段 2：加入命名输入 → 可访问编辑器单例和全局类（回退方案）
	var input_names: Array[StringName] = [
		&"EditorInterface", &"ProjectSettings", &"OS", &"Engine",
		&"DisplayServer", &"Input", &"Time", &"ResourceLoader",
		&"ResourceSaver", &"ClassDB",
		# 全局类引用
		&"GDScript", &"FileAccess", &"DirAccess",
	]
	var input_values: Array = [
		EditorInterface, ProjectSettings, OS, Engine,
		DisplayServer, Input, Time, ResourceLoader,
		ResourceSaver, ClassDB,
		GDScript, FileAccess, DirAccess,
	]
	expr = Expression.new()
	err = expr.parse(code, input_names)
	if err != OK:
		return _tool_err(id, "解析错误: %s (第 %d 行)" % [expr.get_error_text(), expr.get_error_line()])

	var result = expr.execute(input_values, EditorInterface)
	if expr.has_execute_failed():
		return _tool_err(id, "执行错误: " + expr.get_error_text())

	if typeof(result) == TYPE_OBJECT:
		return _tool_ok(id, str(result))
	return _tool_ok(id, str(result))


# ---- hover_element ----

func _tool_hover_element(id, args: Dictionary) -> Dictionary:
	var ref: String = args.get("ref", "")
	if ref.is_empty():
		return _tool_err(id, "缺少必填参数 ref（控件路径）")

	var ctrl := _resolve_control_by_path(ref)
	if not ctrl:
		return _tool_err(id, "未找到控件: " + ref)

	var rect := ctrl.get_global_rect()
	var center := rect.position + rect.size / 2.0

	_simulate_mouse_move(center)
	return _tool_ok(id, "已悬停: %s @ (%.0f, %.0f)" % [ref, center.x, center.y])


# ---- drag_element ----

func _tool_drag_element(id, args: Dictionary) -> Dictionary:
	var from_ref: String = args.get("from_ref", "")
	var to_ref: String = args.get("to_ref", "")

	if from_ref.is_empty() or to_ref.is_empty():
		return _tool_err(id, "缺少必填参数 from_ref 或 to_ref（控件路径）")

	var from_ctrl := _resolve_control_by_path(from_ref)
	if not from_ctrl:
		return _tool_err(id, "未找到源控件: " + from_ref)

	var to_ctrl := _resolve_control_by_path(to_ref)
	if not to_ctrl:
		return _tool_err(id, "未找到目标控件: " + to_ref)

	var from_center := from_ctrl.get_global_rect().position + from_ctrl.get_global_rect().size / 2.0
	var to_center := to_ctrl.get_global_rect().position + to_ctrl.get_global_rect().size / 2.0

	var vp := _get_main_viewport()
	if not vp:
		return _tool_err(id, "无法获取编辑器视口")

	# Mouse down at source
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.global_position = from_center
	down.position = from_center
	vp.push_input(down)

	# Move to target
	var motion := InputEventMouseMotion.new()
	motion.global_position = to_center
	motion.position = to_center
	vp.push_input(motion)

	# Mouse up at target
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.global_position = to_center
	up.position = to_center
	vp.push_input(up)

	return _tool_ok(id, "已从 %s 拖拽到 %s" % [from_ref, to_ref])


# ---- select_node ----

func _tool_select_node(id, args: Dictionary) -> Dictionary:
	var name: String = args.get("name", "")
	var node_path: String = args.get("path", "")

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return _tool_err(id, "当前没有打开的场景。")

	var target: Node = null

	if not name.is_empty():
		# 按名称递归查找
		target = _find_node_by_name(root, name)

	if not target and not node_path.is_empty():
		target = root.get_node_or_null(node_path)

	if not target:
		return _tool_err(id, "未找到节点: name='%s' path='%s'" % [name, node_path])

	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(target)
	EditorInterface.edit_node(target)

	return _tool_ok(id, "已选中节点: %s (%s)" % [target.name, target.get_class()])


func _find_node_by_name(root: Node, name: String) -> Node:
	if root.name == name:
		return root
	for child in root.get_children():
		var found := _find_node_by_name(child, name)
		if found:
			return found
	return null


# ---- get_node_properties ----

func _tool_get_node_properties(id, args: Dictionary) -> Dictionary:
	var node_path: String = args.get("path", "")

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return _tool_err(id, "当前没有打开的场景。")

	var target: Node
	if node_path.is_empty():
		# 使用当前选中节点
		var sel := EditorInterface.get_selection()
		var selected := sel.get_selected_nodes()
		if selected.is_empty():
			return _tool_err(id, "未指定节点且没有选中节点。请先通过 select_node 选中节点，或提供 path 参数。")
		target = selected[0]
	else:
		target = root.get_node_or_null(node_path)

	if not target:
		return _tool_err(id, "未找到节点: " + node_path)

	var props: Array = []
	for prop in target.get_property_list():
		var prop_name: String = prop.name
		# 跳过内部属性
		if prop_name.begins_with("_"):
			continue
		var val = target.get(prop_name)
		props.append({
			"name": prop_name,
			"type": type_string(typeof(val)),
			"value": str(val),
		})

	var result := {
		"node": target.name,
		"class": target.get_class(),
		"path": String(root.get_path_to(target)),
		"properties": props,
	}
	return _tool_ok(id, JSON.stringify(result, "  "))


# ---- set_node_property ----

func _tool_set_node_property(id, args: Dictionary) -> Dictionary:
	var node_path: String = args.get("path", "")
	var property: String = args.get("property", "")
	if property.is_empty():
		return _tool_err(id, "缺少必填参数 property")

	if not "value" in args:
		return _tool_err(id, "缺少必填参数 value")

	var value = args.get("value")

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return _tool_err(id, "当前没有打开的场景。")

	var target: Node
	if node_path.is_empty():
		var sel := EditorInterface.get_selection()
		var selected := sel.get_selected_nodes()
		if selected.is_empty():
			return _tool_err(id, "未指定节点且没有选中节点。")
		target = selected[0]
	else:
		target = root.get_node_or_null(node_path)

	if not target:
		return _tool_err(id, "未找到节点: " + node_path)

	# 尝试类型转换
	var prop_list := target.get_property_list()
	for prop in prop_list:
		if prop.name == property:
			match prop.type:
				TYPE_INT:
					value = int(value)
				TYPE_FLOAT:
					value = float(value)
				TYPE_BOOL:
					if value is String:
						value = value.to_lower() == "true"
					else:
						value = bool(value)
				TYPE_STRING:
					value = str(value)
				TYPE_VECTOR2, TYPE_VECTOR2I:
					if value is String:
						var parts : Array  = value.strip_edges().split(",")
						if parts.size() >= 2:
							value = Vector2(float(parts[0]), float(parts[1]))
				TYPE_VECTOR3, TYPE_VECTOR3I:
					if value is String:
						var parts : Array = value.strip_edges().split(",")
						if parts.size() >= 3:
							value = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
				TYPE_COLOR:
					if value is String:
						value = Color(value)
			break

	target.set(property, value)
	# 标记场景已修改
	EditorInterface.mark_scene_as_unsaved()

	return _tool_ok(id, "已设置 %s.%s = %s" % [target.name, property, str(value)])


# ============================================================================
# 网络 I/O
# ============================================================================

func _send(peer: StreamPeerTCP, data: String) -> void:
	var body := data.to_utf8_buffer()
	var header := "Content-Length: %d\r\n\r\n" % body.size()
	peer.put_data(header.to_utf8_buffer() + body)


func _send_error(peer: StreamPeerTCP, id, code: int, message: String) -> void:
	_send(peer, JSON.stringify(_mk_err(id, code, message)))
