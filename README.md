# godot-mcp

Godot 编辑器内的 MCP Server（EditorPlugin），让 VS Code Agent 像 Playwright 操控网页一样操控 Godot。

## 工作模型

> **定位 → 操作 → 验证**（Playwright 风格）

Agent 不依赖预设的语义工具，而是感知编辑器 UI 结构后自行组合底层操作原语完成任务——就像人看着界面操作一样。

## 安装

详见 [docs/installation.md](docs/installation.md)。

## 工具

| 层 | 工具 | 说明 |
|---|---|---|
| **Perception** | `get_scene_tree` | 获取场景节点树 |
| | `get_editor_ui_tree` | 获取编辑器 UI 控件树 |
| | `find_editor_ui_element` | 按名称/类名搜索 UI 控件 |
| | `screenshot` | 截取编辑器视口（Base64 PNG） |
| | `pick_ui_element` | 点击任意控件获取路径（也支持菜单手动激活） |
| **Action** | `click_element` | 点击 UI 控件 |
| | `type_text` | 向控件输入文本 |
| | `press_key` | 模拟按键/组合键 |
| | `hover_element` | 鼠标悬停 |
| | `drag_element` | 拖拽控件 |
| **Escape** | `run_gdscript` | 执行任意 GDScript 表达式 |
| **Scene** | `select_node` | 选中场景节点 |
| | `get_node_properties` | 读取节点属性 |
| | `set_node_property` | 修改节点属性 |

## 项目结构

```
├── addons/godot-mcp/         # Godot EditorPlugin
│   ├── plugin.cfg            # 插件清单
│   ├── plugin.gd             # 主入口 + 菜单
│   ├── mcp_server.gd         # TCP Server + 全部工具实现
│   ├── picker_overlay.gd     # UI 拾取覆盖层（hover 高亮 + 点击）
│   └── bridge/               # Node.js MCP 桥接代理
│       └── bridge.mjs
├── docs/                     # 设计文档
├── project.godot             # 开发用 Godot 项目
└── README.md
```

## 开发

用 Godot 4.6+ 打开此目录即可开发和调试。

## 许可

MIT
