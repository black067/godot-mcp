@tool
extends EditorPlugin
class_name GodotMCPPlugin

## godot-mcp 主插件入口
## 管理 MCP Server 生命周期、注册 ProjectSettings、初始化所有子模块

const DEFAULT_PORT := 8765
const SETTING_PORT := "godot_mcp/port"
const SETTING_REQUIRE_CONFIRM := "godot_mcp/require_confirm"
const SETTING_AUTH_TOKEN := "godot_mcp/auth_token"

var _server: RefCounted = null
var _router: RefCounted = null
var _poll_timer: Timer = null
const POLL_INTERVAL := 0.05  # 50ms 轮询间隔

# ------------------------------------------------------------------ 生命周期

func _enter_tree() -> void:
	_register_project_settings()
	_instantiate_modules()
	_start_server()
	_start_poll_timer()


func _exit_tree() -> void:
	_stop_poll_timer()
	_stop_server()
	_cleanup_modules()

# ------------------------------------------------------------------ ProjectSettings

func _register_project_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_PORT):
		var info: Dictionary = {
			"name": SETTING_PORT,
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "1024,65535",
		}
		ProjectSettings.set_setting(SETTING_PORT, DEFAULT_PORT)
		ProjectSettings.add_property_info(info)
		ProjectSettings.set_initial_value(SETTING_PORT, DEFAULT_PORT)
		ProjectSettings.set_as_basic(SETTING_PORT, true)

	if not ProjectSettings.has_setting(SETTING_REQUIRE_CONFIRM):
		var info: Dictionary = {
			"name": SETTING_REQUIRE_CONFIRM,
			"type": TYPE_BOOL,
		}
		ProjectSettings.set_setting(SETTING_REQUIRE_CONFIRM, true)
		ProjectSettings.add_property_info(info)
		ProjectSettings.set_initial_value(SETTING_REQUIRE_CONFIRM, true)
		ProjectSettings.set_as_basic(SETTING_REQUIRE_CONFIRM, true)

	if not ProjectSettings.has_setting(SETTING_AUTH_TOKEN):
		var info: Dictionary = {
			"name": SETTING_AUTH_TOKEN,
			"type": TYPE_STRING,
		}
		ProjectSettings.set_setting(SETTING_AUTH_TOKEN, "")
		ProjectSettings.add_property_info(info)
		ProjectSettings.set_initial_value(SETTING_AUTH_TOKEN, "")
		ProjectSettings.set_as_basic(SETTING_AUTH_TOKEN, true)


func is_require_confirm() -> bool:
	return ProjectSettings.get_setting(SETTING_REQUIRE_CONFIRM, true)


func get_auth_token() -> String:
	return ProjectSettings.get_setting(SETTING_AUTH_TOKEN, "")

# ------------------------------------------------------------------ 轮询驱动

func _start_poll_timer() -> void:
	if _poll_timer:
		return
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()


func _stop_poll_timer() -> void:
	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null


func _on_poll() -> void:
	if _server:
		_server.poll()

# ------------------------------------------------------------------ 模块管理

func _instantiate_modules() -> void:
	var base_dir := _get_addon_dir()

	# 加载并实例化 MCP 协议层
	var MCPProtocol = load(base_dir + "mcp_protocol.gd")
	var protocol: RefCounted = MCPProtocol.new()

	# 加载并实例化 Router
	var MCPRouter = load(base_dir + "mcp_router.gd")
	_router = MCPRouter.new()
	_router.setup(protocol, self)

	# 加载并实例化 Server
	var MCPServer = load(base_dir + "mcp_server.gd")
	_server = MCPServer.new()
	_server.setup(_router, self)


func _cleanup_modules() -> void:
	_server = null
	_router = null


func _start_server() -> void:
	var port: int = ProjectSettings.get_setting(SETTING_PORT, DEFAULT_PORT)
	print_rich("[color=cyan][godot-mcp][/color] Starting MCP Server on [b]127.0.0.1:%d[/b]..." % port)
	_server.start(port)


func _stop_server() -> void:
	if _server:
		_server.stop()
	print_rich("[color=cyan][godot-mcp][/color] MCP Server stopped.")


func _get_addon_dir() -> String:
	var script_path: String = get_script().resource_path
	return script_path.get_base_dir() + "/"

# ------------------------------------------------------------------ 对外接口（供 Tool 使用）
# EditorPlugin 已内置 get_editor_interface()，Tool 可通过 plugin 引用直接调用
