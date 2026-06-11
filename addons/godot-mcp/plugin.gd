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
const MENU_PICK_UI     := "Pick UI Control Path"
const MENU_SETUP_VSCODE := "Setup VS Code MCP"

var _server: TCPServer = null
var _poll_timer: Timer = null
var _mcp: RefCounted = null
var _running := false


func _enter_tree() -> void:
	_define_project_settings()
	# 初始状态：未运行，显示 Start
	add_tool_menu_item(MENU_LABEL_START, _toggle_server)
	# 手动拾取 UI 控件路径（无需 MCP Server 运行）
	add_tool_menu_item(MENU_PICK_UI, _pick_ui_control)
	# 自动配置 VS Code MCP 连接
	add_tool_menu_item(MENU_SETUP_VSCODE, _setup_vscode_mcp)


func _exit_tree() -> void:
	_remove_menu_silent(MENU_LABEL_START)
	_remove_menu_silent(MENU_LABEL_STOP)
	_remove_menu_silent(MENU_PICK_UI)
	_remove_menu_silent(MENU_SETUP_VSCODE)
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


# ---- 手动拾取 UI 控件路径（菜单入口） ----

func _pick_ui_control() -> void:
	var base := EditorInterface.get_base_control()
	if not base:
		push_error("[godot-mcp] 无法获取编辑器 UI 根节点。")
		return

	print("[godot-mcp] 进入 UI 拾取模式：左键点击控件获取路径，右键取消")

	PickerOverlay.create(base,
		func(path_str: String):
			DisplayServer.clipboard_set(path_str)
			print("[godot-mcp] 已复制到剪贴板: " + path_str),
		func():
			print("[godot-mcp] 拾取已取消")
	)


# ---- 自动配置 VS Code MCP 连接 ----

func _setup_vscode_mcp() -> void:
	var base := ProjectSettings.globalize_path("res://")
	var vscode_dir := base.path_join(".vscode")
	var mcp_path := vscode_dir.path_join("mcp.json")

	# 若文件已存在，提示用户手动操作
	if FileAccess.file_exists(mcp_path):
		var hint := '{\n  "servers": {\n    "godot": {\n      "command": "node",\n      "args": ["addons/godot-mcp/bridge/bridge.mjs"]\n    }\n  }\n}'
		DisplayServer.clipboard_set(hint)
		print("[godot-mcp] .vscode/mcp.json 已存在。已将 godot 条目复制到剪贴板，请手动合并到现有配置中。")
		OS.alert(".vscode/mcp.json 已存在。\n\n已将 godot 条目复制到剪贴板，请手动合并到现有 mcp.json 中。", "godot-mcp")
		return

	# 创建 .vscode 目录
	DirAccess.make_dir_recursive_absolute(vscode_dir)

	# 写入 mcp.json
	var config := {
		"servers": {
			"godot": {
				"command": "node",
				"args": ["addons/godot-mcp/bridge/bridge.mjs"],
			}
		}
	}
	var f := FileAccess.open(mcp_path, FileAccess.WRITE)
	if not f:
		push_error("[godot-mcp] 无法创建 " + mcp_path)
		return
	f.store_string(JSON.stringify(config, "  ") + "\n")
	f.close()

	print("[godot-mcp] 已创建 .vscode/mcp.json")
	OS.alert("已创建 .vscode/mcp.json\n\n请在 VS Code 中重新加载窗口以激活 MCP 连接。", "godot-mcp")
