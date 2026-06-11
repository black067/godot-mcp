@tool
extends RefCounted
class_name MCPServer

## TCP MCP Server
## 管理 TCPServer 生命周期、客户端连接、Content-Length 帧协议

var _plugin: EditorPlugin = null
var _router: RefCounted = null
var _tcp_server: TCPServer = null
var _port: int = 8765
var _active := false
var _peers: Array[StreamPeerTCP] = []
var _peer_buffers: Dictionary = {}  # peer → accumulated byte buffer (PackedByteArray)

# 帧协议常量
const CRLF := "\r\n"
const HEADER_PREFIX := "Content-Length: "

# ------------------------------------------------------------------ 生命周期

func setup(router: RefCounted, plugin: EditorPlugin) -> void:
	_router = router
	_plugin = plugin


func start(port: int) -> void:
	if _active:
		return
	_port = port
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("[godot-mcp] Failed to listen on port %d: %d" % [port, err])
		return
	_active = true
	print_rich("[color=green][godot-mcp][/color] TCP server listening on 127.0.0.1:%d" % port)


func stop() -> void:
	_active = false
	for peer in _peers:
		peer.disconnect_from_host()
	_peers.clear()
	_peer_buffers.clear()
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null


## 每帧由 plugin._process() 或 EditorPlugin._process() 调用
func poll() -> void:
	if not _active:
		return

	# 接受新连接
	if _tcp_server.is_connection_available():
		var peer: StreamPeerTCP = _tcp_server.take_connection()
		if peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_peers.append(peer)
			_peer_buffers[peer] = PackedByteArray()
			print_rich("[color=cyan][godot-mcp][/color] Client connected: %s" % peer)

	# 处理已有连接
	var to_remove: Array = []
	for peer in _peers:
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			to_remove.append(peer)
			continue

		# 读取可用数据
		var available := peer.get_available_bytes()
		if available > 0:
			var data := peer.get_data(available)
			if data[0] != OK:
				to_remove.append(peer)
				continue

			var chunk: PackedByteArray = data[1]
			var buffer: PackedByteArray = _peer_buffers.get(peer, PackedByteArray())
			buffer.append_array(chunk)

			# 处理帧
			var result := _process_buffer(buffer)
			if result.has("error"):
				push_error("[godot-mcp] Protocol error: %s" % result.error)
				to_remove.append(peer)
				continue

			_peer_buffers[peer] = result.buffer

			# 发送响应
			for response in result.responses:
				var response_text: String = response
				_send_raw(peer, response_text)

	# 清理断开的连接
	for peer in to_remove:
		_peers.erase(peer)
		_peer_buffers.erase(peer)
		peer.disconnect_from_host()
		print_rich("[color:cyan][godot-mcp][/color] Client disconnected.")


## 处理缓冲区中的帧
## 返回 { "buffer": remaining, "responses": [String], "error": String (optional) }
func _process_buffer(buffer: PackedByteArray) -> Dictionary:
	var raw := buffer.get_string_from_utf8()
	var responses: Array[String] = []

	while true:
		# 查找 Content-Length 头
		var header_start := raw.find(HEADER_PREFIX)
		if header_start == -1:
			# 没有完整头，保留缓冲区等待更多数据
			break

		var header_end := raw.find(CRLF + CRLF, header_start)
		if header_end == -1:
			# 头不完整，等待更多数据
			break

		# 解析 Content-Length
		var header_line := raw.substr(header_start, header_end - header_start)
		var length_str := header_line.trim_prefix(HEADER_PREFIX).strip_edges()
		if not length_str.is_valid_int():
			return {"error": "Invalid Content-Length: %s" % length_str, "buffer": buffer, "responses": responses}

		var content_length := length_str.to_int()
		var body_start := header_end + 4  # 跳过 \r\n\r\n

		if raw.length() - body_start < content_length:
			# 消息体不完整，等待更多数据
			break

		# 提取消息体
		var body := raw.substr(body_start, content_length)
		raw = raw.substr(body_start + content_length)

		# 路由消息并获取响应
		var response: String = _router.process_message(body)
		if not response.is_empty():
			responses.append(response)

	# 剩余未处理的数据
	var remaining := raw.to_utf8_buffer()
	return {"buffer": remaining, "responses": responses}


func _send_raw(peer: StreamPeerTCP, text: String) -> void:
	var data := text.to_utf8_buffer()
	var header := (HEADER_PREFIX + str(data.size()) + CRLF + CRLF).to_utf8_buffer()
	var packet := header
	packet.append_array(data)
	peer.put_data(packet)
