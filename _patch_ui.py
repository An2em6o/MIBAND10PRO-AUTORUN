# -*- coding: utf-8 -*-
"""把 Chaos 安装器的界面段换成「主视图 + 自启动页」两视图版。

只替换 `local root = lvgl.Object(nil, {` 到文件末尾这一段; 其余一字不动。
"""
import io
import sys

LUA = r"C:\zcode\chaos-autostart\Chaos-Module\installer\chaos_installer.lua"
MARK = "local root = lvgl.Object(nil, {"

NEW_UI = r'''local root = lvgl.Object(nil, {
  w = SCR_W, h = SCR_H,
  outline_width = 0, border_width = 0, pad_all = 0,
  bg_opa = lvgl.OPA(100), bg_color = V_DEEP,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
-- 重要(实测): LVGL 对象默认带 SCROLLABLE, 会把手势吃掉 —— 表现就是
-- **长按表盘进不了表盘选择页**(主包与投递包都一样)。凡是本脚本创建的容器对象,
-- 一律清掉 SCROLLABLE; 需要点击的再单独加 CLICKABLE。
root:clear_flag(lvgl.FLAG.SCROLLABLE)
-- 只清 SCROLLABLE **不够**(清完长按仍然进不了表盘选择页) —— 还要 add_flag(EVENT_BUBBLE)。
-- EVENT_BUBBLE 让触摸事件**冒泡给父层**(固件的表盘容器), 系统的长按手势才收得到;
-- 固件自带表盘用的也是 CLICKABLE + EVENT_BUBBLE 这两句。
root:add_flag(lvgl.FLAG.CLICKABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

-- ===== 两个视图(主视图 / 自启动页) =====
-- 自启动的操作单独一页(与同机那个平台的排布一致), 主视图只留一个入口。
-- 切页用 align 的 y_ofs 位移, **不用 hidden 标志**: 位移是纯布局, 不依赖任何在本设备上
-- 没验证过的属性; 被移出屏幕的视图 LVGL 自己就不画了。
local OFF_Y = 3000
local main_view = lvgl.Object(root, {
  w = SCR_W, h = SCR_H, bg_opa = lvgl.OPA(100), bg_color = V_DEEP,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 0 },
})
local as_view = lvgl.Object(root, {
  w = SCR_W, h = SCR_H, bg_opa = lvgl.OPA(100), bg_color = V_DEEP,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = OFF_Y },
})
-- 视图容器同样要清 SCROLLABLE + 加 CLICKABLE/EVENT_BUBBLE:
-- 否则长按手势会被这一层吃掉, 自启动页上尤其明显(它整页都是按钮)。
local views = { main_view, as_view }
for i = 1, #views do
  views[i]:clear_flag(lvgl.FLAG.SCROLLABLE)
  views[i]:add_flag(lvgl.FLAG.CLICKABLE)
  views[i]:add_flag(lvgl.FLAG.EVENT_BUBBLE)
end
local function view_show(name)
  local top = name == "as" and as_view or main_view
  local off = name == "as" and main_view or as_view
  top:set { align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 0 } }
  off:set { align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = OFF_Y } }
end

-- 自启动页的状态行先做前置声明: 主视图那个入口按钮要用它刷新, 而它在后面才建。
-- (写成 `local function` 会捕获 nil —— 闭包只认"声明在自己之前"的局部量。)
local as_label
local function as_set(text, color)
  if as_label then as_label:set { text = tostring(text), text_color = color or V_TXT2 } end
end

-- 标题: 一个 Label 说完, 字号与颜色建立层级(不用衬线, 原因见上面 F_BODY 的说明)
lvgl.Label(main_view, {
  text = "Chaos 安装器",
  text_color = V_TXT,
  text_font = lvgl.Font(F_BODY, 32),
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -198 },
})

-- 状态卡片: 中间灰 + 1px 边框 + 圆角走 V_R(卡片里不再套卡片); 状态文字在卡片内居中
local card = lvgl.Object(main_view, {
  w = SCR_W - 32, h = 94,
  bg_opa = lvgl.OPA(100), bg_color = V_MID,
  border_width = 1, border_color = V_LINE2,
  radius = V_R, pad_all = 0,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -126 },
})
card:clear_flag(lvgl.FLAG.SCROLLABLE)
card:add_flag(lvgl.FLAG.EVENT_BUBBLE)
status_label = lvgl.Label(card, {
  text = "准备就绪",
  text_color = V_TXT2,
  text_font = lvgl.Font(F_BODY, 22),
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 0 },
})

-- 按钮三态查表(替代 if/elseif 链)。danger 用**同色系淡底 + 同色字 + 无边框**:
--   Web 上那套写法是 bg-[#ff453a]/15 text-[#ff453a], 即 15% 透明度的红底配红字;
--   LVGL 里对应 bg_color=同色 + bg_opa=OPA(15)(底下的深灰透出来, 就是 /15 的效果)。
--   对照过两种不对的写法: "深灰底 + 红字"缺那层红底, "实心红底 + 白字"又太实。
--   primary = 强调蓝底 + 白字(主操作)
--   danger  = 红 15% 底 + 红字, 无边框
--   ghost   = 深底 + 1px 边框 + 次要文字
local BUTTON_STYLES = {
  primary = { bg = V_ACC_BG, line = V_ACC_BG, fg = V_TXT,  opa = 100, bw = 1 },
  danger  = { bg = V_ERR,    line = V_ERR,    fg = V_ERR,  opa = 15,  bw = 0 },
  ghost   = { bg = V_DEEP,   line = V_LINE2,  fg = V_TXT2, opa = 100, bw = 1 },
}

local function make_button(parent, text, y_ofs, kind, on_clicked)
  local style = BUTTON_STYLES[kind] or BUTTON_STYLES.ghost
  local b = lvgl.Object(parent, {
    w = SCR_W - 32, h = 64,
    bg_opa = lvgl.OPA(style.opa),
    bg_color = style.bg,
    border_width = style.bw,
    border_color = style.line,
    radius = V_R, pad_all = 0,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y_ofs },
  })
  b:clear_flag(lvgl.FLAG.SCROLLABLE)
  b:add_flag(lvgl.FLAG.CLICKABLE)
  b:add_flag(lvgl.FLAG.EVENT_BUBBLE)
  lvgl.Label(b, {
    text = text,
    text_color = style.fg,
    text_font = lvgl.Font(F_BODY, 24),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 0 },
  })
  b:onClicked(function() local ok, msg = pcall(on_clicked); if not ok then set_status("错误: " .. tostring(msg), V_ERR) end end)
  return b
end

local run_button
detect_language()

run_button = make_button(main_view, "运行", 6, "primary", function()
  if runner then set_status("正在运行"); return end
  if started_once then set_status("每次开机只能运行一次", V_WARN); return end
  if module_loaded() then
    set_status("已激活, 请重启后运行", V_WARN)
    return
  end
  started_once = true
  run_button:clear_flag(lvgl.FLAG.CLICKABLE)
  local started, err = start_runner()
  if not started then set_status("运行失败: " .. tostring(err), V_ERR) end
end)

make_button(main_view, "自启动", 80, "ghost", function()
  as_set(autostart_state_text(), V_TXT2)
  view_show("as")
end)

make_button(main_view, "清除重置", 154, "danger", function()
  if runner then set_status("运行中, 请等待", V_WARN); return end
  if not wipe_armed then wipe_armed = true; set_status("再按一次以确认清除", V_WARN); return end
  wipe_armed = false
  -- 顺序: 先把 /data/rc 里属于我们的那行摘掉, 再删数据目录。
  -- autostart_strip 只删我们自己那一行, 不动 /data/rc 里别人(上游平台)的内容。
  autostart_strip()
  autostart_flag(false)
  exec("rm -rf " .. DATA_DIR)
  set_status("已清除, 重启后重新运行", V_OK)
end)

-- ===== 自启动页 =====
lvgl.Label(as_view, {
  text = "自启动",
  text_color = V_TXT,
  text_font = lvgl.Font(F_BODY, 32),
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -198 },
})
-- 状态行: 单行短文本, 不设 width —— 与上面同一条实测理由(不设宽度才会按文字居中)。
as_label = lvgl.Label(as_view, {
  text = "",
  text_color = V_TXT2,
  text_font = lvgl.Font(F_BODY, 18),
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -152 },
})

make_button(as_view, "装自启文件", -66, "ghost", function()
  if runner then as_set("正在运行, 请等待", V_WARN); return end
  local ok, err = autostart_install()
  if ok then
    as_set("已落盘: boot.bin + rc + rc 二跳", V_OK)
  else
    as_set("失败: " .. tostring(err), V_ERR)
  end
end)

make_button(as_view, "开自启动", 8, "primary", function()
  if not autostart_staged() then as_set("先按「装自启文件」", V_WARN); return end
  if autostart_flag(true) then
    as_set("自启动【开】 下次开机自动注册", V_OK)
  else
    as_set("写开关失败", V_ERR)
  end
end)

make_button(as_view, "关自启动", 82, "ghost", function()
  if autostart_flag(false) then
    as_set("自启动【关】 下次开机不注册", V_WARN)
  else
    as_set("删开关失败", V_ERR)
  end
end)

make_button(as_view, "< 返回", 156, "ghost", function()
  as_set(autostart_state_text(), V_TXT2)
  view_show("main")
end)
'''


def main():
    src = io.open(LUA, encoding="utf-8", newline="").read()
    assert "main_view" not in src, "看起来已经改过了"
    k = src.index(MARK)
    assert "== " not in src[:k].split("===== 界面")[-1]  # 无害断言: 确保锚点唯一
    head = src[:k]
    io.open(LUA, "w", encoding="utf-8", newline="").write(head + NEW_UI)
    print("PATCH-UI: OK  %d B -> %d B" % (len(src), len(head + NEW_UI)))


if __name__ == "__main__":
    sys.exit(main())
