@tool
class_name PickerOverlay
extends Control

## 编辑器 UI 拾取覆盖层
##
## 覆盖在编辑器 UI 根节点上，拦截鼠标点击以拾取控件路径。
## 用途：
##   - MCP pick_ui_element 工具（通过 bridge 调用）
##   - 编辑器菜单 "Copy UI Control Path"（手动操作）
##
## 用法：
##   var overlay := PickerOverlay.create(EditorInterface.get_base_control(),
##       func(path): print(path), func(): print("cancelled"))

signal picked(path: String)
signal cancelled()

var _base: Control
var _hovered_rect: Rect2 = Rect2()
var _highlight_color := Color(1.0, 0.8, 0.0, 0.7)  # 金黄色描边


static func create(base: Control, on_picked: Callable, on_cancelled: Callable = Callable()) -> PickerOverlay:
	"""工厂方法：创建拾取覆盖层并连接回调。"""
	var overlay := PickerOverlay.new(base)
	overlay.picked.connect(on_picked)
	if on_cancelled.is_valid():
		overlay.cancelled.connect(on_cancelled)
	base.add_child(overlay)
	return overlay


func _init(base: Control) -> void:
	_base = base
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 半透明蓝色提示层
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.4, 0.8, 0.15)
	add_theme_stylebox_override(&"panel", style)


func _ready() -> void:
	gui_input.connect(_on_gui_input)
	# 添加提示标签
	var label := Label.new()
	label.text = "点击控件获取路径 | 右键取消"
	label.add_theme_color_override(&"font_color", Color.WHITE)
	label.add_theme_font_size_override(&"font_size", 24)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(label)


func _on_gui_input(event: InputEvent) -> void:
	# 鼠标移动 → 更新悬停高亮
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var target := _find_deepest_control_at(_base, mm.global_position, [self])
		if target and target != self:
			_hovered_rect = target.get_global_rect()
		else:
			_hovered_rect = Rect2()
		queue_redraw()
		return

	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return

	# 右键取消
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		cancelled.emit()
		queue_free()
		return

	# 左键拾取
	var target := _find_deepest_control_at(_base, mb.global_position, [self])
	if target:
		var path_str := _build_control_path(_base, target)
		picked.emit(path_str)
	else:
		cancelled.emit()
	queue_free()


func _draw() -> void:
	"""绘制悬停控件的金色描边。"""
	if _hovered_rect.size.x <= 0:
		return
	var local_pos := _hovered_rect.position - global_position
	var local_rect := Rect2(local_pos, _hovered_rect.size)
	draw_rect(local_rect, _highlight_color, false, 2.0)


func _find_deepest_control_at(root: Control, pos: Vector2, exclude: Array[Control] = []) -> Control:
	# 深度优先：先检查子控件，再回退到自身
	for child in root.get_children():
		if child is Control and child.visible and not exclude.has(child):
			var result := _find_deepest_control_at(child, pos, exclude)
			if result:
				return result
	if exclude.has(root):
		return null
	var rect := root.get_global_rect()
	if rect.has_point(pos):
		return root
	return null


func _build_control_path(from: Control, target: Control) -> String:
	# 从根到目标构建路径（用 name 拼接）
	var parts: Array[String] = []
	var current: Control = target
	while current and current != from:
		parts.push_front(current.name)
		var parent := current.get_parent()
		if parent is Control:
			current = parent
		else:
			break
	parts.push_front(from.name)
	return "/".join(parts)
