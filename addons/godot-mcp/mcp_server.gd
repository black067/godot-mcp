@tool
extends RefCounted

## godot-mcp MCP 协议处理器
##
## 职责：
##   - 管理多个 TCP 客户端连接
##   - Content-Length 帧协议解析
##   - JSON-RPC 2.0 路由分发
##   - 工具实现（当前仅 get_scene_tree 用于测试）
##
## 由 plugin.gd 驱动：plugin 接受连接后调用 accept()，并通过 poll() 定时处理数据。

const PROTOCOL_VERSION := "2025-03-26"

# 客户端列表：{ peer: StreamPeerTCP, buffer: String }
var _clients: Array = []


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
			var response := _dispatch(json.data)
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
	]


func _call_tool(id, params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	var args: Dictionary = params.get("arguments", {})
	match name:
		"get_scene_tree":
			return _tool_get_scene_tree(id)
		"get_editor_ui_tree":
			return _tool_get_editor_ui_tree(id, args)
		"find_editor_ui_element":
			return _tool_find_editor_ui_element(id, args)
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
# 网络 I/O
# ============================================================================

func _send(peer: StreamPeerTCP, data: String) -> void:
	var body := data.to_utf8_buffer()
	var header := "Content-Length: %d\r\n\r\n" % body.size()
	peer.put_data(header.to_utf8_buffer() + body)


func _send_error(peer: StreamPeerTCP, id, code: int, message: String) -> void:
	_send(peer, JSON.stringify(_mk_err(id, code, message)))
