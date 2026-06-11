# godot-mcp 安装指南

将 godot-mcp 集成到任意 Godot 4.6+ 项目中。

---

## 一、复制插件

将 `addons/godot-mcp/` 复制到目标项目的 `addons/` 目录：

```
your-project/
├── addons/
│   └── godot-mcp/          ← 复制整个目录
│       ├── plugin.cfg
│       ├── plugin.gd
│       ├── mcp_server.gd
│       ├── picker_overlay.gd
│       └── bridge/          ← 内置 bridge.mjs
│           └── bridge.mjs
└── project.godot
```

bridge 已内置在插件中，无需额外复制。

---

## 二、配置 VS Code（自动）

1. 在 Godot 中启用插件（见第四步）
2. **项目 → Setup VS Code MCP**
3. 自动生成 `.vscode/mcp.json`，内容如下：

```json
{
    "servers": {
        "godot": {
            "command": "node",
            "args": ["addons/godot-mcp/bridge/bridge.mjs"]
        }
    }
}
```

> 若 `.vscode/mcp.json` 已存在，会将 godot 条目复制到剪贴板，手动合并即可。

---

## 三、配置端口（可选）

默认端口 `8765`。如需修改，在 `project.godot` 中添加：

```ini
[godot_mcp]
port=8765
```

多项目同时开发时，为每个项目设置不同端口避免冲突。

---

## 四、启用插件

1. 用 Godot 打开目标项目
2. **项目 → 项目设置 → 插件**
3. 找到 `godot-mcp`，勾选启用
4. 控制台应输出：
   ```
   [godot-mcp] 已在 127.0.0.1:8765 启动
   ```

---

## 五、验证连接

在 VS Code 的 Copilot Chat 中调用：

```
调用 godot_status
```

返回 `"connected": true` 即表示成功。

或直接在 Godot 中测试菜单功能：**项目 → Pick UI Control Path**，点击任意控件应复制其路径到剪贴板。

---

## 常见问题

### 连接失败

- 确认 Godot 编辑器已打开且插件已启用
- 检查端口是否被占用：`netstat -ano | findstr 8765`

### 端口冲突

在 `project.godot` 中为不同项目设置不同端口：

```ini
# 项目 A
[godot_mcp]
port=8765

# 项目 B
[godot_mcp]
port=8766
```

### 插件启用后无反应

- 检查 Godot 版本 ≥ 4.6
- 查看 Godot 控制台（底部 Output 面板）是否有报错
- 确认 `addons/godot-mcp/` 下四个文件完整

---

## 依赖

| 依赖 | 说明 |
|------|------|
| Godot 4.6+ | 编辑器插件运行环境 |
| Node.js | 运行 bridge.mjs（VS Code 侧） |
| VS Code + Copilot | MCP Client |

无需额外安装 Godot Asset Library 包。bridge 已内置在 addon 中。
