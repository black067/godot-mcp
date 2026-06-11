@tool
extends RefCounted
class_name MCPProtocol

## MCP 协议工具类
## 提供 JSON-RPC 2.0 消息构造方法和 MCP 协议常量

# JSON-RPC 2.0 标准错误码
const PARSE_ERROR := -32700
const INVALID_REQUEST := -32600
const METHOD_NOT_FOUND := -32601
const INVALID_PARAMS := -32602
const INTERNAL_ERROR := -32603

# MCP 协议版本
const PROTOCOL_VERSION := "2024-11-05"
const SERVER_NAME := "godot-mcp"
const SERVER_VERSION := "0.1.0"

# Content-Length 帧
const CRLF := "\r\n"
const HEADER_PREFIX := "Content-Length: "

# ------------------------------------------------------------------ JSON-RPC 消息构造

func make_response(result: Variant, req_id: Variant) -> String:
	var resp := {
		"jsonrpc": "2.0",
		"id": req_id,
		"result": result,
	}
	return _stringify(resp)


func make_error_response(req_id: Variant, code: int, message: String, data: Variant = null) -> String:
	var error_obj := {
		"code": code,
		"message": message,
	}
	if data != null:
		error_obj["data"] = data

	var resp := {
		"jsonrpc": "2.0",
		"id": req_id if req_id != null else 0,
		"error": error_obj,
	}
	return _stringify(resp)


func make_notification(method: String, params: Variant = {}) -> String:
	var notif := {
		"jsonrpc": "2.0",
		"method": method,
		"params": params,
	}
	return _stringify(notif)


## 将 Dictionary 序列化为 JSON 字符串（不含帧头，帧头由传输层 MCPServer 添加）
func _stringify(data: Dictionary) -> String:
	return JSON.stringify(data, "", false)

# ------------------------------------------------------------------ MCP 协议方法

## 构造 initialize 响应
func build_initialize_result() -> Dictionary:
	return {
		"protocolVersion": PROTOCOL_VERSION,
		"capabilities": {
			"tools": {},
			# "resources": {"subscribe": false, "listChanged": false},
			# "prompts": {},
		},
		"serverInfo": {
			"name": SERVER_NAME,
			"version": SERVER_VERSION,
		},
	}

# ------------------------------------------------------------------ Tool 响应辅助

## 构造标准的 tool 调用成功响应
static func tool_success(text: String) -> Dictionary:
	return {
		"content": [{"type": "text", "text": text}],
		"isError": false,
	}


## 构造标准的 tool 调用错误响应
static func tool_error(message: String) -> Dictionary:
	return {
		"content": [{"type": "text", "text": "Error: %s" % message}],
		"isError": true,
	}


## 构造 JSON 格式的 tool 成功响应
static func tool_success_json(data: Variant) -> Dictionary:
	return {
		"content": [{"type": "text", "text": JSON.stringify(data, "  ", false)}],
		"isError": false,
	}
