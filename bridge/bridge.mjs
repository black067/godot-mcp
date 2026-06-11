#!/usr/bin/env node

/**
 * godot-mcp Bridge — Node.js 智能 MCP 桥接代理
 *
 * 职责：
 *   VS Code 端（stdio）：以子进程方式被 VS Code MCP Client 启动，通过
 *   stdin/stdout 收发 newline-delimited JSON-RPC 2.0 消息。
 *
 *   Godot 端（TCP）：连接到 Godot 编辑器中运行的 godot-mcp EditorPlugin
 *   （默认 127.0.0.1:8765），使用 Content-Length 头帧格式收发 JSON-RPC 消息。
 *
 * 智能代理模式：
 *   - 当 Godot 未运行时，bridge 自行响应 initialize / ping / tools/list，
 *     避免 VS Code 报 "Server 启动失败"。
 *   - 当 Agent 调用工具但 Godot 不在线时，返回友好错误提示用户打开 Godot。
 *   - 当 Godot 上线后，bridge 自动切换为"转发模式"。
 *
 * 用法：
 *   node bridge/bridge.mjs [--port 8765]
 */

import { createInterface } from "node:readline";
import { connect } from "node:net";

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

const DEFAULT_PORT = 8765;
const GODOT_HOST = "127.0.0.1";
const RECONNECT_INTERVAL_MS = 3000; // Godot 断线后重试间隔

// 从命令行参数解析端口
function parsePort(args) {
  const portIdx = args.indexOf("--port");
  if (portIdx !== -1 && portIdx + 1 < args.length) {
    const p = parseInt(args[portIdx + 1], 10);
    if (!isNaN(p) && p > 0 && p < 65536) return p;
  }
  return DEFAULT_PORT;
}

const PORT = parsePort(process.argv.slice(2));

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

/** @type {import("node:net").Socket | null} */
let godotSocket = null;
let godotBuffer = ""; // TCP 流拼接缓冲区
let reconnectTimer = null;
let shuttingDown = false;
let wasConnected = false; // 是否曾成功连接过（用于区分"从未连上"和"连上后断开"）

// ---------------------------------------------------------------------------
// 离线工具列表（与 Godot 插件保持一致的工具签名）
// 当 Godot 不在线时，tools/list 返回此列表，确保 Agent 提前知道所有工具能力
// ---------------------------------------------------------------------------

const OFFLINE_TOOLS = [
  {
    name: "get_editor_ui_tree",
    description:
      "获取 Godot 编辑器 UI 树结构（菜单栏、面板、Inspector 等所有 Control 节点）。需要 Godot 编辑器已打开并启用 godot-mcp 插件。",
    inputSchema: {
      type: "object",
      properties: {
        max_depth: {
          type: "integer",
          description: "最大遍历深度，默认 10",
          default: 10,
        },
        include_hidden: {
          type: "boolean",
          description: "是否包含隐藏节点，默认 false",
          default: false,
        },
      },
    },
  },
  {
    name: "find_ui_element",
    description:
      "在编辑器 UI 中按名称/类名/文本模糊搜索 Control 节点。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        pattern: {
          type: "string",
          description: "搜索模式（支持通配符 *）",
        },
        filter_class: {
          type: "string",
          description: "可选：按类名过滤（如 Button、LineEdit）",
        },
      },
      required: ["pattern"],
    },
  },
  {
    name: "get_scene_tree",
    description:
      "获取当前编辑场景的完整节点树结构。需要 Godot 编辑器已打开且有一个打开的场景。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "get_node_properties",
    description: "获取指定场景节点的所有属性。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        node_path: {
          type: "string",
          description: "节点路径（相对于场景根节点）",
        },
      },
      required: ["node_path"],
    },
  },
  {
    name: "set_node_property",
    description:
      "修改指定场景节点的属性值（通过 EditorUndoRedoManager 可撤销）。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        node_path: {
          type: "string",
          description: "节点路径（相对于场景根节点）",
        },
        property: {
          type: "string",
          description: "属性名",
        },
        value: {
          description: "新属性值（类型由属性决定）",
        },
      },
      required: ["node_path", "property", "value"],
    },
  },
  {
    name: "get_selected_nodes",
    description:
      "获取当前在编辑器中选中的节点列表。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "select_node",
    description:
      "在场景树中选中指定节点。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        node_path: {
          type: "string",
          description: "要选中的节点路径",
        },
      },
      required: ["node_path"],
    },
  },
  {
    name: "play_current_scene",
    description:
      "运行当前编辑的场景。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "stop_playing_scene",
    description:
      "停止当前正在运行的场景。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "get_editor_viewport_screenshot",
    description:
      "截取 2D/3D 编辑器视口的当前画面，返回 base64 编码的 PNG 图片。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        viewport_type: {
          type: "string",
          enum: ["2d", "3d"],
          description: "视口类型：2d 或 3d",
          default: "2d",
        },
      },
    },
  },
  {
    name: "edit_script",
    description:
      "在 Godot 编辑器中打开指定脚本文件到指定行。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        script_path: {
          type: "string",
          description: "脚本文件路径（相对于项目根目录，如 res://player.gd）",
        },
        line: {
          type: "integer",
          description: "跳转到指定行号",
        },
      },
      required: ["script_path"],
    },
  },
  {
    name: "get_filesystem_tree",
    description:
      "获取项目文件系统树结构。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "目录路径（默认为 res://）",
          default: "res://",
        },
      },
    },
  },
  {
    name: "click_editor_button",
    description:
      "根据文本/类名在编辑器 UI 中查找并点击按钮。需要一个已打开的 Godot 编辑器。",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "按钮文本（模糊匹配）",
        },
        button_class: {
          type: "string",
          description: "可选：按钮类名过滤",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "set_editor_text",
    description:
      "在编辑器 UI 输入框中填写文本。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {
        field_pattern: {
          type: "string",
          description: "输入框名称/类名模式",
        },
        text: {
          type: "string",
          description: "要填写的文本",
        },
      },
      required: ["field_pattern", "text"],
    },
  },
  {
    name: "get_editor_layout_info",
    description:
      "获取编辑器布局信息（面板位置、尺寸、可见性等）。需要 Godot 编辑器已打开。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
];

// ---------------------------------------------------------------------------
// MCP 协议辅助
// ---------------------------------------------------------------------------

let nextId = 1;
/** @type {Map<number, {resolve, reject}>} */
const pendingRequests = new Map();

function makeJsonRpcResponse(id, result) {
  return JSON.stringify({ jsonrpc: "2.0", id, result });
}

function makeJsonRpcError(id, code, message, data) {
  const err = { jsonrpc: "2.0", id, error: { code, message } };
  if (data !== undefined) err.error.data = data;
  return JSON.stringify(err);
}

/** 返回给 Agent 的友好错误（isError: true 的 tool result，不是协议错误） */
function makeToolErrorResult(id, message) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text: message }],
      isError: true,
    },
  });
}

// ---------------------------------------------------------------------------
// Godot 连接管理
// ---------------------------------------------------------------------------

function connectToGodot() {
  if (shuttingDown) return;
  if (godotSocket && !godotSocket.destroyed) return;

  const sock = connect({ host: GODOT_HOST, port: PORT });

  sock.on("connect", () => {
    wasConnected = true;
    godotSocket = sock;
    godotBuffer = "";
    if (reconnectTimer) {
      clearInterval(reconnectTimer);
      reconnectTimer = null;
    }
  });

  sock.on("data", (chunk) => {
    godotBuffer += chunk.toString("utf-8");
    // Content-Length 帧解析
    while (true) {
      const headerEnd = godotBuffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) break;

      const header = godotBuffer.substring(0, headerEnd);
      const contentLengthMatch = header.match(/^Content-Length:\s*(\d+)/im);
      if (!contentLengthMatch) {
        warn("无效的 Content-Length 帧头，丢弃缓冲区");
        godotBuffer = "";
        break;
      }

      const contentLength = parseInt(contentLengthMatch[1], 10);
      const bodyStart = headerEnd + 4;
      const totalNeeded = bodyStart + contentLength;

      if (godotBuffer.length < totalNeeded) break; // 数据不完整，等待

      const body = godotBuffer.substring(bodyStart, totalNeeded);
      godotBuffer = godotBuffer.substring(totalNeeded);

      try {
        const msg = JSON.parse(body);
        // Godot 发来的响应或请求，直接写到 stdout 给 VS Code
        writeStdout(JSON.stringify(msg));
      } catch {
        warn("收到无效 JSON 帧");
      }
    }
  });

  sock.on("close", () => {
    if (wasConnected) {
      warn("Godot 连接断开，将在 " + RECONNECT_INTERVAL_MS / 1000 + " 秒后重试");
    }
    godotSocket = null;
    godotBuffer = "";
    scheduleReconnect();
  });

  sock.on("error", (err) => {
    // ECONNREFUSED 是常态（Godot 未启动），不打印；其他错误才报告
    if (err.code !== "ECONNREFUSED") {
      warn("连接 Godot 时出错: " + err.message);
    }
    godotSocket = null;
    godotBuffer = "";
    scheduleReconnect();
  });
}

function scheduleReconnect() {
  if (shuttingDown) return;
  if (reconnectTimer) return;
  reconnectTimer = setInterval(() => {
    if (godotSocket && !godotSocket.destroyed) {
      clearInterval(reconnectTimer);
      reconnectTimer = null;
      return;
    }
    connectToGodot();
  }, RECONNECT_INTERVAL_MS);
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

// ---------------------------------------------------------------------------
// VS Code stdio 通信
// ---------------------------------------------------------------------------

function writeStdout(str) {
  process.stdout.write(str + "\n");
}

/** 仅输出到 stderr 的日志——只在真正的异常/错误时才写，避免 VS Code [warning] 泛滥 */
function warn(msg) {
  process.stderr.write("[godot-mcp] " + msg + "\n");
}

// ---------------------------------------------------------------------------
// MCP 消息路由（来自 VS Code → bridge 处理或转发到 Godot）
// ---------------------------------------------------------------------------

function handleVsCodeMessage(msg) {
  const { method, id, params } = msg;

  // ---- 请求（有 id，需要响应） ----

  if (id !== undefined && id !== null) {
    switch (method) {
      case "initialize": {
        // 始终自响应，VS Code 不会报 Server 启动失败
        writeStdout(
          makeJsonRpcResponse(id, {
            protocolVersion: "2025-03-26",
            capabilities: {
              tools: { listChanged: true },
            },
            serverInfo: {
              name: "godot-mcp",
              version: "0.1.0",
            },
            instructions:
              "Godot MCP Bridge — 请在 Godot 编辑器中启用 godot-mcp 插件后使用工具。" +
              (godotSocket ? " ✅ Godot 已连接。" : " ⚠️ Godot 未连接，请先打开 Godot 编辑器。"),
          })
        );
        return;
      }

      case "tools/list": {
        if (godotSocket && !godotSocket.destroyed) {
          // 转发给 Godot 获取实时工具列表
          sendToGodot(JSON.stringify(msg));
        } else {
          // Godot 不在线，返回离线工具列表
          writeStdout(
            makeJsonRpcResponse(id, {
              tools: OFFLINE_TOOLS,
            })
          );
        }
        return;
      }

      case "tools/call": {
        if (godotSocket && !godotSocket.destroyed) {
          // Godot 在线 → 转发
          sendToGodot(JSON.stringify(msg));
        } else {
          // Godot 不在线 → 返回友好错误
          writeStdout(
            makeToolErrorResult(
              id,
              "❌ 无法执行工具 **" +
                (params?.name || "unknown") +
                "**：Godot 编辑器未运行或 godot-mcp 插件未启用。\n\n" +
                "请执行以下步骤：\n" +
                "1. 打开 Godot 编辑器并载入当前项目\n" +
                "2. 在菜单栏选择 **项目 → 项目设置 → 插件**\n" +
                "3. 启用 **godot-mcp** 插件\n" +
                "4. 确认插件状态栏显示绿色指示条「🤖 MCP 就绪」"
            )
          );
        }
        return;
      }

      case "ping": {
        if (godotSocket && !godotSocket.destroyed) {
          // 有 Godot 时转发
          sendToGodot(JSON.stringify(msg));
        } else {
          // 无 Godot 时自响应
          writeStdout(makeJsonRpcResponse(id, {}));
        }
        return;
      }

      default: {
        // 其他所有请求：尝试转发给 Godot
        if (godotSocket && !godotSocket.destroyed) {
          sendToGodot(JSON.stringify(msg));
        } else {
          writeStdout(
            makeJsonRpcError(
              id,
              -32000,
              "Godot 未连接。请打开 Godot 编辑器并启用 godot-mcp 插件。"
            )
          );
        }
        return;
      }
    }
  }

  // ---- 通知（无 id） ----

  if (method === "notifications/initialized") {
    // initialized 通知：静默接受，如果 Godot 在线则转发
    if (godotSocket && !godotSocket.destroyed) {
      sendToGodot(JSON.stringify(msg));
    }
    // 不在线也 OK，bridge 已经处理了 initialize
    return;
  }

  // 其他通知：如果 Godot 在线则转发
  if (godotSocket && !godotSocket.destroyed) {
    sendToGodot(JSON.stringify(msg));
  }
  // 不在线则静默丢弃
}

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------

function main() {
  // 立即尝试连接 Godot
  connectToGodot();

  // 从 stdin 读取 VS Code 发来的 JSON-RPC 消息
  const rl = createInterface({
    input: process.stdin,
    output: undefined,
    terminal: false,
  });

  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    try {
      const msg = JSON.parse(trimmed);
      handleVsCodeMessage(msg);
    } catch {
      warn("无法解析 stdin 消息: " + trimmed.substring(0, 100));
    }
  });

  rl.on("close", () => {
    shutdown();
  });

  // 优雅退出
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("exit", () => {
    if (godotSocket) godotSocket.destroy();
  });
}

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  if (reconnectTimer) {
    clearInterval(reconnectTimer);
    reconnectTimer = null;
  }
  if (godotSocket) {
    godotSocket.destroy();
    godotSocket = null;
  }
  process.exit(0);
}

main();
