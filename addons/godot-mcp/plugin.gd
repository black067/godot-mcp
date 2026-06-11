@tool
extends EditorPlugin

## godot-mcp EditorPlugin 入口
##
## 通过 项目 → MCP Server 菜单项手动控制开关（Toggle）。
## 端口在 项目设置 → godot_mcp/port 中配置，默认为 8765。

const DEFAULT_PORT := 8765
const POLL_INTERVAL := 0.05
const MENU_LABEL_START := "MCP Server: Start"
const MENU_LABEL_STOP  := "MCP Server: Stop"

var _server: TCPServer = null
var _poll_timer: Timer = null
var _mcp: RefCounted = null
var _running := false


func _enter_tree() -> void:
	_define_project_settings()
	# 初始状态：未运行，显示 Start
	add_tool_menu_item(MENU_LABEL_START, _toggle_server)


func _exit_tree() -> void:
	_remove_menu_silent(MENU_LABEL_START)
	_remove_menu_silent(MENU_LABEL_STOP)
	_stop_server()


# ---- 项目设置 ----

func _define_project_settings() -> void:
	var name := "godot_mcp/port"
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, DEFAULT_PORT)
		ProjectSettings.set_initial_value(name, DEFAULT_PORT)
	ProjectSettings.add_property_info({
		"name": name,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1024,65535,1",
	})
	ProjectSettings.set_as_basic(name, true)


# ---- Toggle 控制 ----

func _toggle_server() -> void:
	if _running:
		stop()
	else:
		start()


func start() -> void:
	if _running:
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
	_swap_menu_label()
	print("[godot-mcp] 已在 127.0.0.1:%d 启动" % port)


func stop() -> void:
	if not _running:
		return
	_stop_server()
	_swap_menu_label()
	print("[godot-mcp] 已停止")


func _stop_server() -> void:
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


func _swap_menu_label() -> void:
	if _running:
		remove_tool_menu_item(MENU_LABEL_START)
		add_tool_menu_item(MENU_LABEL_STOP, _toggle_server)
	else:
		remove_tool_menu_item(MENU_LABEL_STOP)
		add_tool_menu_item(MENU_LABEL_START, _toggle_server)


func _remove_menu_silent(label: String) -> void:
	# remove_tool_menu_item 在 item 不存在时会报错，这里静默处理
	if not label.is_empty():
		remove_tool_menu_item(label)


# ---- Poll ----

func _on_poll() -> void:
	if not _server or not _mcp:
		return

	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer and _mcp.has_method("accept"):
			_mcp.accept(peer)

	if _mcp.has_method("poll"):
		_mcp.poll()


# ---- 端口获取 ----

func _get_configured_port() -> int:
	if ProjectSettings.has_setting("godot_mcp/port"):
		var p := ProjectSettings.get_setting("godot_mcp/port")
		if typeof(p) == TYPE_INT and p > 0 and p < 65536:
			return p
	return DEFAULT_PORT
