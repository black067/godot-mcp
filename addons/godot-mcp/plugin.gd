@tool
extends EditorPlugin

## godot-mcp EditorPlugin 入口
##
## 通过菜单手动控制 MCP Server：
##   项目 → MCP Server: Start / MCP Server: Stop
## 而非在启用插件时自动启动，方便调试。

const DEFAULT_PORT := 8765
const POLL_INTERVAL := 0.05

var _server: TCPServer = null
var _poll_timer: Timer = null
var _mcp: RefCounted = null
var _running := false


func _enter_tree() -> void:
	add_tool_menu_item("MCP Server: Start", _start_server)
	add_tool_menu_item("MCP Server: Stop", _stop_server)


func _exit_tree() -> void:
	remove_tool_menu_item("MCP Server: Start")
	remove_tool_menu_item("MCP Server: Stop")
	_stop_server()


func _start_server() -> void:
	if _running:
		print("[godot-mcp] 已在运行中")
		return

	var port := _get_configured_port()

	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("[godot-mcp] 无法在端口 %d 启动: %d" % [port, err])
		_server = null
		return

	_mcp = load("res://addons/godot-mcp/mcp_server.gd").new()

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()

	_running = true
	print("[godot-mcp] 已在 127.0.0.1:%d 启动" % port)


func _stop_server() -> void:
	if not _running:
		return

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

	_running = false
	print("[godot-mcp] 已停止")


func _on_poll() -> void:
	if not _server or not _mcp:
		return

	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer and _mcp.has_method("accept"):
			_mcp.accept(peer)

	if _mcp.has_method("poll"):
		_mcp.poll()


func _get_configured_port() -> int:
	if ProjectSettings.has_setting("godot_mcp/port"):
		var p := ProjectSettings.get_setting("godot_mcp/port")
		if typeof(p) == TYPE_INT and p > 0 and p < 65536:
			return p
	return DEFAULT_PORT
