#!/usr/bin/env node

/**
 * godot-mcp Bridge — Node.js 智能 MCP 桥接代理
 *
 * 架构原则：
 *   Godot 是工具的唯一权威来源。Bridge 不硬编码任何 Godot 工具定义，
 *   只负责：缓存工具列表 + 透明转发 + 连接状态管理。
 *
 *   VS Code 端（stdio）：以子进程方式被 VS Code MCP Client 启动，通过
 *   stdin/stdout 收发 newline-delimited JSON-RPC 2.0 消息。
 *
 *   Godot 端（TCP）：连接到 Godot 编辑器中运行的 godot-mcp EditorPlugin
 *   （默认 127.0.0.1:8765），使用 Content-Length 头帧格式。
 *
 * 智能代理模式：
 *   - Godot 离线：返回缓存的工具列表（首次仅含 godot_status 元工具），
 *     tools/call 返回友好错误引导用户打开 Godot。
 *   - Godot 上线：后台拉取真实工具列表 → 更新缓存 → 通知 VS Code 刷新。
 *   - Godot 断线：回退到 godot_status → 通知 VS Code 刷新。
 *
 * 用法：
 *   node addons/godot-mcp/bridge/bridge.mjs [--port 8765]
 */

import { createInterface } from "node:readline";
import { connect } from "node:net";

// ============================================================================
// 配置
// ============================================================================

const DEFAULT_PORT = 8765;
const GODOT_HOST = "127.0.0.1";
const RECONNECT_INTERVAL_MS = 3000;
const MAX_RECONNECT_ATTEMPTS = 10;

function parsePort(args) {
  const portIdx = args.indexOf("--port");
  if (portIdx !== -1 && portIdx + 1 < args.length) {
    const p = parseInt(args[portIdx + 1], 10);
    if (!isNaN(p) && p > 0 && p < 65536) return p;
  }
  return DEFAULT_PORT;
}

const PORT = parsePort(process.argv.slice(2));

// ============================================================================
// 状态
// ============================================================================

/** @type {import("node:net").Socket | null} */
let godotSocket = null;
/** @type {Buffer} */
let godotBuffer = Buffer.alloc(0);
let reconnectTimer = null;
let reconnectAttempts = 0;
let shuttingDown = false;
let wasConnected = false;

// ---- 工具缓存：Godot 是唯一权威，bridge 只缓存 + 转发 ----

let _internalId = 0;
/** @type {Map<string, (msg: object) => void>} */
const _internalCallbacks = new Map();

/** bridge 唯一自维护的元工具 */
const META_TOOLS = [
  {
    name: "godot_status",
    description:
      "查询 Godot 编辑器的连接状态。返回是否已连接、端口、工具数量。" +
      "当其他工具返回 'Godot 未连接' 错误时，可先调用此工具确认状态。",
    inputSchema: { type: "object", properties: {} },
  },
];

/** @type {object[]} 工具缓存（初始 META_TOOLS，Godot 上线后追加真实工具） */
let _cachedTools = [...META_TOOLS];

// ============================================================================
// JSON-RPC / MCP 辅助
// ============================================================================

function makeResponse(id, result) {
  return JSON.stringify({ jsonrpc: "2.0", id, result });
}

function makeError(id, code, message) {
  return JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } });
}

function makeNotification(method, params) {
  return JSON.stringify({ jsonrpc: "2.0", method, params });
}

function makeToolOk(id, text) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id,
    result: { content: [{ type: "text", text }], isError: false },
  });
}

function makeToolErr(id, message) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id,
    result: { content: [{ type: "text", text: message }], isError: true },
  });
}

// ============================================================================
// Godot 连接管理
// ============================================================================

function connectToGodot() {
  if (shuttingDown) return;
  if (godotSocket && !godotSocket.destroyed) return;

  const sock = connect({ host: GODOT_HOST, port: PORT });

  sock.on("connect", () => {
    wasConnected = true;
    reconnectAttempts = 0;
    godotSocket = sock;
    godotBuffer = Buffer.alloc(0);
    if (reconnectTimer) {
      clearInterval(reconnectTimer);
      reconnectTimer = null;
    }
    _fetchToolsFromGodot();
  });

  sock.on("data", (chunk) => {
    godotBuffer = Buffer.concat([godotBuffer, chunk]);

    while (true) {
      const headerEnd = godotBuffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) break;

      const header = godotBuffer.subarray(0, headerEnd).toString("utf-8");
      const m = header.match(/^Content-Length:\s*(\d+)/im);
      if (!m) { godotBuffer = Buffer.alloc(0); break; }

      const contentLength = parseInt(m[1], 10);
      const bodyStart = headerEnd + 4;
      const totalNeeded = bodyStart + contentLength;
      if (godotBuffer.length < totalNeeded) break;

      const body = godotBuffer.subarray(bodyStart, totalNeeded).toString("utf-8");
      godotBuffer = godotBuffer.subarray(totalNeeded);

      try {
        _onGodotMessage(JSON.parse(body));
      } catch {
        warn("收到无效 JSON 帧");
      }
    }
  });

  sock.on("close", () => {
    godotSocket = null;
    godotBuffer = Buffer.alloc(0);
    _onGodotDisconnected();
    if (!_tryScheduleReconnect("Godot 连接断开")) return;
    if (wasConnected) warn("Godot 连接断开，将在 " + RECONNECT_INTERVAL_MS / 1000 + "s 后重试（剩余 " + (MAX_RECONNECT_ATTEMPTS - reconnectAttempts) + " 次）");
  });

  sock.on("error", (err) => {
    godotSocket = null;
    godotBuffer = Buffer.alloc(0);
    _onGodotDisconnected();
    if (!_tryScheduleReconnect(err.code === "ECONNREFUSED" ? "" : "连接 Godot 时出错: " + err.message)) return;
    if (err.code !== "ECONNREFUSED") warn("连接 Godot 时出错: " + err.message + "，将在 " + RECONNECT_INTERVAL_MS / 1000 + "s 后重试（剩余 " + (MAX_RECONNECT_ATTEMPTS - reconnectAttempts) + " 次）");
  });
}

/** 尝试调度重连。返回 true 表示已调度，false 表示已达上限。 */
function _tryScheduleReconnect(reason) {
  if (shuttingDown) return false;
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    warn("已重试 " + MAX_RECONNECT_ATTEMPTS + " 次，停止重连。" + (reason ? " 原因: " + reason : ""));
    return false;
  }
  reconnectAttempts++;
  if (reconnectTimer) return true; // 已有定时器在跑
  reconnectTimer = setInterval(() => {
    if (godotSocket && !godotSocket.destroyed) {
      clearInterval(reconnectTimer);
      reconnectTimer = null;
      return;
    }
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      clearInterval(reconnectTimer);
      reconnectTimer = null;
      warn("已重试 " + MAX_RECONNECT_ATTEMPTS + " 次，停止重连。");
      return;
    }
    reconnectAttempts++;
    connectToGodot();
  }, RECONNECT_INTERVAL_MS);
  return true;
}

/** @deprecated 请使用 _tryScheduleReconnect */
function scheduleReconnect() {
  _tryScheduleReconnect("");
}

function sendToGodot(jsonStr) {
  if (!godotSocket || godotSocket.destroyed) return false;
  try {
    const buf = Buffer.from(jsonStr, "utf-8");
    const header = "Content-Length: " + buf.length + "\r\n\r\n";
    godotSocket.write(header);
    godotSocket.write(buf);
    return true;
  } catch {
    return false;
  }
}

// ============================================================================
// Godot → Bridge 消息处理
// ============================================================================

function _onGodotMessage(msg) {
  const id = msg.id;

  // 内部请求的响应（string id）→ 拦截
  if (typeof id === "string" && _internalCallbacks.has(id)) {
    const cb = _internalCallbacks.get(id);
    _internalCallbacks.delete(id);
    cb(msg);
    return;
  }

  // Godot 发来的 tools/list_changed → 重新拉取
  if (msg.method === "notifications/tools/list_changed") {
    _fetchToolsFromGodot();
    return;
  }

  // 其他一切直接透传给 VS Code
  writeStdout(JSON.stringify(msg));
}

function _fetchToolsFromGodot() {
  if (!godotSocket || godotSocket.destroyed) return;

  const reqId = "_b_" + ++_internalId;
  _internalCallbacks.set(reqId, (resp) => {
    if (resp.result && Array.isArray(resp.result.tools)) {
      _cachedTools = [...META_TOOLS, ...resp.result.tools];
      writeStdout(makeNotification("notifications/tools/list_changed"));
    }
  });

  sendToGodot(JSON.stringify({ jsonrpc: "2.0", id: reqId, method: "tools/list", params: {} }));
}

function _onGodotDisconnected() {
  _cachedTools = [...META_TOOLS];
  writeStdout(makeNotification("notifications/tools/list_changed"));
}

// ============================================================================
// VS Code stdio
// ============================================================================

function writeStdout(str) {
  process.stdout.write(str + "\n");
}

function warn(msg) {
  process.stderr.write("[godot-mcp] " + msg + "\n");
}

// ============================================================================
// VS Code → Bridge 消息路由
// ============================================================================

function handleVsCodeMessage(msg) {
  const { method, id, params } = msg;

  // ---- 通知 ----
  if (id === undefined || id === null) {
    if (method === "notifications/initialized") {
      if (godotSocket && !godotSocket.destroyed) sendToGodot(JSON.stringify(msg));
    } else if (godotSocket && !godotSocket.destroyed) {
      sendToGodot(JSON.stringify(msg));
    }
    return;
  }

  // ---- 请求 ----
  switch (method) {
    case "initialize":
      writeStdout(
        makeResponse(id, {
          protocolVersion: "2025-03-26",
          capabilities: { tools: { listChanged: true } },
          serverInfo: { name: "godot-mcp", version: "0.1.0" },
          instructions:
            "Godot 编辑器 MCP Bridge。" +
            (godotSocket
              ? " ✅ 已连接，共 " + _cachedTools.length + " 个工具可用。"
              : " ⚠️ 未连接 Godot。打开编辑器并启用 godot-mcp 插件后工具将自动加载。"),
        })
      );
      return;

    case "tools/list":
      writeStdout(makeResponse(id, { tools: _cachedTools }));
      return;

    case "tools/call":
      _handleToolCall(id, params);
      return;

    case "ping":
      writeStdout(makeResponse(id, {}));
      return;

    default:
      if (godotSocket && !godotSocket.destroyed) {
        sendToGodot(JSON.stringify(msg));
      } else {
        writeStdout(makeError(id, -32000, "Godot 未连接。请打开 Godot 编辑器并启用 godot-mcp 插件。"));
      }
  }
}

function _handleToolCall(id, params) {
  const toolName = params?.name || "";

  // bridge 自维护的元工具
  if (toolName === "godot_status") {
    const ok = !!(godotSocket && !godotSocket.destroyed);
    writeStdout(
      makeToolOk(
        id,
        JSON.stringify(
          {
            connected: ok,
            port: PORT,
            toolsCount: _cachedTools.length,
            message: ok ? "Godot 已连接，MCP 服务正常。" : "Godot 未连接。请打开 Godot 并启用 godot-mcp 插件。",
          },
          null,
          2
        )
      )
    );
    return;
  }

  // 其他工具 → 转发 Godot
  if (godotSocket && !godotSocket.destroyed) {
    sendToGodot(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params }));
    return;
  }

  // Godot 不在线
  writeStdout(
    makeToolErr(
      id,
      "❌ 无法执行工具 **" +
        toolName +
        "**：Godot 编辑器未运行或 godot-mcp 插件未启用。\n\n" +
        "请：1. 打开 Godot 并载入项目  2. 项目设置 → 插件 → 启用 godot-mcp  3. 调用 godot_status 确认连接"
    )
  );
}

// ============================================================================
// 启动
// ============================================================================

function main() {
  connectToGodot();

  const rl = createInterface({ input: process.stdin, output: undefined, terminal: false });

  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      handleVsCodeMessage(JSON.parse(trimmed));
    } catch {
      warn("无法解析 stdin 消息: " + trimmed.substring(0, 100));
    }
  });

  rl.on("close", () => shutdown());
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("exit", () => { if (godotSocket) godotSocket.destroy(); });
}

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  if (reconnectTimer) { clearInterval(reconnectTimer); reconnectTimer = null; }
  if (godotSocket) { godotSocket.destroy(); godotSocket = null; }
  process.exit(0);
}
