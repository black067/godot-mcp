#!/usr/bin/env node
/**
 * godot-mcp TCP → stdio 桥接
 *
 * VS Code 通过 stdio 启动此脚本，脚本连接到 Godot 编辑器中运行的
 * MCP Server（TCP :8765），双向转发 Content-Length 帧消息。
 *
 * 用法: node bridge.mjs [host] [port]
 *   默认: 127.0.0.1:8765
 */

import * as net from "node:net";

const HOST = process.argv[2] ?? "127.0.0.1";
const PORT = parseInt(process.argv[3] ?? "8765", 10);

// ---------------------------------------------------------------------------
// Content-Length 帧协议工具
// ---------------------------------------------------------------------------

function encodeFrame(json) {
  const body = JSON.stringify(json);
  const header = `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`;
  return header + body;
}

/**
 * 从字节流中解析 Content-Length 帧。
 * 返回 { messages: string[], remainder: Buffer }
 */
function decodeFrames(buffer) {
  const messages = [];
  let offset = 0;

  while (offset < buffer.length) {
    const str = buffer.toString("utf8", offset);
    const match = str.match(/^Content-Length: (\d+)\r\n\r\n/);
    if (!match) break;

    const headerLen = match[0].length;
    const bodyLen = parseInt(match[1], 10);

    if (offset + headerLen + bodyLen > buffer.length) break; // 不完整

    const bodyStart = offset + headerLen;
    const body = buffer.toString("utf8", bodyStart, bodyStart + bodyLen);
    messages.push(body);
    offset = bodyStart + bodyLen;
  }

  return { messages, remainder: buffer.subarray(offset) };
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

let tcpBuffer = Buffer.alloc(0);
let stdioBuffer = Buffer.alloc(0);
let tcpSocket = null;
let shutdown = false;

function log(msg) {
  process.stderr.write(`[godot-mcp-bridge] ${msg}\n`);
}

function connect() {
  log(`连接到 Godot MCP Server ${HOST}:${PORT} ...`);

  tcpSocket = net.createConnection({ host: HOST, port: PORT }, () => {
    log("已连接，开始转发。");
  });

  // TCP → stdout
  tcpSocket.on("data", (chunk) => {
    tcpBuffer = Buffer.concat([tcpBuffer, chunk]);
    const result = decodeFrames(tcpBuffer);
    tcpBuffer = result.remainder;

    for (const msg of result.messages) {
      const framed = encodeFrame(JSON.parse(msg));
      process.stdout.write(framed);
    }
  });

  tcpSocket.on("error", (err) => {
    log(`TCP 错误: ${err.message}`);
    // 通知 VS Code 服务器未就绪（通过 stderr，不影响协议帧）
    if (!shutdown) {
      log("Godot 编辑器可能未启动或插件未启用。将每 5 秒重试...");
      tcpSocket = null;
      setTimeout(connect, 5000);
    }
  });

  tcpSocket.on("close", () => {
    if (!shutdown) {
      log("TCP 连接断开，5 秒后重连...");
      tcpSocket = null;
      setTimeout(connect, 5000);
    }
  });
}

// stdin → TCP
process.stdin.on("data", (chunk) => {
  stdioBuffer = Buffer.concat([stdioBuffer, chunk]);
  const result = decodeFrames(stdioBuffer);
  stdioBuffer = result.remainder;

  for (const msg of result.messages) {
    if (tcpSocket && !tcpSocket.destroyed) {
      tcpSocket.write(encodeFrame(JSON.parse(msg)));
    } else {
      log(`丢弃消息（TCP 未连接）: ${msg.slice(0, 100)}`);
    }
  }
});

process.stdin.on("end", () => {
  shutdown = true;
  log("stdin 关闭，退出。");
  if (tcpSocket) tcpSocket.end();
  process.exit(0);
});

process.on("SIGINT", () => {
  shutdown = true;
  if (tcpSocket) tcpSocket.end();
  process.exit(0);
});

// 启动
connect();
