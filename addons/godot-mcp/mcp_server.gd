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
		}
	]


func _call_tool(id, params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	match name:
		"get_scene_tree":
			return _tool_get_scene_tree(id)
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


# ============================================================================
# JSON-RPC 响应构造
# ============================================================================

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
