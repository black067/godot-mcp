@tool
extends EditorPlugin

## godot-mcp EditorPlugin 入口
##
## 职责：
##   - 管理 TCPServer 生命周期（启用时启动，禁用时停止）
##   - 使用 Timer 轮询 TCP 连接（EditorPlugin 无 _process）
##   - 将连接交给 MCPServer 处理

const DEFAULT_PORT := 8765
const POLL_INTERVAL := 0.05  # 50ms

var _server: TCPServer = null
var _poll_timer: Timer = null
var _mcp: RefCounted = null  # MCPServer 实例


func _enable_plugin() -> void:
	# 解析端口：project.godot 中的配置优先
	var port := _get_configured_port()

	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("[godot-mcp] 无法在端口 %d 上启动 TCP 服务: %d" % [port, err])
		return

	_mcp = load("res://addons/godot-mcp/mcp_server.gd").new()

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()

	print("[godot-mcp] 已在 127.0.0.1:%d 启动" % port)


func _disable_plugin() -> void:
	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null

	if _mcp and _mcp.has_method("teardown"):
		_mcp.teardown()
	_mcp = null

	if _server:
		_server.stop()
		_server = null

	print("[godot-mcp] 已停止")


func _on_poll() -> void:
	if not _server or not _mcp:
		return

	# 接受新连接
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer and _mcp.has_method("accept"):
			_mcp.accept(peer)

	# 处理已有连接
	if _mcp.has_method("poll"):
		_mcp.poll()


func _get_configured_port() -> int:
	if ProjectSettings.has_setting("godot_mcp/port"):
		var p := ProjectSettings.get_setting("godot_mcp/port")
		if typeof(p) == TYPE_INT and p > 0 and p < 65536:
			return p
	return DEFAULT_PORT
