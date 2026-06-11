@tool
extends RefCounted
class_name MCPRouter

## MCP JSON-RPC 2.0 路由
## 接收 JSON-RPC 消息，分发给对应的 Tool Handler，返回 JSON-RPC 响应

var _protocol: RefCounted = null
var _plugin: EditorPlugin = null
var _tool_handlers: Dictionary = {}  # tool_name → Callable
var _all_tools: Array[Dictionary] = []

# ------------------------------------------------------------------ 初始化

func setup(protocol: RefCounted, plugin: EditorPlugin) -> void:
	_protocol = protocol
	_plugin = plugin
	_register_tools()


func _register_tools() -> void:
	var base_dir := _plugin.get_script().resource_path.get_base_dir() + "/tools/"

	# 按顺序注册 Tool 模块
	var tool_modules := [
		"ui_tools.gd",
		"scene_tools.gd",
		"editor_tools.gd",
		"project_tools.gd",
	]

	for module_name in tool_modules:
		var path := base_dir + module_name
		if not FileAccess.file_exists(path):
			push_warning("[godot-mcp] Tool module not found: %s" % path)
			continue

		var ToolClass = load(path)
		var tool_instance: RefCounted = ToolClass.new()
		tool_instance.setup(_plugin)

		# 获取该模块提供的工具列表
		if tool_instance.has_method("get_tools"):
			var tools: Array = tool_instance.get_tools()
			for tool_def in tools:
				var tool_name: String = tool_def.name
				# 优先级：显式 handler > _handle_<name> 约定 > 通用 handle() 分发
				if tool_def.has("handler"):
					_tool_handlers[tool_name] = tool_def.handler
				elif tool_instance.has_method("_handle_%s" % tool_name):
					_tool_handlers[tool_name] = Callable(tool_instance, "_handle_%s" % tool_name)
				elif tool_instance.has_method("handle"):
					_tool_handlers[tool_name] = Callable(tool_instance, "handle").bind(tool_name)
				_all_tools.append(tool_def)

	print_rich("[color=cyan][godot-mcp][/color] Registered [b]%d[/b] tools." % _all_tools.size())

# ------------------------------------------------------------------ 消息处理

## 处理单条 JSON-RPC 消息，返回 MCP 帧格式的响应字符串（含 Content-Length 头）
func process_message(raw_message: String) -> String:
	var json := JSON.new()
	var err := json.parse(raw_message)
	if err != OK:
		return _protocol.make_error_response(null, MCPProtocol.PARSE_ERROR, "Parse error: %s" % json.get_error_message())

	var request: Variant = json.get_data()
	if not request is Dictionary:
		return _protocol.make_error_response(null, MCPProtocol.INVALID_REQUEST, "Request must be a JSON object")

	var method: String = request.get("method", "")
	var params: Variant = request.get("params", {})
	var req_id: Variant = request.get("id", null)

	# 通知（无 id，不需要响应）
	if req_id == null:
		_handle_notification(method, params)
		return ""

	return _handle_request(method, params, req_id)


func _handle_notification(method: String, params: Variant) -> void:
	match method:
		"notifications/initialized":
			print_rich("[color=cyan][godot-mcp][/color] Client initialized.")
		_:
			push_warning("[godot-mcp] Unhandled notification: %s" % method)


func _handle_request(method: String, params: Variant, req_id: Variant) -> String:
	match method:
		"initialize":
			return _protocol.make_response(_protocol.build_initialize_result(), req_id)

		"tools/list":
			return _protocol.make_response({"tools": _all_tools}, req_id)

		"tools/call":
			return _handle_tool_call(params, req_id)

		"resources/list":
			return _protocol.make_response({"resources": _get_resources()}, req_id)

		"resources/read":
			return _handle_resource_read(params, req_id)

		"ping":
			return _protocol.make_response({}, req_id)

		_:
			return _protocol.make_error_response(req_id, MCPProtocol.METHOD_NOT_FOUND, "Method not found: %s" % method)


# ------------------------------------------------------------------ Tool 调用

func _handle_tool_call(params: Variant, req_id: Variant) -> String:
	var tool_name: String = ""
	var arguments: Dictionary = {}

	if params is Dictionary:
		tool_name = params.get("name", "")
		arguments = params.get("arguments", {})

	if tool_name.is_empty():
		return _protocol.make_error_response(req_id, MCPProtocol.INVALID_PARAMS, "Missing tool name")

	if not _tool_handlers.has(tool_name):
		return _protocol.make_error_response(req_id, MCPProtocol.METHOD_NOT_FOUND, "Tool not found: %s" % tool_name)

	var handler: Callable = _tool_handlers[tool_name]
	var result: Variant = handler.call(arguments)

	# Tool 返回 Dictionary，包含 { "content": [...], "isError": bool }
	if result is Dictionary:
		var content: Array = result.get("content", [{"type": "text", "text": str(result)}])
		var is_error: bool = result.get("isError", false)
		if is_error:
			return _protocol.make_error_response(req_id, MCPProtocol.INTERNAL_ERROR, str(result.get("content", result)))
		return _protocol.make_response({"content": content}, req_id)

	# 简单返回值自动包装
	return _protocol.make_response({
		"content": [{"type": "text", "text": str(result)}]
	}, req_id)


# ------------------------------------------------------------------ Resources

func _get_resources() -> Array:
	# 暂不暴露文件系统资源，后续按需扩展
	return []


func _handle_resource_read(params: Variant, req_id: Variant) -> String:
	var uri: String = ""
	if params is Dictionary:
		uri = params.get("uri", "")
	if uri.is_empty():
		return _protocol.make_error_response(req_id, MCPProtocol.INVALID_PARAMS, "Missing uri")
	return _protocol.make_error_response(req_id, MCPProtocol.METHOD_NOT_FOUND, "Resource not found: %s" % uri)
