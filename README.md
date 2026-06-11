# godot-mcp

在 Godot 编辑器内部运行的 MCP Server（EditorPlugin），使 VS Code Agent 能够直接感知和操作 Godot 编辑器。

## 核心理念

- **Agent 看到用户看到的**：编辑器布局、场景树、Inspector 属性、视口内容、文件系统等
- **Agent 操作用户能操作的**：点击按钮、修改属性、选择节点、打开脚本、运行场景等
- **不硬编码**所有编辑器操作——Agent 通过 MCP 获取编辑器 UI 结构后自主决策，就像人看界面一样

## 架构

- **语言**：GDScript EditorPlugin
- **协议**：MCP（JSON-RPC 2.0 over TCP）
- **传输**：TCP（默认 `127.0.0.1:8765`），使用 Content-Length 头帧格式
- **Godot 版本**：4.6+

## 安装

1. 将 `addons/godot-mcp/` 复制到你的 Godot 项目的 `addons/` 目录
2. 在 Godot 编辑器中：项目 → 项目设置 → 插件 → 启用 `godot-mcp`
3. 在 VS Code 中配置 MCP Client 连接到 `127.0.0.1:8765`

### VS Code MCP 配置示例

```json
{
    "mcpServers": {
        "godot": {
            "url": "http://127.0.0.1:8765",
            "transport": "http"
        }
    }
}
```

## 项目设置

| 设置项 | 默认值 | 说明 |
|--------|--------|------|
| `godot_mcp/port` | `8765` | TCP 监听端口 |
| `godot_mcp/require_confirm` | `true` | 修改操作是否需要用户确认 |
| `godot_mcp/auth_token` | `""` | 可选的身份验证 token |

## 项目结构

```
├── bridge/                  # Node.js 桥接脚本（TCP ↔ stdio）
│   └── bridge.mjs           # MCP 协议转发桥
├── addons/godot-mcp/        # Godot EditorPlugin（GDScript）
│   ├── plugin.gd            # 插件主入口
│   ├── mcp_server.gd        # TCP Server + Content-Length 帧
│   ├── mcp_router.gd        # JSON-RPC 2.0 路由
│   ├── mcp_protocol.gd      # 消息构造 + MCP 常量
│   └── tools/               # 工具模块
├── docs/                    # 设计文档
├── .vscode/mcp.json         # VS Code MCP 配置
├── project.godot            # Godot 项目文件（开发用）
└── README.md
```

## 开发

本项目本身也是一个 Godot 项目。用 Godot 编辑器打开此目录即可开发和调试插件。

## 许可

MIT
