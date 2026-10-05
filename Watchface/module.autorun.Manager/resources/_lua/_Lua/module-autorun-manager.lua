-- ============================================================================
--  10pro.autorun —— 多模块开机自启动管理器（表盘 Lua / 全权限）
--
--  它管五样东西，各管一段、互不重叠：
--    ① 存在性  /data/rc.d/<name>.sh          模块自己投（写了 = 注册了）
--    ② 策略    /data/rc.d/autorun.json       **就放在注册目录里**，本页回写
--    ③ 产物    /data/rc                     只由本页生成；flash 里的 hook 跑的就是它
--    ④ 闸      /data/rc.d/.autorun.on       自启动页 [3 开启]/[4 关闭] = 建/删这个文件
--    ⑤ 心跳日志 /data/rc.d/.autorun.log       /data/rc 自己写（在 nsh 里）；本页**只读**。
--
--  ★★ 闸的两层语义（2026-10-04 用户定的新方案，动 /data/rc 之前先读懂这一段）：
--     「闸」就是 ④ 那个**文件在不在**，它同时是两样东西：
--       · 用户的总开关 —— [4 关闭] 删掉它 ⇒ 开机一条模块行都不跑；
--       · 开机链的**防砖凭证** —— /data/rc 开跑第一件事是把它**扣掉**（rm -f），
--         等全部模块跑完、再过完安全窗口，才**放行**（echo on > 它）。
--     合起来：开机**被打断**（看门狗 / 断电 / 崩）时闸停在【关】⇒ 下一次开机
--       **一条模块行都不跑** —— 这就是用户要的"一次即停、只能手动开"。
--       恢复只走**明确动作**：[3 开启] / [1 安装]。**绝不**在 [重建] 里顺手补建
--       （那正好会把防砖作废：被打断后一按 [重建] 闸就回来了，下次开机接着崩）。
--     ⑤ 那个日志是给这只闸配的**运行时视图**：每次开机先写一行 `gate_off`
--       （写在 if **外面** —— 闸关着也得留痕，否则"没跑到"和"跑了但闸关"看不出区别）；
--       只有跑到底才再追加一行 `cleared`。
--       ⇒ 末行 `cleared` = 上次正常跑完；末行 `gate_off` = 闸此刻是【关】。
--       ⚠️ **本页永不写它** —— 一写就把"连着两行 gate_off = 上次被打断"这条判据弄脏。
--
--  ★ 模块列表的来源（2026-10-04 用户要求，见 merge()）：
--      模块管理页显示的条目 = **rc.d 里的 .sh** ∪ **/data/rc 里生成行引用的名字**。
--      配置（②）**不决定显示**，只提供 enable/core/order/desc。
--      ⇒ 没装任何模块（两处都空）时列表为空，页面**什么都不显示**；
--      ⇒ "缺脚本"只在「/data/rc 里有那一行、而那个 .sh 不在」时出现；
--      ⇒ 按 [重建] 会把指向不存在脚本的多余行**删掉**，那条缺脚本随后自动消失。
--
--  ★ 本页**自己的落点**只有一个：`/data/10pro.autorun/`（日志 + 命令输出中转 + flash 临时块）。
--    2026-10-04 用户明确：管理器是**独立项目**，不许把东西放在别家的目录里
--    （这里曾经借用 `/data/chaos`，日志跟 chaos 的混在一起，分不清谁写的）。
--
--  ① 和 ②④ 在**同一个目录**里，靠后缀区分：`*.sh` 是模块，`autorun.json` 是策略，
--  `.autorun.on` 是总开关。load_slices() 只认 `^[%w_%-]+%.sh$`，所以后两者
--  **不会被当成模块**。
--
--  ★ 五条不变量（写死在代码里，改动前先想清楚）：
--    1. 别人的行一字不动 —— 重建只替换「生成区」，其余原样留在原位。
--       生成区的判据见 split_others()：以 `sh /data/rc.d/` 开头的行、本页自己发的
--       `if …;then` / `fi` 两行、以及**夹在两行生成行之间**的 `sleep 1`。
--       ⚠️ 2026-10-04 按用户要求**删掉了 [2 接管]** —— 别人的行从此**永不**被搬走。
--    2. 幂等 —— 内容没变就不写盘（连 `set +e` 都一样才算没变）。
--    3. 禁止 = 那一行**根本不出现**在 /data/rc 里，不是"跑了再退出"。
--    4. **不自动重建** —— /data/rc 只在明确时刻被写：模块页/主页的 [重建]、
--       自启动页的 [1 安装]、[3 开启]。改了开关**不会**自动落盘，
--       界面用「● 待重建」提示你按 [重建自启动]。
--       ⚠️ 这条以前是反的（曾经"打开表盘即对账"）—— 按用户要求去掉了：
--          自动重建意味着"打开一下就能悄悄改掉开机脚本"，那是不可审的。
--    5. ★ 生成区**串行**：每个模块一行 `sh …/x.sh`，**不带 `&`**（不后台），
--       两个模块行之间插一行 `sleep 1`。按用户要求（2026-10-04）：
--       脚本不许后台跑、每跑完一个停 1 秒再跑下一个（有几个模块就隔几次）。
--       代价要说清：/data/rc 会**阻塞**到最后一个模块跑完 —— 这正是要的，
--       先后由 order 决定，不再取决于"谁先抢到 CPU"。
--    6. ★ **闸与安全延时归 /data/rc（本页生成），模块脚本里一个字节都不许有**。
--       2026-10-04 用户原话：「各模块只需要写自己的脚本放到 rc.d 就行，不建议把
--       安全延时等这些重要功能加在模块本身的脚本里，管理器和模块要分开。」
--       理由：闸 / 窗口是**跨模块**的知识 ⇒ 写进模块就会有 N 份互相打架的副本
--       （旧版每个模块各带一个 15s 窗口 ⇒ N 个模块就白等 N×15 秒），改一处漏一处。
--       ⇒ 模块脚本 = 纯命令（set +e / insmod / dd / echo …），判据在 chaos 那侧
--         由 _sim_autostart.py 的 C 组逐行钉死（连 `sleep`/`rm`/`if` 都不许出现）。
--       生成区形状（**只在真有模块行时**发，没模块就不留个空 if 块）：
--         set +e
--         <别人的行…>
--         echo gate_off >> .autorun.log     ← 心跳（在 if 外面）
--         if [ -f .autorun.on ];then
--           rm -f .autorun.on               ← 扣闸
--           sleep 8                         ← 窗口 1（扣闸后、跑模块前）
--           sh …/a.sh                       ← 模块行（两行之间 sleep 1）
--           sh …/b.sh
--           sleep 15                        ← 窗口 2（全跑完之后、放行之前）
--           echo cleared >> .autorun.log
--           echo on > .autorun.on           ← 放行
--         fi
--       ⚠️ 全部落在**已验证的 nsh 子集**里，而且只有**一层 if** —— nsh 没有嵌套 if
--          的实证，这个形状就是**为规避嵌套**才长这样的（判句唯一）。
--
--  ★ 为什么不需要 ko：表盘 Lua 有全权限（io.open 绝对路径 + os.execute）。
--
--  ★ flash 那一段（装/卸开机钩子）是**逐字节**从旧版 chaos 安装器里已上机验证过的
--    实现抽出来的（生成器 manager/tools/_port_flash_to_manager.py 自带逐字节判据）。
--    四道门一个都不许松：固件版本 / 载荷自检 / 写前三段逐字节 / 写后回读。
--    那是**唯一能刷砖设备的能力**，所以它是两段式（按两次才动手）。
--
--  ★ 两条本机已知的坑：
--    - Lua 运行时**没有 popen**，命令输出只能重定向到临时文件再读回来。
--    - nsh 是子集解释器：`&&` `||` `$()` `[ -e ]` 没证据，`for`/通配未验。
--      所以 /data/rc 一律**显式生成 N 行**，绝不靠循环遍历目录。
--      ★ 生成区用到的 `set +e` / `if [ -f … ];then` / `fi` / `sleep` / `sh`
--        都在已验证子集里（照 chaos 的 rc 骨架）。
-- ============================================================================

local lvgl = require("lvgl")

-- ===================== 配色（照 Shell++ II，逐色相同）=====================
local C_BG    = 0x07111F   -- 页面底
local C_CARD  = 0x0D1D31   -- 卡片 / 列表行
local C_LINE  = 0x244566   -- 1px 边框
local C_TXT   = 0xFFFFFF   -- 主文
local C_DIM   = 0x9DB7D8   -- 次文
local C_TXT3  = 0x7E93AE   -- 弱化文（状态行）
local C_RED   = 0x8C1E1E   -- 主操作 / 危险
local C_GREEN = 0x2E6B2E   -- 允许
local C_BLUE  = 0x1E4D8C   -- 导航
local C_DRED  = 0x6B3C3C   -- 禁止
local C_SLATE = 0x3C526B   -- 中性 / 返回键
local C_OLIVE = 0x6B5A1E   -- 日志
local C_GRAY  = 0x4A4A52   -- core（不可操作）

local F_BODY = "MiSans-Regular"
local F_BOLD = "MiSans-Demibold"

local W, H = 336, 480
local PAGE_HIDE = 2000

-- ===================== 路径 =====================
-- ★ 管理器是**独立项目**：自己的日志/临时件只许落在 `/data/10pro.autorun/` 下。
--   借别人的目录（这里曾经是 `/data/chaos`）会让"谁写的这份日志"变成要靠猜的事，
--   而且别人的模块卸载/清理时可能顺手把它删掉。
local DATA_DIR  = "/data/10pro.autorun"
local TEMP_LIST = DATA_DIR .. "/.ls.tmp"          -- 命令输出的中转（没有 popen）
local MGR_LOG   = DATA_DIR .. "/manager.log"

local RC_PATH   = "/data/rc"                      -- ★ 生成物（flash hook 跑的就是它）
local RC_DIR    = "/data/rc.d"                    -- ★ 注册目录
local GEN_LINE  = "sh " .. RC_DIR .. "/"          -- 生成区的行前缀（别人的行不会有这个）

-- ★ 总开关（自启动页 [3 开启]/[4 关闭]）：它只是个**文件在不在**。
--   生成区把模块行整个包在 `if [ -f 它 ];then … fi` 里 —— 关掉 = 删掉这个文件，
--   模块行一条都不跑，而**逐模块的 allow/deny 状态一个字节都不动**（可逆、可审计）。
--   ★ 这个写法不是我编的：chaos 的 rc 骨架就是 `if [ -f /data/chaos/autostart.on ];then`
--     + 收尾 `fi`，已在设备上跑过（AUTOSTART-GUIDE §4.4）。
local GATE      = RC_DIR .. "/.autorun.on"
-- ★ 用户**显式关过总开关**的持久凭据（2026-10-04 修 bug）。
--   为什么必须有它：ensure_gate 原来拿「/data/rc 里有没有 IF_LINE」当「这台是不是
--   从没建过总开关的老设备」的判据 —— 而 IF_LINE 是 build_rc 在 **#run > 0** 时才写的，
--   它是「**有没有模块在跑**」的函数，与「用户关没关过总开关」毫无关系。
--   于是这条链会把用户设的「关」弄丢：
--     [4 关闭](删 GATE; rc 里那道门是刻意留着的, 一切字节未动)
--       -> 模块页【禁止】某模块 -> [重建] -> run 变空 -> **门从 rc 里消失**
--       -> 【启用】该模块 -> [重建] -> ensure_gate 判成"老设备" -> **静默补建 GATE(默认开)**
--   有了这个凭据，「关」才是可信任的；[3 开启] / [1 安装] 会把它撤掉。
--   （`.off` / `.on` 都不匹配模块名正则 `^[%w_%-]+%.sh$`，不会被 load_slices 当成模块。）
local GATE_OFF  = RC_DIR .. "/.autorun.off"
local IF_LINE   = "if [ -f " .. GATE .. " ];then"
local FI_LINE   = "fi"
local SLEEP_LINE = "sleep 1"                      -- ★ 两个模块行之间那一秒（见不变量 5）

-- ★★ 闸的运行时（2026-10-04 用户新方案）：闸的**扣与放**、两个安全窗口、心跳日志，
--    全部由 /data/rc 这一层承担 —— 模块脚本里一个字节都不许有（不变量 6）。
--    ⇒ 开机被打断时闸停在【关】，下一次开机一条模块行都不跑（防砖）。
--    ⚠️ 这些行**外面一层 if** 包着，只有 `HB_LINE` 在 if 外面（闸关着也要留痕）。
local AS_LOG     = RC_DIR .. "/.autorun.log"      -- 心跳日志（本页只读，见文件头）
local HB_LINE    = "echo gate_off >> " .. AS_LOG  -- 心跳：在 if 外面
local CLEAR_LINE = "echo cleared >> " .. AS_LOG   -- 跑到底才写它
local RM_GATE    = "rm -f " .. GATE               -- 扣闸
local ON_GATE    = "echo on > " .. GATE           -- 放行（echo > 是 chaos 骨架验过的写法）
local SLEEP_PRE  = "sleep 8"                      -- 窗口 1：扣闸之后、跑模块之前
local SLEEP_POST = "sleep 15"                     -- 窗口 2：全部跑完之后、放行之前

-- 配置文件：**就放在注册目录里**。快应用那条线整个去掉了 ——
-- 不再需要"沙箱路径 / 兜底路径"两套落点，也不再有"这份编辑器看不见"那种半可用状态。
-- **只有一个落点。**
--   ★ 它不以 `.sh` 结尾，所以 load_slices() 会**无视**它，不会被当成一个模块。
--   ★ CFG_OK = false 时**拒绝重建** —— 否则配置一旦读不到，重建出来的 /data/rc
--     会丢掉全部被禁用的记录（甚至生成空表），把开机链悄悄改掉。
local CFG_FILE  = "autorun.json"
local CFG_PATH  = RC_DIR .. "/" .. CFG_FILE
local CFG_OK    = false

-- 模块页：★ 改成**滚动翻页**（按用户要求，2026-10-04 去掉上一页/下一页）。
-- 本项目的 LVGL Lua 上"动态增删子对象"没验过 ⇒ 行是**预建的固定 ROW_POOL 行**，
-- 只改文本与颜色；容器可滚，一屏放得下 ROWS_VISIBLE 行（几何见 UI 段）。
local ROW_POOL      = 12                          -- 预建行数（= 能显示的模块上限）
local ROWS_VISIBLE  = 6                           -- 一屏可见行数
local ROW_H, ROW_GAP = 50, 6                      -- 行高 / 行间距

-- 主页/自启动页那两个「铺满下屏」的日志框：
-- ★ 行数**各按自己的高度算**（2026-10-04 用户要求「把日志显示范围延长，到框的底部」）。
--   高度 h 在 UI 段传给 make_mini_box，那边用 mini_lines_of(h) 算出来（同一个函数，只写一份）。
--   量法：框内可用高 = h − 上下内边距(2×MINI_PAD)；行距按 MINI_LINE_H = 20px 保守估
--   （字号 14，行距 1.4 倍）⇒ 主页 214 → 9 行、自启动页 290 → 13 行。
--   ⚠️ 宁可底部留十几像素空档，也不让最后一行被**切一半** —— 切一半比少显示难查得多。
--      真机上若还空得多，把 MINI_LINE_H 调小（19 会各多一行）。
-- ★ 每条日志再按 MAX_UNITS 折算宽度截断（中文算 2 单位），保证**一行一条不折行**。
local MINI_PAD        = 8                          -- 框内上下内边距（与 make_mini_box 里一致）
local MINI_LINE_H     = 20                         -- 字号 14 的行距（保守估）
local MINI_BOX_H_MAIN = 214                        -- 主页日志框高（UI 段建框时用同一个值）
local MINI_BOX_H_AS   = 290                        -- 自启动页日志框高
local MAX_UNITS       = 36                         -- 36 单位 × 7.5px ≈ 270px < 288px
local function mini_lines_of(h)
  local n = math.floor((h - MINI_PAD * 2) / MINI_LINE_H)
  if n < 1 then n = 1 end
  return n
end

-- ===================== 工具层（照已验证的 chaos 安装器）=====================

local function exec(cmd)
  print("[10pro.autorun] " .. cmd)
  local rc = os.execute(cmd)
  return rc == true or rc == 0
end

-- 读整个小文件。这个 Lua 运行时没有 popen，命令输出全靠重定向到临时文件再读回来。
local function read_all(path, mode)
  if type(io) ~= "table" then return nil end
  local open = io.open
  if type(open) ~= "function" then return nil end
  local fh = open(path, mode or "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

-- 写整个文件并**回读核对**。启动链的文件错一个字节就是"开机什么都不发生"，
-- 而且是静默的 —— 界面看不出来。返回 true, 或 false + 原因。
local function write_file(path, body)
  local f = io.open(path, "wb")
  if not f then return false, "打不开 " .. path end
  local ok = pcall(f.write, f, body)
  local cok = pcall(f.close, f)
  if not ok or not cok then return false, "写入失败 " .. path end
  if read_all(path) ~= body then return false, "回读不一致 " .. path end
  return true
end

local function exists(path)
  local fh = io.open(path, "rb")
  if fh then fh:close() return true end
  return false
end

-- 截断到一行。★ 必须按**字符**边界截，不能按字节：
-- 中文一个字 3 字节、emoji 4 字节，从中间切开得到的是**非法 UTF-8** ——
-- 设备上渲染成一堆豆腐块，日志里也读不出来。往回退到 UTF-8 首字节（非 10xxxxxx）为止。
local function one_line(text, limit)
  local t = tostring(text or ""):gsub("[\r\n]+", " ")
  limit = limit or 30
  if #t > limit then
    local cut = limit - 1
    while cut > 0 do
      local b = t:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end   -- 到了字符边界
      cut = cut - 1
    end
    t = t:sub(1, cut) .. "…"
  end
  return t
end

-- 宽度感知截断：中文（3 字节）算 2 个单位、ASCII 算 1 个、4 字节 emoji 也算 2 个。
-- ★ 为什么不能用 one_line(n) 顶：它按**字节**截，同一行里中文越多截出来的越短/越长
--   （24 字节 = 8 个汉字或 24 个 ASCII），下屏那个日志框就没法保证"一行一条不折行"。
--   单位换算：字号 14 时 1 个单位 ≈ 7.5px ⇒ 36 单位 ≈ 270px < 框内可用 288px。
local function one_line_w(text, units)
  local t = tostring(text or ""):gsub("[\r\n]+", " ")
  units = units or MAX_UNITS
  local w, cut = 0, #t
  for i = 1, #t do
    local b = t:byte(i)
    if b >= 0xE0 then w = w + 2          -- 3/4 字节字符的头字节
    elseif b >= 0x80 then w = w          -- 续字节不计数
    else w = w + 1 end
    if w > units then
      cut = i - 1
      while cut > 0 do
        local pb = t:byte(cut + 1)
        if pb and pb >= 0x80 and pb < 0xC0 then cut = cut - 1 else break end
      end
      break
    end
  end
  if cut >= #t then return t end
  return t:sub(1, cut) .. "…"
end

-- 把命令输出按空白切成词。对"一列"和"多列对齐"两种形态都成立（nsh 的 ls 形态未验）。
local function tokens(raw)
  local out = {}
  for tok in tostring(raw or ""):gmatch("%S+") do out[#out + 1] = tok end
  return out
end

local function exec_capture(cmd, out_path)
  out_path = out_path or TEMP_LIST
  exec(cmd .. " > " .. out_path)
  local raw = read_all(out_path, "r")
  exec("rm -f " .. out_path)
  return raw or ""
end

-- ===================== 极简 JSON =====================
-- 运行时没有 JSON 库，自己带一份。只支持 JSON 的完整子集：
-- 对象 / 数组 / 字符串(含 \u 与代理对) / 数 / true / false / null。
-- 输出是**稳定**的（键排序 + 2 空格缩进），所以"内容没变"能被逐字节判出来。

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
                     0x80 + math.floor(cp / 0x1000) % 0x40,
                     0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local JSON_ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["/"] = "/",
                   ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
                   ["\r"] = "\\r", ["\t"] = "\\t" }

-- ★ 解码表必须与编码表**分开**。它们是反向映射，拿编码表去解码的后果是：
--     `\"` 解出来还是 `\"`（反斜杠留着）、`\\` 解出来变成 `\\`（翻倍）
--   => 配置里只要有一个引号或反斜杠，每读写一轮就多一层转义，几轮之后文件就废了。
--   而且它是**静默**的：文件依然是合法 JSON，只是内容悄悄变了。
local JSON_UNESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                     b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- ★ 逐字节转义，**不用模式匹配**。原因有两个：
--   1. `%z`（表示 \0 的字符类）在 Lua 5.2 起已废弃、5.4 直接没有 —— 用了就是语法期
--      或运行期报错，设备上的 Lua 版本我们没有保证。
--   2. 待转义的正是"控制字符"，用 gsub + 字符类去匹配控制字符，本身就有 \0 边界问题。
--   手写循环慢一点，但跨版本同行为，且 \0 一定被转成 \u0000。
local function json_escape(s)
  s = tostring(s)
  local out, n = {}, #s
  for i = 1, n do
    local c = s:sub(i, i)
    local e = JSON_ESC[c]
    if e then
      out[#out + 1] = e
    else
      local b = c:byte()
      if b < 0x20 then out[#out + 1] = string.format("\\u%04x", b)
      else out[#out + 1] = c end
    end
  end
  return table.concat(out)
end

local function json_parse(s)
  local pos, n = 1, #s
  local function fail(msg) error("json@" .. pos .. ": " .. msg, 0) end
  local function skip()
    local a, b = s:find("^[ \t\r\n]+", pos)
    if a then pos = b + 1 end
  end

  local function parse_str()
    pos = pos + 1                             -- 跳过开引号
    local out = {}
    while true do
      if pos > n then fail("字符串未闭合") end
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1 return table.concat(out) end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        if e == "u" then
          local hex = s:sub(pos + 2, pos + 5)
          local cp = tonumber(hex, 16)
          if not cp or #hex ~= 4 then fail("\\u 转义非法: " .. hex) end
          pos = pos + 6
          -- 代理对: 高代理后面紧跟低代理，合成一个码点
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          out[#out + 1] = utf8_char(cp)
        else
          if not JSON_UNESC[e] then fail("未知转义 \\" .. e) end
          out[#out + 1] = JSON_UNESC[e]
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end

  local parse_v
  parse_v = function()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local o = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return o end
      while true do
        skip()
        if s:sub(pos, pos) ~= '"' then fail("对象键必须是字符串") end
        local k = parse_str()
        skip()
        if s:sub(pos, pos) ~= ":" then fail("对象缺 :") end
        pos = pos + 1
        o[k] = parse_v()
        skip()
        local d = s:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "}" then pos = pos + 1 return o
        else fail("对象里缺 , 或 }") end
      end
    elseif c == "[" then
      pos = pos + 1
      local a = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return a end
      while true do
        a[#a + 1] = parse_v()
        skip()
        local d = s:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "]" then pos = pos + 1 return a
        else fail("数组里缺 , 或 ]") end
      end
    elseif c == '"' then
      return parse_str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
      if not num or num == "" then fail("不认识的记号 " .. c) end
      pos = pos + #num
      return tonumber(num)
    end
  end

  local v = parse_v()
  skip()
  return v
end

local function json_decode(s)
  if type(s) ~= "string" or #s == 0 then return nil, "空内容" end
  local ok, v = pcall(json_parse, s)
  if not ok then return nil, tostring(v) end
  if type(v) ~= "table" then return nil, "顶层不是对象" end
  return v
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return false end                -- 空表按对象输出 {}
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local json_encode
json_encode = function(v, ind)
  ind = ind or ""
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then return '"' .. json_escape(v) .. '"' end
  if t ~= "table" then return "null" end

  local sub = ind .. "  "
  if is_array(v) then
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = sub .. json_encode(v[i], sub) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
  end
  local ks = {}
  for k in pairs(v) do ks[#ks + 1] = k end
  table.sort(ks)
  if #ks == 0 then return "{}" end
  local parts = {}
  for _, k in ipairs(ks) do
    parts[#parts + 1] = sub .. '"' .. json_escape(tostring(k)) .. '": '
      .. json_encode(v[k], sub)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

-- ===================== 日志 =====================
-- 三个去处：日志页那份全文（可滚）、主页与自启动页那两个「铺满下屏」的小窗。
-- ★ 两个小窗共用同一份**尾巴**（tail_lines），所以它是 forward-declared local ——
--   下面 log_append / log_restore 都要引用它，而它们写在 tail_lines 赋值之前。
--   顺序错了（先写 `local function tail_lines`）就会变成两个不同的变量，静默失效。
local log_lines, log_seq = {}, 0
local log_label, mini_log_label, as_log_label, status_label
local tail_lines
-- 两个小窗各自能放几行（UI 段建框时算出来，见 mini_lines_of）
local mini_lines_main, mini_lines_as
-- 自启动页那个框**上半部分**的状态摘要（照 shellpp2 的自启动页）。
-- ★ 它**不在 log_append 里重算** —— 里面有一项要读 flash（"是否安装"），
--   只能由 refresh_as_state() 在明确时刻刷（开机 / 进自启动页 / 装·卸·开关之后）。
local AS_STATE = {}

local function log_persist(line)
  local f = io.open(MGR_LOG, "a")
  if f then f:write(line .. "\n") pcall(f.close, f) end
end

-- 最近 n 条（每行先按像素宽度截断 ⇒ 每条**恰好占一行**，见 one_line_w 的换算）。
local function tail_list(n)
  if #log_lines == 0 then return { "(就绪)" } end
  local out, from = {}, #log_lines - n + 1
  if from < 1 then from = 1 end
  for i = from, #log_lines do out[#out + 1] = one_line_w(log_lines[i], MAX_UNITS) end
  return out
end
tail_lines = function(n) return table.concat(tail_list(n), "\n") end

-- 自启动页那个框的内容 = **状态摘要** + 一行分隔 + 最近日志。
-- ★ 2026-10-04 用户要求：「把自启动页面日志内容改成 shellpp2 那样 —— 显示开关状态、
--   是否安装、模块状态（安装几个，启动几个）等」，同时「显示范围延长到框的底部」。
--   所以做成"上面状态、下面日志"，总行数**恰好**等于框能放的行数 n ⇒ 一直铺到框底。
--   （shellpp2 的自启动页也只有状态；这里把日志尾巴接在下面，是为了同时满足"铺到框底"。）
-- ★ 状态摘要本身就比框高时，只显示状态，不硬塞日志。
local function as_box_text(n)
  local out = {}
  for i = 1, #AS_STATE do
    if #out >= n then break end
    out[#out + 1] = one_line_w(AS_STATE[i], MAX_UNITS)
  end
  local room = n - #out - 1
  if room >= 1 then
    out[#out + 1] = "-- 日志 --"
    local tail = tail_list(room)
    for i = 1, #tail do out[#out + 1] = tail[i] end
  end
  return table.concat(out, "\n")
end

-- ★ 两个小窗**不再显示同一份文本**：主页是纯日志（铺到框底），自启动页是"状态 + 日志"。
--   颜色仍跟着最近一条日志走（一个 Label 只能一个颜色）—— 那次操作成功还是失败，
--   两个页面都一眼看得出。
local function log_mini(color)
  local c = color or C_DIM
  if mini_log_label then
    mini_log_label:set { text = tail_lines(mini_lines_main or 6), text_color = c }
  end
  if as_log_label then
    as_log_label:set { text = as_box_text(mini_lines_as or 6), text_color = c }
  end
end

local function log_append(text, color)
  log_seq = log_seq + 1
  local line = string.format("%02d  %s", log_seq % 100, tostring(text))
  log_lines[#log_lines + 1] = line
  while #log_lines > 200 do table.remove(log_lines, 1) end
  if log_label then
    log_label:set { text = table.concat(log_lines, "\n"), text_color = color or C_DIM }
  end
  log_mini(color)
  log_persist(line)
  print("[10pro.autorun] " .. line)
end

local function log_restore()
  exec("mkdir -p " .. DATA_DIR)
  local raw = read_all(MGR_LOG, "r")
  if type(raw) ~= "string" or #raw == 0 then
    log_lines = {}
    return
  end
  local tmp = {}
  for line in raw:gmatch("[^\n]+") do tmp[#tmp + 1] = line end
  while #tmp > 60 do table.remove(tmp, 1) end
  log_lines = tmp
  if log_label then
    log_label:set { text = table.concat(tmp, "\n"), text_color = 0xFFD27A }
  end
  log_mini(0xFFD27A)
end

-- ★ 2026-10-05 用户定的日志节奏（四拍）：
--   点击按钮 -> 「执行 xxx」-> 命令原始输出（逐行）-> 成功/失败。
--   exec_logged 只包**有副作用的 shell 命令**（dd 写 flash、rm 总开关这类）；
--   辅助性的 mkdir/ls/rm 临时文件不套它 —— 不然日志被水管命令刷屏，主流程反而看不见。
--   纯 Lua 的文件读写（write_file / 配置）由调用方自己给结果行。
local function exec_logged(cmd, label)
  log_append("执行: " .. (label or one_line(cmd, 48)), 0xBFD9FF)
  -- 没有 popen，原始输出全靠重定向到中转文件再读回来（同 exec_capture 的套路；
  -- NuttX nsh 只认 > ，不赌 2>&1）。
  -- os.execute 返回值按 Lua 版本有三副面孔：
  --   5.1: true / nil,"exit",code   5.3+: true / nil,"exit"| "signal",code  部分嵌入: 0/非0
  --   统一吃成 ok + 人类可读的失败原因，别把 "exit nil" 打到用户脸上。
  local out_path = TEMP_LIST
  local rc, how, code = os.execute(cmd .. " > " .. out_path)
  local raw = read_all(out_path, "r")
  exec("rm -f " .. out_path)
  if type(raw) == "string" and #raw > 0 then
    local n = 0
    for line in raw:gmatch("[^\r\n]+") do
      n = n + 1
      if n <= 8 then log_append("| " .. one_line(line, 60)) end
    end
    if n > 8 then log_append("| ... (共 " .. n .. " 行, 截断)") end
  end
  local ok = rc == true or rc == 0
  local fail_msg = "失败"
  if not ok then
    if type(rc) == "number" then fail_msg = "失败 (exit " .. rc .. ")"
    elseif code ~= nil then fail_msg = "失败 (" .. tostring(how) .. " " .. tostring(code) .. ")"
    end
  end
  log_append(ok and "成功" or fail_msg, ok and 0x8FF0A4 or 0xFF9A9A)
  return ok
end

-- ===================== 逻辑层 =====================

-- 确保配置文件在。**只有一个落点**（注册目录里的 autorun.json），没有兜底路径。
--   ① 文件已在      -> 直接用，一个字节都不动
--   ② 目录/文件不在 -> mkdir -p 建目录 + 落一份空配置
--   ③ 建不出来      -> 返回 false。调用方必须**拒绝重建**（不要把半套状态写进 /data/rc）
-- ★ 不能用"exists(目录)"判 mkdir 成功：NuttX 上 open() 开目录返回 -6(ENXIO)，
--   io.open 会返回 nil，于是"目录明明建好了"也会被判成失败。直接试**写文件**才对。
-- ★ 不再有"降级到兜底"：两套落点意味着"改哪个才是真源"要额外裁决，
--   而且兜底那份在界面上永远是"你没在改你以为在改的那份"。一个落点，失败就明说失败。
local function ensure_config()
  if exists(CFG_PATH) then return true end
  exec("mkdir -p " .. RC_DIR)
  local body = json_encode({ version = 1, modules = {} }) .. "\n"
  if write_file(CFG_PATH, body) then return true end
  return false
end

-- 扫注册目录: /data/rc.d/*.sh -> 名字列表（排序）
-- ★ 同一个目录里还躺着 autorun.json —— 它不匹配 `^[%w_%-]+%.sh$`，所以**看不见**。
--   这不是巧合：配置文件的后缀故意选 `.json` 而不是 `.sh`，就不会被当成模块。
local function load_slices()
  local names, seen = {}, {}
  local raw = exec_capture("ls " .. RC_DIR)
  for _, tok in ipairs(tokens(raw)) do
    local n = tok:match("^([%w_%-]+)%.sh$")
    if n and not seen[n] then seen[n] = true names[#names + 1] = n end
  end
  table.sort(names)
  return names
end

-- /data/rc 里"生成行"引用的模块名（`sh /data/rc.d/<name>.sh` -> name）。
--
-- ★ 为什么需要它（2026-10-04 用户要求）：
--   「缺脚本」这个状态**只**在这条成立时出现 —— /data/rc 里**还留着那一行**，
--   而 /data/rc.d/<name>.sh **不在**了。以前是拿配置登记去判的（配置里有、文件没有
--   ⇒ 缺脚本），结果"用户早就不用的模块"会一直挂在列表里，永远显示缺脚本，
--   怎么按 [重建] 都消不掉（因为它压根不在 rc 里）。现在改成看 /data/rc：
--   ★ [重建] 只为 **present** 的模块出行 ⇒ 悬空行**天然被删掉** ⇒ 那条缺脚本
--     在下次刷新时就自己没了。这就是用户要的"按重建把多余的 rc 脚本删掉"。
local function refs_from_rc()
  local names, seen = {}, {}
  local cur = read_all(RC_PATH)          -- 读不到就当没有（不写盘，只读）
  if type(cur) == "string" then
    for line in cur:gmatch("[^\n]+") do
      local t = line:gsub("^%s+", ""):gsub("%s+$", "")
      if t:sub(1, #GEN_LINE) == GEN_LINE then
        local n = t:sub(#GEN_LINE + 1):match("^([%w_%-]+)%.sh$")
        if n and not seen[n] then seen[n] = true names[#names + 1] = n end
      end
    end
  end
  table.sort(names)
  return names
end

-- 读策略文件。空/坏都当空配置（不报错，交给界面上屏），但**调用方要据此拒绝重建**：
-- merge() 面对空配置会把所有切片当成"新注册"、默认 enable=true —— 那是**放开**，
-- 而不是**禁用**，所以就算读坏了也不至于把开机链清空；但"被禁用过的"记录会丢。
-- 所以规则是：读不到/读坏了 -> 先把它**逐字节备份**出来，再当空配置往下走。
local function load_policy(path)
  local raw = read_all(path, "r")
  if type(raw) ~= "string" or #raw == 0 then return { version = 1, modules = {} }, nil end
  local t, err = json_decode(raw)
  if not t then
    -- 坏配置不静默丢弃：留一份原样副本，便于事后看"当时到底写了什么"。
    write_file(CFG_PATH .. ".bad", raw)
    return { version = 1, modules = {} }, err
  end
  if type(t.modules) ~= "table" then t.modules = {} end
  t.version = tonumber(t.version) or 1
  for k, v in pairs(t.modules) do
    if type(v) ~= "table" then t.modules[k] = { enable = true } end
  end
  return t, nil
end

local function default_policy(name)
  return { core = false, delay = 0, desc = "", enable = true, order = 100, _n = name }
end

-- 合并：列表来源 = **rc.d 里的 .sh** ∪ **/data/rc 里的生成行引用**。
--
-- ★ 2026-10-04 用户要求（"没有安装就不显示 / 缺脚本只在 rc 有行时显示"），
--   所以列表来源改了 **两次**：
--     —— 不再有"配置登记过就显示"这条。**配置只提供 enable/core/order/desc**，
--        不决定"这一行显不显示"。以前配置里的陈年条目会一直挂在列表上显示
--        "缺脚本"，现在不会了（不在 rc.d、也不在 /data/rc ⇒ 根本不进列表）。
--     —— 加了 `/data/rc` 生成行这一路来源 ⇒ 只在那一种情况下显示"缺脚本"：
--        文件被删了、但 /data/rc 里那一行还在。按 [重建] 之后那行被删，
--        下次刷新这条就消失 —— 正是用户要的"重建把多余的 rc 脚本删掉"。
--   ⇒ 两边都空（rc.d 里一个 .sh 都没有、/data/rc 里也没有生成行）时列表为空，
--     模块管理页**什么都不显示**（"没安装"就是这个样子）。
-- 返回：排序后的列表 / "配置要不要回写" / "缺脚本条数"。
local function merge(slices, refs, policy)
  local mods = policy.modules or {}
  local present, ref = {}, {}
  for _, n in ipairs(slices) do present[n] = true end
  for _, n in ipairs(refs or {}) do ref[n] = true end
  local names, seen = {}, {}
  for _, n in ipairs(slices) do
    if not seen[n] then seen[n] = true names[#names + 1] = n end
  end
  for _, n in ipairs(refs or {}) do
    if not seen[n] then seen[n] = true names[#names + 1] = n end
  end
  local list, changed, missing = {}, false, 0
  for _, n in ipairs(names) do
    local p = mods[n]
    if type(p) ~= "table" then
      p = default_policy(n)
      -- 只给**文件在**的新切片补登记（那是真的"新装了一个模块"）。
      -- 只有 rc 引用的（文件已经不在）不落进配置：它是"残留的一行"，
      -- 按 [重建] 就该被清掉，不该反过来在配置里生根。
      if present[n] then mods[n] = p changed = true end
    end
    local is_present = present[n] == true
    if not is_present then missing = missing + 1 end
    list[#list + 1] = {
      name    = n,
      enable  = p.enable == true,
      core    = p.core == true,
      order   = tonumber(p.order) or 100,
      delay   = tonumber(p.delay) or 0,
      desc    = tostring(p.desc or ""),
      present = is_present,
      ref     = ref[n] == true,
    }
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  return list, changed, missing
end

-- 摘出 /data/rc 里"别人的行"（逐行，原样，不含生成区与 set +e）
--
-- ★ 生成区**不止一种行**（2026-10-04 加上闸与串行之后，见不变量 6）：
--     sh /data/rc.d/x.sh            ← 生成行（前缀 GEN_LINE）
--     echo gate_off >> …            ← 心跳（HB_LINE，在 if **外面**）
--     if [ -f … ];then              ← 门（IF_LINE，一整行一字不差）
--     rm -f …/.autorun.on           ← 扣闸（RM_GATE）
--     sleep 8                       ← 窗口 1（SLEEP_PRE）
--     sleep 1                       ← **只在两行生成行之间**才算我们的
--     sleep 15                      ← 窗口 2（SLEEP_POST）
--     echo cleared >> …             ← CLEAR_LINE
--     echo on > …/.autorun.on       ← 放行（ON_GATE）
--     fi                            ← 收尾（FI_LINE）
--   判据刻意写成"逐行 + 局部邻接"，不是"从第一个生成行删到最后一个"：
--   后者会把别人插在生成区中间的行一起吃掉，那就破了不变量 1。
--   ★ 带路径 / 我们专有字样的那几句（IF / HB / RM / CLEAR / ON）**整行一字不差**比对
--     —— 别人写不出第二条一模一样的；只有 `fi` 和三个 `sleep N` 是**通用词**，
--     所以它们必须靠"紧挨着我们自己的行、且上下文对得上"才算我们的。
--     ⚠️ 宁可**漏收**（把我们的行判成别人的 ⇒ 重建时它排到前面，内容仍对、只是顺序散开），
--       也不能**误收**（把别人的 `sleep 15` 吃掉 ⇒ 破不变量 1）。
local function split_others(cur)
  local lines, n = {}, 0
  for line in tostring(cur or ""):gmatch("[^\n]+") do n = n + 1 lines[n] = line end
  local function lead(s)
    return (s:gsub("^%s+", "")):gsub("%s+$", "")
  end
  local function isgen(s)
    return s ~= nil and s:sub(1, #GEN_LINE) == GEN_LINE
  end
  -- 第一遍：整行可辨认的（生成行前缀 + 我们专有那几句）
  local mine = {}
  for i = 1, n do
    local t = lead(lines[i])
    if isgen(t) or t == IF_LINE or t == HB_LINE or t == RM_GATE
      or t == CLEAR_LINE or t == ON_GATE
    then mine[i] = true end
  end
  -- 第二遍：通用词（fi / 三个 sleep N）只有在**上下文是我们自己**时才算我们的。
  for i = 1, n do
    if not mine[i] then
      local t = lead(lines[i])
      local prev = mine[i - 1] and lead(lines[i - 1]) or nil
      local nxt = mine[i + 1] and lead(lines[i + 1]) or nil
      if t == SLEEP_LINE and isgen(prev) and isgen(nxt) then
        mine[i] = true                                    -- 两行模块行之间那一秒
      elseif t == FI_LINE and prev ~= nil then
        mine[i] = true                                    -- 收尾：紧跟在我们自己的行后
      elseif t == SLEEP_PRE and prev == RM_GATE and isgen(nxt) then
        mine[i] = true                                    -- 窗口 1
      elseif t == SLEEP_POST and isgen(prev) and nxt == CLEAR_LINE then
        mine[i] = true                                    -- 窗口 2
      end
    end
  end
  local others = {}
  for i = 1, n do
    if not mine[i] then
      local t = lead(lines[i])
      if #t > 0 and t ~= "set +e" then others[#others + 1] = t end
    end
  end
  return others
end

-- 生成 /data/rc 全文。别人的行**原样保留**（这是"绝不丢东西"的那条不变量）。
-- ★ 生成区形状（不变量 5 + 6）：心跳 → 门 → 扣闸 → 窗口1 → 模块行（之间夹 sleep 1）
--   → 窗口2 → cleared → 放行 → 收尾 fi。
--   ★ 只在**真的有模块行**时才发 —— 一个模块都不跑的时候，留个空 if 块
--     （配上一对 sleep + 一次扣闸放闸）没有意义，还会白白阻塞开机 23 秒。
--   ★ 顺序不能调：`rm`（扣闸）必须在模块行**之前** —— 它就是防砖的全部依据；
--     `echo on >`（放行）必须在 `sleep 15` **之后** —— 那是"全部模块都加载且过了 15 秒"。
--   ★ 心跳在 `if` **外面**：闸关着时它也写 ⇒ 日志上能分清"没跑到"和"跑了但闸关"。
-- ★ 重建会**删掉多余的行**（2026-10-04 用户要求）：run 只收 `present` 的模块 ⇒
--   上一份 /data/rc 里指向"已经不存在的脚本"的那一行不会被重新写出来 ⇒ 天然被清掉。
--   这是刻意的：只有 **enable && present** 才出行（禁止 = 那行不出现，不变量 3）。
local function build_rc(list, others)
  local L = { "set +e" }
  for _, line in ipairs(others) do L[#L + 1] = line end
  local run = {}
  for _, m in ipairs(list) do
    if m.enable and m.present then run[#run + 1] = GEN_LINE .. m.name .. ".sh" end
  end
  if #run > 0 then
    L[#L + 1] = HB_LINE
    L[#L + 1] = IF_LINE
    L[#L + 1] = RM_GATE                            -- 扣闸：跑不完就一直是关的
    L[#L + 1] = SLEEP_PRE                          -- 窗口 1
    for i = 1, #run do
      if i > 1 then L[#L + 1] = SLEEP_LINE end     -- 上一个跑完，停 1 秒再跑下一个
      L[#L + 1] = run[i]                           -- ★ 不带 & ：同步跑，不后台
    end
    L[#L + 1] = SLEEP_POST                         -- 窗口 2
    L[#L + 1] = CLEAR_LINE                         -- 它的缺席 = 上次被打断的唯一证据
    L[#L + 1] = ON_GATE                            -- 放行：闸加回来
    L[#L + 1] = FI_LINE
  end
  return table.concat(L, "\n") .. "\n"
end

-- /data/rc 到底**在不在**？ -- 只在 `io.open` 读失败时才问这个。
-- ★ 为什么需要它：`io.open(path,"rb")` 返回 nil 时**分不清**"文件不存在"和"文件在但打不开"
--   （本运行时不给 errno）。而这两种情况的处置**完全相反**：
--     不存在   ⇒ 别人的行 = 0，要把它**建出来**（新设备上本来就没有 /data/rc）；
--     存在读不到 ⇒ 重建会把别人的行抹掉 ⇒ **必须拒绝**（不变量 1）。
--   `ls <目录>` 是本项目已经在用、且在设备上验过的探针（load_slices 就靠它），
--   按**整词**比对 `rc` —— `rc.d` 是另一个词，不会误判。
--   返回 true / false / **nil（连列目录都没拿到 => 不知道）**。
local function rc_present_by_ls()
  exec("ls /data > " .. TEMP_LIST)
  local raw = read_all(TEMP_LIST, "r")
  exec("rm -f " .. TEMP_LIST)
  -- 空串 = 输出没拿到（/data 里至少得有 rc.d，不可能真空）⇒ 当成"不知道"
  if type(raw) ~= "string" or #raw == 0 then return nil end
  for _, tok in ipairs(tokens(raw)) do
    if tok == "rc" then return true end
  end
  return false
end

-- rc 状态：生成 N 行（模块行数）。别人的行数**走同一个 split_others** ——
-- ★ 不能在这里自己再写一套"非生成行就算别人的"：那样 if/fi/sleep 会被算成
--   "别人的行"，状态行立刻就开始说假话（"生成 2 别人 3"）。
local function rc_state()
  local cur = read_all(RC_PATH)
  if type(cur) ~= "string" then
    if rc_present_by_ls() == false then return "无", 0, 0 end
    return "读不到", 0, 0
  end
  local gen = 0
  for line in cur:gmatch("[^\n]+") do
    local t = line:gsub("^%s+", "")
    if t:sub(1, #GEN_LINE) == GEN_LINE then gen = gen + 1 end
  end
  return "可读", gen, #split_others(cur)
end

-- 总开关现在开着没有。
local function gate_on()
  return exists(GATE)
end

-- 心跳日志（/data/rc 写的）的**末行**。返回 "cleared" / "gate_off" / nil。
-- ★ 这是**只读**的旁证，绝不参与写决策以外的地方：
--     "cleared"  = 上一次开机把模块跑完了、闸也放回来了；
--     "gate_off" = 闸此刻是【关】（被开机脚本扣住了 / 用户关过 / 上次被打断）；
--     nil        = 没有这个文件或读不到 ⇒ **当成"没有证据"**，不许拿它去推断。
--   ★ 为什么末行就够：/data/rc 一次开机最多写两行（先 gate_off，跑到底再 cleared）。
local function log_last()
  local raw = read_all(AS_LOG, "r")
  if type(raw) ~= "string" then return nil end
  local last = nil
  for line in raw:gmatch("[^\n]+") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if #t > 0 then last = t end
  end
  return last
end

-- 总开关缺了就补建（默认**开**）。返回 (开关在, 是不是刚建的)。
-- ★ 判据只有一条：**用户有没有显式关过**（GATE_OFF 这个持久凭据）。
--   v0.6.5 删掉了原来那条「`/data/rc` 里有 IF_LINE 就不补建」的判据 —— 它和 v0.6.4
--   修掉的那个 bug 是**同一个错误**：拿 rc 的文本去反推用户意图。而 rc 里那道门是
--   build_rc 在 **#run > 0** 时才写的（= "有没有模块在跑"），并且 [4 关闭] **刻意**
--   把门的文本留在 rc 里（这样开回来才可逆）⇒ "rc 里有门"完全推不出"开关文件该在"。
--   真机后果（2026-10-04）：[4 关闭] 之后按 [1 安装]，前脚刚删掉 GATE_OFF 凭据，
--   再进到这里，看到 rc 里有门 ⇒ 不补 ⇒ 日志说"打开"、实际还是关的 ⇒
--   重建出来的模块行被关在门里 ⇒ **开机不跑 = "自启动不生效"**。
-- ★ 2026-10-04（新方案）又加了第三条：**闸被开机脚本扣住的那一刻**（心跳日志末行
--   `gate_off`）也**绝不补建**。理由与上面同源、但后果严重得多：
--     闸的**扣住状态本身就是防砖**。要是这里"顺手补建"，那么开机被看门狗打断之后，
--     用户按一下 [重建] 闸就回来了，下一次开机又开始跑那批把设备搞崩的模块 ——
--     这道闸等于没有。⇒ 恢复只走**明确动作**：[3 开启] / [1 安装]
--     （它们都会**直接写**总开关，不经过任何推断）。
--   注意这条**不会**挡掉真正的"老设备迁移"：老设备的 /data/rc 从没跑过 ⇒ 没有日志
--   ⇒ log_last() == nil ⇒ 照旧补建（R10 / H13 那两条判据管的就是这个）。
local function ensure_gate()
  if exists(GATE) then return true, false end
  -- 用户显式关过 -> 绝不补建（这条是"关"能被信任的唯一依据）。
  if exists(GATE_OFF) then return false, false end
  -- 闸已被开机脚本扣住 -> 绝不补建（否则防砖作废，见上面那段）。
  if log_last() == "gate_off" then return false, false end
  if write_file(GATE, "on\n") then return true, true end
  return false, false
end

-- ===================== 配置写回 =====================

-- CFG_PATH / CFG_OK / CFG_FILE 已在路径段声明（那里是唯一真源），这里不要重复声明 ——
-- 重复 `local` 会 shadow 掉外层，前面那些函数看到的是旧的那个变量。

local function policy_from(list, version)
  local mods = {}
  for _, m in ipairs(list) do
    -- ★ 只写**文件在**的模块（2026-10-04 起）。理由：新规则下"模块"就是
    --   rc.d 里的那个 .sh；文件不在了，它的策略也就没有意义了，留着只会让
    --   配置越滚越大、还可能把陈年开关状态复活到重新投进来的同名脚本上。
    --   判据：config.modules 的键永远是 {present 的模块} 的子集。
    if m.present then
      mods[m.name] = {
        core = m.core, delay = m.delay, desc = m.desc,
        enable = m.enable, order = m.order,
      }
    end
  end
  return { version = version or 1, modules = mods }
end

local function save_policy(list, version)
  local body = json_encode(policy_from(list, version)) .. "\n"
  local ok, err = write_file(CFG_PATH, body)
  if not ok then return false, err end
  return true
end

-- ===================== 前向声明 =====================
-- ★ 下面这些在**后面的段**才赋值，但前面的函数已经要用到它们。
--   必须在**第一条文本引用之前**声明成 local —— 否则前面那些函数引用的是**全局名**，
--   而后面赋的是**局部名**，两边不是同一个变量，静默失效。表现是"按了没反应"，不报错：
--     armed        -> ["安装"/"卸载"] 的两段式闸门关不掉（退出去再进来，闸门还开着）
--     render_rows  -> 列表不刷新
--     scroll_log_bottom -> 点"日志"变成 nil 调用报错
--     mod_list_top -> 模块页不回列表顶部
--     refresh_as_state -> 自启动页的状态面板不刷新（★ 2026-10-04 加的：
--                      set_gate/do_init_* 在它**前面**就调它了）
--   Lua 的 local 作用域从声明那一行才开始，这是本项目最容易踩的一类坑。
local armed = ""
local scroll_log_bottom
local render_rows
local mod_list_top
local refresh_as_state

-- ===================== 高层动作 =====================

local MODS = {}
local _policy = { version = 1, modules = {} }
-- 上一次 load_policy 的解析错误（nil = 没出错）。只用于上屏，不参与决策：
-- 决策一律走 CFG_OK 那一套，错误信息只是给"配置坏了"留个说法。
local _cfg_err = nil

-- 重新读一遍：确保配置在 -> 读策略 -> 扫切片 -> 合并。返回摘要字符串。
-- ★ 配置**只有一个落点**，所以不再有"落点变了要说一声"那套；
--   但"新建"和"建不出来"这两件事仍然要上屏 —— 前者是"你第一次用"，后者是"现在别信我"。
local function refresh_all(quiet)
  local had = exists(CFG_PATH)
  CFG_OK = ensure_config()
  if not CFG_OK then
    log_append("配置建不出来: " .. CFG_PATH .. " -> 拒绝重建", 0xFF9A9A)
  elseif not had then
    -- "第一次用"一辈子只发生一次，不受 quiet 影响 —— quiet 只是压掉例行噪音。
    log_append("配置已新建: " .. CFG_PATH, 0x8FF0A4)
  end
  _policy, _cfg_err = load_policy(CFG_PATH)
  -- ★ 不受 quiet 影响：quiet 只压例行噪音。"配置坏了"是必须当场看见的事 ——
  --   被压掉的话，用户看到的只是一个"少了几个模块"的列表，而不知道配置没读进来。
  if _cfg_err then
    log_append("配置解析失败(" .. tostring(_cfg_err) .. ") 已留底 .bad", 0xFFD27A)
  end
  local slices = load_slices()
  local refs = refs_from_rc()
  local list, changed, missing = merge(slices, refs, _policy)
  MODS = list
  if changed then
    local ok, err = save_policy(MODS, _policy.version)
    if not quiet then
      if ok then log_append("配置已补登记 " .. #MODS .. " 项", 0x8FF0A4)
      else log_append("配置回写失败: " .. tostring(err), 0xFF9A9A) end
    end
  end
  local on = 0
  for _, m in ipairs(MODS) do if m.enable then on = on + 1 end end
  return string.format("%d 项 · rc.d %d · rc %d · 放开 %d%s",
    #MODS, #slices, #refs, on, missing > 0 and (" · 缺脚本 " .. missing) or "")
end

-- /data/rc 现在是不是**落后于配置**？现算，不存状态。
-- ★ 这是"去掉自动重建"之后必须补上的安全网：自动重建没了，
--   "改了但还没落盘"这件事就必须**看得见**，否则改了开关却什么都不发生，全靠人猜。
--   它就是 build_rc 的定义式比较 —— 内容一致 = 不待重建。
local function rc_pending()
  if not CFG_OK then return true end
  local cur = read_all(RC_PATH)
  if type(cur) ~= "string" then return true end
  return cur ~= build_rc(MODS, split_others(cur))
end

-- 状态行。★ 用 one_line_w(40 单位) 而不是 one_line(60 字节)：状态行这行标签是
-- 定宽 316px 的**单行**（height=24），按字节截断会让中文多的那版折算成 44 单位
-- ⇒ 折成两行 ⇒ 第二行被切掉。"自启开/关"是这一版新加的，正好踩到这条。
local function refresh_status(extra)
  if not status_label then return end
  local st, gen, others = rc_state()
  local text = extra or string.format("rc %s 生成%d 别人%d 自启%s%s",
    st, gen, others, gate_on() and "开" or "关",
    rc_pending() and " ●待重建" or "")
  status_label:set { text = one_line_w(text, 40), text_color = C_TXT3 }
end

-- 重建 /data/rc：别人的行不动，只重建生成区。内容没变就不写盘（幂等）。
-- ★ 每个出口都要 render_rows()：refresh_all 可能**自动补登记**了新切片，
--   不重绘的话模块页会一直显示上一次的旧列表（"脚本都删了还写着允许"）。
-- ★ 配置读写不正常（CFG_OK=false）时**一律拒绝**：这时候 MODS 是空壳，重建出来
--   会是一份"什么都不启动"的 /data/rc —— 那是把开机链悄悄改掉，比不重建危险得多。
local function do_rebuild()
  refresh_all(true)
  if not CFG_OK then
    log_append("拒绝重建: " .. CFG_PATH .. " 建不出来", 0xFF9A9A)
    refresh_status() render_rows()
    return
  end
  -- ★ 总开关文件不在就补建（默认开）；**用户显式关过**（GATE_OFF 凭据）或**闸已经被
  --   开机脚本扣住**（心跳日志末行 gate_off）都**不补** —— 后者是防砖的核心，
  --   见 ensure_gate 上面那段。
  --   不补的话，重建出来的生成区被关在门里、开机一条模块行都不跑；所以界面必须
  --   当场说清"是关的 + 为什么关 + 要开按哪个键"，否则就是静默失效。
  local gok, made = ensure_gate()
  if made then log_append("总开关已补建(默认开): " .. GATE, 0x8FF0A4) end
  if not gok then
    local why = (log_last() == "gate_off") and "上次开机没跑到底, 闸停在扣住状态"
      or (exists(GATE_OFF) and "你关过" or "还没有过")
    log_append("注意: 总开关是关的(" .. why .. ") -> 这次重建出来的模块行不会跑", 0xFFD27A)
    log_append("-> 面板显示 未启动; 要开机自动跑, 请按 [3 开启]", 0xFFD27A)
  end
  -- ★ "不在" 和 "在但读不出来" **必须分开处置**（这是真机上踩到的 bug，2026-10-04）：
  --   不在      ⇒ 别人的行 = 0，**要把它建出来**。新设备上 /data/rc 本来就不存在，
  --               上一版把它当成"读不到"直接 return ⇒ hook 装好了却没有 rc，
  --               开机跑 `sh /data/rc` 必然失败 —— 而日志只留一句"读不到 /data/rc"。
  --   在但读不出 ⇒ 读不到别人的行，重建会把它们**抹掉** ⇒ 拒绝（不变量 1）。
  local cur = read_all(RC_PATH)
  if type(cur) ~= "string" then
    local present = rc_present_by_ls()
    if present == false then
      cur = ""
      log_append(RC_PATH .. " 不在 -> 当成空的, 这次会把它建出来", 0xFFD27A)
    else
      log_append("拒绝重建: " .. RC_PATH .. " 读不出来" ..
        (present == true and " (文件在, 怕抹掉别人的行)" or " (连 ls /data 都没判出来)"),
        0xFF9A9A)
      refresh_status() render_rows()
      return
    end
  end
  local others = split_others(cur)
  local body = build_rc(MODS, others)
  if cur == body then
    log_append("重建: 内容未变, 未写盘 (" .. #others .. " 行别人的)", 0x8FF0A4)
    refresh_status() render_rows()
    return
  end
  local ok, err = write_file(RC_PATH, body)
  if not ok then
    log_append("重建失败: " .. tostring(err), 0xFF9A9A)
    refresh_status() render_rows()
    return
  end
  local wrote = 0
  for _, m in ipairs(MODS) do if m.enable and m.present then wrote = wrote + 1 end end
  -- ★ 必须在下面那条 log_append **之前**刷面板：log_mini 会把当时的文本写进"上屏流水"，
  --   排后面的话「重载: ● 待重建」会先被推上屏一次（真机上闪一下、判据里被咬住）。
  --   /data/rc 已经写完了，所以这里读到的就是新状态。
  refresh_as_state()
  log_append(string.format("已重建 /data/rc: %d 行生成 + %d 行别人的", wrote, #others),
    0x8FF0A4)
  refresh_status() render_rows()
end

-- 【已删除】sync_rc_auto（"打开表盘即对账"）
--   它曾经让 /data/rc 在每次打开管理器时自动跟上配置。**按用户要求去掉了**：
--   自动重建意味着"只要打开一下就能悄悄改掉开机脚本"，而开机脚本是**不可审**的 ——
--   用户看到的是界面，不是 /data/rc。
--   现在写它的地方只有**明说的那几处**：模块页/主页 [重建]、自启动页 [1 安装] 与
--   [3 开启]。（[2 接管] 那条已经整个删掉了，见下面 do_init_* 上面那段注释。）
--   补偿手段是 refresh_status 里的「●待重建」提示 + 改开关后那句"按 [重建自启动] 生效"。

-- 总开关（自启动页 [3 开启] / [4 关闭]）：开启 = 建那个文件；关闭 = 删那个文件。
-- ★ 关闭**不写** /data/rc —— 门就是"文件在不在"，删掉它下次开机整个生成区都不跑。
--   这正好是可审计的地方：逐模块的 allow/deny 一个字节都没动，开回来立刻恢复原样。
local function set_gate(on)
  refresh_all(true)
  if on then
    local ok, err = write_file(GATE, "on\n")
    if not ok then
      log_append("开启失败: " .. tostring(err), 0xFF9A9A)
      refresh_status() return
    end
    exec("rm -f " .. GATE_OFF)      -- ★ 用户显式开过 -> 撤掉"他关过"的凭据
    log_append("自启动总开关: 开 (" .. GATE .. ")", 0x8FF0A4)
    do_rebuild()                       -- 老设备的 /data/rc 里可能还没有那道门
    refresh_as_state()                 -- 开关 + "会跑几个" 都变了
  else
    exec_logged("rm -f " .. GATE, "删除总开关 " .. GATE)
    if exists(GATE) then
      log_append("关闭失败: 删不掉 " .. GATE, 0xFF9A9A)
      refresh_status() return
    end
    -- ★ 留凭据：这是"关"能被信任的唯一依据（见 GATE_OFF 那段注释）。
    --   没有它的话，只要出现"所有模块都不出行"，下一次 [重建] 就会把开关静默打开。
    write_file(GATE_OFF, "off\n")
    log_append("自启动总开关: 关 (已删 " .. GATE .. ")", 0xFFD27A)
    log_append("-> 下次开机不跑任何模块; 逐模块开关没动, 开回来即恢复")
    refresh_status() render_rows()
    refresh_as_state()
  end
end

-- 全部允许 / 全部禁止（core 不动）
local function set_all(want)
  refresh_all(true)
  local n = 0
  for _, m in ipairs(MODS) do
    if not m.core and m.present and m.enable ~= want then
      m.enable = want
      n = n + 1
    end
  end
  if n == 0 then
    log_append(want and "全部启用: 没有需要改的" or "全部禁止: 没有需要改的")
  else
    local ok, err = save_policy(MODS, _policy.version)
    if not ok then log_append("回写失败: " .. tostring(err), 0xFF9A9A)
    else
      log_append((want and "全部启用 " or "全部禁止 ") .. n .. " 项", 0x8FF0A4)
      log_append("-> 配置已改, 按 [2 重建自启动] 才落到 /data/rc", 0xFFD27A)
    end
  end
  refresh_status()
  render_rows()
end

-- 单个模块 允许<->禁止（core 不给动）
local function toggle_mod(name)
  log_append("点击 [模块 " .. name .. "]", 0xBFD9FF)
  for _, m in ipairs(MODS) do
    if m.name == name then
      if m.core then
        log_append("[" .. name .. "] 是核心模块, 不给禁 (要停请用它自己的开关)", 0xFFD27A)
        return
      end
      if not m.present then
        log_append("[" .. name .. "] 没有 " .. RC_DIR .. "/" .. name .. ".sh, 不算注册", 0xFFD27A)
        return
      end
      m.enable = not m.enable
      local ok, err = save_policy(MODS, _policy.version)
      if not ok then
        m.enable = not m.enable
        log_append("回写失败: " .. tostring(err), 0xFF9A9A)
      else
        log_append("[" .. name .. "] -> " .. (m.enable and "允许" or "禁止"),
          0x8FF0A4)
        log_append("-> 配置已改, 按 [2 重建自启动] 才落到 /data/rc", 0xFFD27A)
      end
      refresh_status()
      render_rows()
      return
    end
  end
end

-- 【已删除】do_adopt（[2 接管]，两段式）
--   2026-10-04 按用户要求去掉。理由不只是"少个按钮"：它是**唯一不等 [重建] 就直接
--   写 /data/rc 的路径**，而且会把"别人的行"搬进 /data/rc.d/legacy.sh、登记成 core、
--   顺手把它们的相对先后塞进一个子 shell。现在改成：别人的行**原样留着**，
--   本页只管生成区（不变量 1）。REGISTER.md §5 里"自带 legacy_cleanup() 的模块
--   不需要接管"那句仍然成立 —— 只是管理器不再提供接管入口。

-- ===================== init rc（flash 里那句开机钩子）=====================
-- ★ 下面这一整段是**逐字节**从旧版 chaos 安装器里抽出来的（不自写、不改一个字母）：
--   manager/tools/_port_flash_to_manager.py 把占位符换成源码里那几段，并用 md5
--   双向证明"抽出来的 == 源里的"。抽的是：
--     常量段（FLASH_BS / 四道门的常量 / 三个候选块）
--     + 32KB 内置原块（65,536 个 hex 字符）
--     + 载荷 PAY 的确定性推导（be4 / NUL / HOOKB / HPAD）
--     + flash_adler / flash_read / flash_write / flash_diff_at / flash_three /
--       flash_state / flash_nbr / flash_fw_code / flash_gate / flash_probe /
--       hook_install / hook_restore
--   四道门保持原样：固件版本 / 载荷自检 / 写前三段逐字节 / 写后回读。
--   ⚠️ **不要为了"改文案"动这一段里的任何一个字符** —— 门（PORT-FLASH）判的就是
--      "这一段与源逐字节相同"。段内那条注释说"落在 /data/chaos/apblk.bin"是**过时的**
--      （写它的时候我们的目录还借在 chaos 下），真实路径跟着 DATA_DIR 走 =
--      `/data/10pro.autorun/apblk.bin`。留着不动，比改坏一个字节划得来。
-- ★ 为什么是两段式：这是**唯一能刷砖设备的能力**（改 AP 分区里 rcS 那个 inode）。
--   第一下只探测并报状态（纯读），第二下才写。"再按一次"这句会明写在日志里。
local FLASH_FIRMWARE_CODE = 3101043        -- 内置原块来自 3.101.043
local FLASH_BS     = 32768
local FLASH_TEMP   = DATA_DIR .. "/apblk.bin"
local HOOK         = "sh /data/rc &"
local P_SIZE       = 332                   -- 改后 rcS inode size
local P_CK         = 0x8D9C53E2            -- 改后 rcS inode checksum
local HEAD_END     = 0x64EC                -- 前段   [0x0000, HEAD_END)
local BODY_END     = 0x6654                -- 本身段 [HEAD_END, BODY_END)
local WIN_OFF      = 0x6642                -- 末行窗口
local WIN_LEN      = 18
local ORIG_ADLER   = "40877019"
local PAY_ADLER    = "1E4A726D"
local FW_VERSION_PROP = "ro.build.version"
local FW_VERSION_OUT  = DATA_DIR .. "/fwver.tmp"
local FLASH_CAND = {
  { dev = "/dev/ap",        off = 12582912, name = "ap-rel" },
  { dev = "/dev/bes_flash", off = 13369344, name = "flash-abs" },
  { dev = "/dev/bes_flash", off = 12582912, name = "flash-aprel" },
}

-- 内置原块: vela_ap.bin 里 AP /etc ROMFS 所在那个 32KB 块, **原样搬**(65,536 个 hex 字符)。
-- 载荷不另存第二份, 由原块**确定性推导**出来(见下面 PAY) —— 两份数据只会落得"改一处忘一处"。
local ORIG_HEX = ([[
590c00553c696530a5f0fca9c09599cccc9995c0a9fcf0a50c595500693c306565303c690055590c99ccc095fca9a5f0f0a5
a9fc95c0cc9995c0cc99f0a5a9fcfca9a5f099ccc0950055590c65303c69693c30650c59550003010200f889b22c188ab22c
248ab22c308ab22c388ab22c448ab22c4c8ab22c548ab22c608ab22c6c8ab22c000101020102020301020203020303040102
0203020303040203030403040405010202030203030402030304030404050203030403040405030404050405050601020203
0203030402030304030404050203030403040405030404050405050602030304030404050304040504050506030404050405
0506040505060506060701020203020303040203030403040405020303040304040503040405040505060203030403040405
0304040504050506030404050405050604050506050606070203030403040405030404050405050603040405040505060405
05060506060703040405040505060405050605060607040505060506060705060607060707088401cc2c0102030304040404
05050606060000001098b22c1c98b22c2898b22c3098b22c3c98b22c4898b22c5498b22c00000000963007772c610eeeba51
099919c46d078ff46a7035a563e9a395649e3288db0ea4b8dc791ee9d5e088d9d2972b4cb609bd7cb17e072db8e7911dbf90
6410b71df220b06a4871b9f3de41be847dd4da1aebe4dd6d51b5d4f4c785d38356986c13c0a86b647af962fdecc9658a4f5c
0114d96c0663633d0ffaf50d088dc8206e3b5e10694ce44160d5727167a2d1e4033c47d4044bfd850dd26bb50aa5faa8b535
6c98b242d6c9bbdb40f9bcace36cd832755cdf45cf0dd6dc593dd1abac30d9263a00de518051d7c81661d0bfb5f4b42123c4
b3569995bacf0fa5bdb89eb802280888055fb2d90cc624e90bb1877c6f2f114c6858ab1d61c13d2d66b69041dc760671db01
bc20d2982a10d5ef8985b1711fb5b606a5e4bf9f33d4b8e8a2c9077834f9000f8ea8099618980ee1bb0d6a7f2d3d6d08976c
6491015c63e6f4516b6b62616c1cd83065854e0062f2ed95066c7ba5011bc1f4088257c40ff5c6d9b06550e9b712eab8be8b
7c88b9fcdf1ddd62492dda15f37cd38c654cd4fb5861b24dce51b53a7400bca3e230bbd441a5df4ad795d83d6dc4d1a4fbf4
d6d36ae96943fcd96e34468867add0b860da732d0444e51d03335f4c0aaac97c0ddd3c710550aa41022710100bbe86200cc9
25b56857b3856f2009d466b99fe461ce0ef9de5e98c9d9292298d0b0b4a8d7c7173db359810db42e3b5cbdb7ad6cbac02083
b8edb6b3bf9a0ce2b6039ad2b1743947d5eaaf77d29d1526db048316dc73120b63e3843b64943e6a6d0da85a6a7a0bcf0ee4
9dff099327ae000ab19e077d44930ff0d2a3088768f2011efec206695d5762f7cb67658071366c19e7066b6e761bd4fee02b
d3895a7ada10cc4add676fdfb9f9f9efbe8e43beb717d58eb060e8a3d6d67e93d1a1c4c2d83852f2df4ff167bbd16757bca6
dd06b53f4b36b248da2b0dd84c1b0aaff64a0336607a0441c3ef60df55df67a8ef8e6e3179be69468cb361cb1a8366bca0d2
6f2536e2685295770ccc03470bbbb91602222f260555be3bbac5280bbdb2925ab42b046ab35ca7ffd7c231cfd0b58b9ed92c
1daede5bb0c2649b26f263ec9ca36a750a936d02a906099c3f360eeb8567077213570005824abf95147ab8e2ae2bb17b381b
b60c9b8ed2920dbed5e5b7efdc7c21dfdb0bd4d2d38642e2d4f1f8b3dd686e83da1fcd16be815b26b9f6e177b06f7747b718
e65a0888706a0fffca3b06665c0b0111ff9e658f69ae62f8d3ff6b6145cf6c1678e20aa0eed20dd75483044ec2b303396126
67a7f71660d04d476949db776e3e4a6ad1aedc5ad6d9660bdf40f03bd83753aebca9c59ebbde7fcfb247e9ffb5301cf2bdbd
8ac2baca3093b353a6a3b4240536d0ba9306d7cd2957de54bf67d9232e7a66b3b84a61c4021b685d942b6f2a37be0bb4a18e
0cc31bdf055a8def022d00002110422063308440a550c660e770088129914aa16bb18cc1add1cee1eff13112100273325222
b5529442f772d662399318837bb35aa3bdd39cc3fff3dee36224433420040114e664c774a44485546aa54bb528850995eee5
cff5acc58dd55336722611163006d776f6669556b4465bb77aa719973887dff7fee79dd7bcc7c448e5588668a77840086118
02282338ccc9edd98ee9aff9488969990aa92bb9f55ad44ab77a966a711a500a333a122afddbdccbbffb9eeb799b588b3bbb
1aaba66c877ce44cc55c222c033c600c411caeed8ffdeccdcddd2aad0bbd688d499d977eb66ed55ef44e133e322e511e700e
9fffbeefdddffccf1bbf3aaf599f788f8891a981cab1eba10cd12dc14ef16fe18010a100c230e3200450254046706760b983
9893fba3dab33dc31cd37fe35ef3b1029012f322d2323542145277625672eab5cba5a89589856ef54fe52cd50dc5e234c324
a01481046674476424540544dba7fab79987b8975fe77ef71dc73cd7d326f2369106b01657667676154634564cd96dc90ef9
2fe9c899e9898ab9aba94458654806782768c018e1088238a3287dcb5cdb3feb1efbf98bd89bbbab9abb754a545a376a167a
f10ad01ab32a923a2efd0fed6cdd4dcdaabd8bade89dc98d267c076c645c454ca23c832ce01cc10c1fef3eff5dcf7cdf9baf
babfd98ff89f176e367e554e745e932eb23ed10ef01eff0000007f0000016c6f63616c686f7374000000a09cb22c7b000000
06000000a09cb22c7b0000001100000000000000000000000000000073636865645f64756d70737461636b002f746d702f58
58585858582e746d7000000000000000000000000000000000000a00000064000000e803000010270000a086010040420f00
8096980000e1f505286e756c6c290000000000000080e03779c3314300003426f56bfc420000901ec4bcc642000040e59c30
9242000000a2941a5d42000000e876482742000000205fa0f2410000000065cdbd410000000084d7874100000000d0125341
0000000080841e4100000000006ae840000000000088b3400000000000407f40000000000000494000000000000014409a99
99999999b93f7b14ae47e17a843f2d431cebe2361a3f3a8c30e28e79453ebc89d897b2d29c3c33a7a8d523f649393da7f444
fd0fa5329d978ccf08ba5b25436fac642806c80a00000000000024400000000000005940000000000088c3400000000084d7
97410080e03779c34143176e05b5b5b89346f5f93fe9034f384d321d30f94877825a3cbf737fdd4f15750000000000000000
32000000010000004b000000020000006e0000000300000086000000040000009600000005000000c8000000060000002c01
0000070000005802000008000000b004000009000000080700000a000000600900000b000000c01200000c00000080250000
0d000000004b00000e000000009600000f00000000e100000110000000c20100021000000084030003100000000807000410
000020a107000510000000ca08000610000000100e000710000040420f0008100000009411000910000060e316000a100000
80841e000b100000a02526000c100000c0c62d000d100000e06735000e10000000093d000f100000f498b22c6ca4b22c0899
b22c1099b22cd498b22c2099b22c2899b22c3099b22c3899b22c4499b22c4c99b22c5899b22cc498b22cc898b22ccc98b22c
d098b22cd498b22cd898b22cdc98b22ce098b22ce498b22ce898b22cec98b22cf098b22c8098b22c8898b22c9098b22c9898
b22ca498b22cb098b22cb898b22c6498b22c6898b22c6c98b22c7098b22c7498b22c7898b22c7c98b22c00001f003b005a00
78009700b500d400f300110130014e016d010000c498b22cc898b22ccc98b22cd098b22cd498b22cd898b22cdc98b22ce098
b22ce498b22ce898b22cec98b22cf098b22c6498b22c6898b22c6c98b22c7098b22c7498b22c7898b22c7c98b22c6d010000
6e0100001f0000001c0000001f0000001e0000001f0000001e0000001f0000001f0000001e0000001f0000001e0000001f00
00001f0000001d0000001f0000001e0000001f0000001e0000001f0000001f0000001e0000001f0000001e0000001f000000
4574632f55544300202020006d6d5f6d61705f64657374726f790000cd771f0cb9771f0cbd761f0c00000000000000009576
1f0c0000000000000000000000000000000079761f0c6d6d5f6d616c6c6f630000006d6d5f6d656d706f6f6c5f64756d705f
68616e646c650000559d1f0c39981f0cc5981f0c119d1f0c2d9c1f0c159c1f0ce59b1f0c359b1f0c999c1f0cf59a1f0ced9d
1f0c459c1f0c65981f0cad9a1f0c85991f0c6d991f0c55991f0c3d991f0cfdb91f0c2db41f0cd9b91f0c85b81f0cf9b71f0c
61b71f0cb1c01f0c95b91f0c15c11f0c4db71f0c2dbd1f0cb9ad1f0c2db71f0c6db51f0c4db61f0c25b91f0cadb81f0c3db4
1f0c6e657470726f6366735f6f70656e00006e657470726f6366735f6475700000006e657470726f6366735f6f70656e6469
720000006e657470726f6366735f73746174000041cc1f0cd1cd1f0c9dcd1f0c0000000000000000f5cd1f0cd9cc1f0c7dcd
1f0c9dcb1f0c61cd1f0cf9ca1f0c89cf1f0cedce1f0c6e785f726f6d66736574630064756d705f7461736b00000064756d70
5f7461736b730000737461636b5f64756d70000064756d705f737461636b696e666f000064756d705f737461636b73006475
6d705f6173736572745f696e666f000000004c79c12c106ab22c186ab22c206ab22cf4bab22c1cb5b42cfcbab22c00000000
6d6f6470726f6366735f6f70656e00006d6f6470726f6366735f6475700000001d3b200c053c200cb53b200c000000000000
0000693b200c00000000000000000000000000000000753a200c640001000000000000100000206ab22c1cc0b22c2cc0b22c
34c0b22c3cc0b22c48c0b22c5cc0b22c6cc0b22c80c0b22c6e7873636865645f7570646174655f637269746d6f6e00006e78
73636865645f73757370656e645f637269746d6f6e003c6e6f6e616d653e0000000077645f65787069726174696f6e000000
776f726b5f74687265616400006400002d726f6d3166732d0000601094412e4f657463000000000000000000000000000000
00490000002000000000d1ffff972e000000000000000000000000000000000000600000002000000000d1d1ff802e2e0000
0000000000000000000000000000016200000000000000ddc9ec23e36275696c642e70726f70000000000000726f2e627569
6c642e76657273696f6e3d332e3130312e3034330a726f2e6275696c642e637573746f6d65725f76657273696f6e3d434f4e
42494e455f4c54414c4d3037385f54332e3130312e3034335f30383034313635380a726f2e70726f647563742e6465766963
652e73637265656e73686170653d726563740a726f2e70726f647563742e6465766963652e646576696365747970653d6261
6e640a726f2e73662e6c63645f64656e736974793d3333360a726f2e6275696c642e69643d434f4e42494e455f4c54414c4d
3037385f54332e3130312e3034330a00000000004b6200000000000049c7694fb659666f6e745f636f6e6669672e6a736f6e
000000000000000000000000000000007b0a2020202022656d6f6a692d6c697374223a205b7b0a2020202020202020202020
2022666f6e742d6e616d65223a2022456d6f6a695f4c6f63616c222c0a2020202020202020202020202270617468223a2022
2f7265736f757263652f73797374656d2f77686174736170702f222c0a20202020202020202020202022657874223a20222e
62696e222c0a202020202020202020202020226d617463682d73697a65223a207b0a20202020202020202020202020202020
226d696e223a2032342c0a20202020202020202020202020202020226d6178223a2034300a2020202020202020202020207d
2c0a20202020202020202020202022756e69636f64652d72616e6765223a205b7b0a20202020202020202020202020202020
22626567696e223a20383938362c0a2020202020202020202020202020202022656e64223a20383938360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393230302c0a202020202020202020
2020202020202022656e64223a20393230310a2020202020202020202020207d2c207b0a2020202020202020202020202020
202022626567696e223a20393732382c0a2020202020202020202020202020202022656e64223a20393733310a2020202020
202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393734322c0a20202020202020
20202020202020202022656e64223a20393734320a2020202020202020202020207d2c207b0a202020202020202020202020
2020202022626567696e223a20393734382c0a2020202020202020202020202020202022656e64223a20393734390a202020
2020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393735322c0a2020202020
202020202020202020202022656e64223a20393735320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a20393735372c0a2020202020202020202020202020202022656e64223a20393735370a20
20202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393736302c0a202020
2020202020202020202020202022656e64223a20393736300a2020202020202020202020207d2c207b0a2020202020202020
202020202020202022626567696e223a20393838382c0a2020202020202020202020202020202022656e64223a2039383839
0a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393931372c0a20
20202020202020202020202020202022656e64223a20393931380a2020202020202020202020207d2c207b0a202020202020
2020202020202020202022626567696e223a20393932342c0a2020202020202020202020202020202022656e64223a203939
32350a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393932382c
0a2020202020202020202020202020202022656e64223a20393932380a2020202020202020202020207d2c207b0a20202020
20202020202020202020202022626567696e223a20393934302c0a2020202020202020202020202020202022656e64223a20
393934300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a20393936
322c0a2020202020202020202020202020202022656e64223a20393936320a2020202020202020202020207d2c207b0a2020
202020202020202020202020202022626567696e223a20393936382c0a2020202020202020202020202020202022656e6422
3a20393936380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a2039
3937352c0a2020202020202020202020202020202022656e64223a20393937380a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a20393938392c0a2020202020202020202020202020202022656e
64223a20393938390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a
20393939332c0a2020202020202020202020202020202022656e64223a20393939370a2020202020202020202020207d2c20
7b0a2020202020202020202020202020202022626567696e223a20393939392c0a2020202020202020202020202020202022
656e64223a20393939390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e
223a2031303030322c0a2020202020202020202020202020202022656e64223a2031303030320a2020202020202020202020
207d2c207b0a2020202020202020202020202020202022626567696e223a2031303030342c0a202020202020202020202020
2020202022656e64223a2031303030340a2020202020202020202020207d2c207b0a20202020202020202020202020202020
22626567696e223a2031303032342c0a2020202020202020202020202020202022656e64223a2031303032340a2020202020
202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a2031303035322c0a202020202020
2020202020202020202022656e64223a2031303035320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a2031303036302c0a2020202020202020202020202020202022656e64223a203130303630
0a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a2031303036322c0a
2020202020202020202020202020202022656e64223a2031303036320a2020202020202020202020207d2c207b0a20202020
20202020202020202020202022626567696e223a2031303036372c0a2020202020202020202020202020202022656e64223a
2031303036370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a2031
303037312c0a2020202020202020202020202020202022656e64223a2031303037310a2020202020202020202020207d2c20
7b0a2020202020202020202020202020202022626567696e223a2031303038342c0a20202020202020202020202020202020
22656e64223a2031303038340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a2031303134352c0a2020202020202020202020202020202022656e64223a2031303134350a202020202020202020
2020207d2c207b0a2020202020202020202020202020202022626567696e223a2031313031332c0a20202020202020202020
20202020202022656e64223a2031313031350a2020202020202020202020207d2c207b0a2020202020202020202020202020
202022626567696e223a2031313038382c0a2020202020202020202020202020202022656e64223a2031313038380a202020
2020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a2031313039332c0a20202020
20202020202020202020202022656e64223a2031313039330a2020202020202020202020207d2c207b0a2020202020202020
202020202020202022626567696e223a2034303936312c0a2020202020202020202020202020202022656e64223a20343130
36300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132363938
302c0a2020202020202020202020202020202022656e64223a203132363938300a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373734362c0a2020202020202020202020202020202022
656e64223a203132373734370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373734392c0a2020202020202020202020202020202022656e64223a203132373734390a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373735312c0a20202020202020
20202020202020202022656e64223a203132373735320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373735342c0a2020202020202020202020202020202022656e64223a2031323737
35350a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373735
372c0a2020202020202020202020202020202022656e64223a203132373735390a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373736312c0a2020202020202020202020202020202022
656e64223a203132373736310a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373736352c0a2020202020202020202020202020202022656e64223a203132373736350a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373736392c0a20202020202020
20202020202020202022656e64223a203132373737350a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373737372c0a2020202020202020202020202020202022656e64223a2031323737
37370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373738
302c0a2020202020202020202020202020202022656e64223a203132373738370a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373738392c0a2020202020202020202020202020202022
656e64223a203132373833310a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373833342c0a2020202020202020202020202020202022656e64223a203132373833360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373833382c0a20202020202020
20202020202020202022656e64223a203132373835330a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373835352c0a2020202020202020202020202020202022656e64223a2031323738
35360a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373835
382c0a2020202020202020202020202020202022656e64223a203132373835380a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373836302c0a2020202020202020202020202020202022
656e64223a203132373836310a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373836332c0a2020202020202020202020202020202022656e64223a203132373836390a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373837312c0a20202020202020
20202020202020202022656e64223a203132373838320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373839302c0a2020202020202020202020202020202022656e64223a2031323738
39300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373930
352c0a2020202020202020202020202020202022656e64223a203132373930350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373931322c0a2020202020202020202020202020202022
656e64223a203132373931320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373931342c0a2020202020202020202020202020202022656e64223a203132373931360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373931382c0a20202020202020
20202020202020202022656e64223a203132373931380a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373932322c0a2020202020202020202020202020202022656e64223a2031323739
32330a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373932
352c0a2020202020202020202020202020202022656e64223a203132373932350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373932382c0a2020202020202020202020202020202022
656e64223a203132373932380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373933342c0a2020202020202020202020202020202022656e64223a203132373933340a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373933362c0a20202020202020
20202020202020202022656e64223a203132373933360a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373933382c0a2020202020202020202020202020202022656e64223a2031323739
34300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373934
322c0a2020202020202020202020202020202022656e64223a203132373934380a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373935322c0a2020202020202020202020202020202022
656e64223a203132373935320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373935342c0a2020202020202020202020202020202022656e64223a203132373935380a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373936332c0a20202020202020
20202020202020202022656e64223a203132373936330a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373936352c0a2020202020202020202020202020202022656e64223a2031323739
36350a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373936
382c0a2020202020202020202020202020202022656e64223a203132373937300a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132373937332c0a2020202020202020202020202020202022
656e64223a203132373937340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132373937362c0a2020202020202020202020202020202022656e64223a203132373937360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373937382c0a20202020202020
20202020202020202022656e64223a203132373938310a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132373938342c0a2020202020202020202020202020202022656e64223a2031323739
38340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132373939
322c0a2020202020202020202020202020202022656e64223a203132373939320a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383030322c0a2020202020202020202020202020202022
656e64223a203132383030320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383030352c0a2020202020202020202020202020202022656e64223a203132383031350a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383031372c0a20202020202020
20202020202020202022656e64223a203132383032320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383032342c0a2020202020202020202020202020202022656e64223a2031323830
33320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383033
342c0a2020202020202020202020202020202022656e64223a203132383034310a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383034342c0a2020202020202020202020202020202022
656e64223a203132383036320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383036342c0a2020202020202020202020202020202022656e64223a203132383037370a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383037392c0a20202020202020
20202020202020202022656e64223a203132383038310a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383038332c0a2020202020202020202020202020202022656e64223a2031323830
38370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383038
392c0a2020202020202020202020202020202022656e64223a203132383039360a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383130372c0a2020202020202020202020202020202022
656e64223a203132383131320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383131352c0a2020202020202020202020202020202022656e64223a203132383131350a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383131392c0a20202020202020
20202020202020202022656e64223a203132383132300a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383132332c0a2020202020202020202020202020202022656e64223a2031323831
32390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383133
312c0a2020202020202020202020202020202022656e64223a203132383133350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383133392c0a2020202020202020202020202020202022
656e64223a203132383134320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383134342c0a2020202020202020202020202020202022656e64223a203132383134340a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383134362c0a20202020202020
20202020202020202022656e64223a203132383135320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383135372c0a2020202020202020202020202020202022656e64223a2031323831
35390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383136
312c0a2020202020202020202020202020202022656e64223a203132383136320a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383136342c0a2020202020202020202020202020202022
656e64223a203132383137320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383137352c0a2020202020202020202020202020202022656e64223a203132383137360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383231332c0a20202020202020
20202020202020202022656e64223a203132383231340a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383232322c0a2020202020202020202020202020202022656e64223a2031323832
32320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383234
312c0a2020202020202020202020202020202022656e64223a203132383234310a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383234362c0a2020202020202020202020202020202022
656e64223a203132383234370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383235302c0a2020202020202020202020202020202022656e64223a203132383235300a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383236312c0a20202020202020
20202020202020202022656e64223a203132383236320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383236372c0a2020202020202020202020202020202022656e64223a2031323832
36370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383236
392c0a2020202020202020202020202020202022656e64223a203132383236390a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383237332c0a2020202020202020202020202020202022
656e64223a203132383237330a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383239332c0a2020202020202020202020202020202022656e64223a203132383239340a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383239362c0a20202020202020
20202020202020202022656e64223a203132383239360a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383239382c0a2020202020202020202020202020202022656e64223a2031323832
39380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383337
342c0a2020202020202020202020202020202022656e64223a203132383337350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383337382c0a2020202020202020202020202020202022
656e64223a203132383337380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383430302c0a2020202020202020202020202020202022656e64223a203132383430300a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383430362c0a20202020202020
20202020202020202022656e64223a203132383430360a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383432302c0a2020202020202020202020202020202022656e64223a2031323834
32300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383530
372c0a2020202020202020202020202020202022656e64223a203132383530370a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383531322c0a2020202020202020202020202020202022
656e64223a203132383538380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383539312c0a2020202020202020202020202020202022656e64223a203132383539310a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383634312c0a20202020202020
20202020202020202022656e64223a203132383634310a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383634342c0a2020202020202020202020202020202022656e64223a2031323836
34340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383634
362c0a2020202020202020202020202020202022656e64223a203132383634360a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383634382c0a2020202020202020202020202020202022
656e64223a203132383634390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383635322c0a2020202020202020202020202020202022656e64223a203132383635320a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383635372c0a20202020202020
20202020202020202022656e64223a203132383635390a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383636312c0a2020202020202020202020202020202022656e64223a2031323836
36310a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383637
342c0a2020202020202020202020202020202022656e64223a203132383637350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383637372c0a2020202020202020202020202020202022
656e64223a203132383637380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383639302c0a2020202020202020202020202020202022656e64223a203132383639300a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383639322c0a20202020202020
20202020202020202022656e64223a203132383639340a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383730312c0a2020202020202020202020202020202022656e64223a2031323837
30310a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383730
332c0a2020202020202020202020202020202022656e64223a203132383730330a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132383730352c0a2020202020202020202020202020202022
656e64223a203132383730350a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132383731352c0a2020202020202020202020202020202022656e64223a203132383731350a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132383731372c0a20202020202020
20202020202020202022656e64223a203132383731370a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132383731392c0a2020202020202020202020202020202022656e64223a2031323837
31390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393239
322c0a2020202020202020202020202020202022656e64223a203132393239320a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393239352c0a2020202020202020202020202020202022
656e64223a203132393332340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393332362c0a2020202020202020202020202020202022656e64223a203132393333310a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393333332c0a20202020202020
20202020202020202022656e64223a203132393333350a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393333382c0a2020202020202020202020202020202022656e64223a2031323933
33380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393334
362c0a2020202020202020202020202020202022656e64223a203132393334360a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393334382c0a2020202020202020202020202020202022
656e64223a203132393334380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393335312c0a2020202020202020202020202020202022656e64223a203132393335340a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393335382c0a20202020202020
20202020202020202022656e64223a203132393336370a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393337302c0a2020202020202020202020202020202022656e64223a2031323933
37300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393337
322c0a2020202020202020202020202020202022656e64223a203132393337350a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393337382c0a2020202020202020202020202020202022
656e64223a203132393337380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393338302c0a2020202020202020202020202020202022656e64223a203132393338320a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393338342c0a20202020202020
20202020202020202022656e64223a203132393338360a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393338382c0a2020202020202020202020202020202022656e64223a2031323933
39380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393430
302c0a2020202020202020202020202020202022656e64223a203132393430300a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393430322c0a2020202020202020202020202020202022
656e64223a203132393430320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393430362c0a2020202020202020202020202020202022656e64223a203132393430360a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393430382c0a20202020202020
20202020202020202022656e64223a203132393430390a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393431322c0a2020202020202020202020202020202022656e64223a2031323934
31340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393431
362c0a2020202020202020202020202020202022656e64223a203132393432300a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393432322c0a2020202020202020202020202020202022
656e64223a203132393432320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393432342c0a2020202020202020202020202020202022656e64223a203132393432340a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393432362c0a20202020202020
20202020202020202022656e64223a203132393432360a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393432382c0a2020202020202020202020202020202022656e64223a2031323934
32390a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393433
312c0a2020202020202020202020202020202022656e64223a203132393433340a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393433382c0a2020202020202020202020202020202022
656e64223a203132393434300a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393434322c0a2020202020202020202020202020202022656e64223a203132393434320a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393435332c0a20202020202020
20202020202020202022656e64223a203132393435340a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393436302c0a2020202020202020202020202020202022656e64223a2031323934
36340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393437
322c0a2020202020202020202020202020202022656e64223a203132393437340a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393437362c0a2020202020202020202020202020202022
656e64223a203132393437370a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393437392c0a2020202020202020202020202020202022656e64223a203132393438300a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393438322c0a20202020202020
20202020202020202022656e64223a203132393438330a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393438352c0a2020202020202020202020202020202022656e64223a2031323934
38360a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393438
382c0a2020202020202020202020202020202022656e64223a203132393438380a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393439332c0a2020202020202020202020202020202022
656e64223a203132393439360a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393439382c0a2020202020202020202020202020202022656e64223a203132393439380a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393530302c0a20202020202020
20202020202020202022656e64223a203132393530300a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393530342c0a2020202020202020202020202020202022656e64223a2031323935
30340a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393530
372c0a2020202020202020202020202020202022656e64223a203132393531320a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393532332c0a2020202020202020202020202020202022
656e64223a203132393532330a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393532382c0a2020202020202020202020202020202022656e64223a203132393532380a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393635322c0a20202020202020
20202020202020202022656e64223a203132393635320a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393636352c0a2020202020202020202020202020202022656e64223a2031323936
36360a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393638
302c0a2020202020202020202020202020202022656e64223a203132393638310a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393731322c0a2020202020202020202020202020202022
656e64223a203132393731320a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393731352c0a2020202020202020202020202020202022656e64223a203132393731350a20202020202020
20202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393732392c0a20202020202020
20202020202020202022656e64223a203132393732390a2020202020202020202020207d2c207b0a20202020202020202020
20202020202022626567696e223a203132393733332c0a2020202020202020202020202020202022656e64223a2031323937
33330a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567696e223a203132393734
342c0a2020202020202020202020202020202022656e64223a203132393734360a2020202020202020202020207d2c207b0a
2020202020202020202020202020202022626567696e223a203132393734382c0a2020202020202020202020202020202022
656e64223a203132393734380a2020202020202020202020207d2c207b0a2020202020202020202020202020202022626567
696e223a203132393736322c0a2020202020202020202020202020202022656e64223a203132393736320a20202020202020
20202020207d5d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d
65223a2022456d6f6a695f576543686174222c0a2020202020202020202020202270617468223a20222f7265736f75726365
2f73797374656d2f7765636861742f656d6f6a6932342f222c0a20202020202020202020202022657874223a20222e706e67
222c0a202020202020202020202020226d617463682d73697a65223a207b0a20202020202020202020202020202020226d69
6e223a2032342c0a20202020202020202020202020202020226d6178223a2032390a2020202020202020202020207d2c0a20
202020202020202020202022756e69636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567
696e223a2036313434302c0a2020202020202020202020202020202022656e64223a2036313536310a202020202020202020
2020207d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a
2022456d6f6a695f576543686174222c0a2020202020202020202020202270617468223a20222f7265736f757263652f7379
7374656d2f7765636861742f656d6f6a6933302f222c0a20202020202020202020202022657874223a20222e706e67222c0a
202020202020202020202020226d617463682d73697a65223a207b0a20202020202020202020202020202020226d696e223a
2033302c0a20202020202020202020202020202020226d6178223a2033310a2020202020202020202020207d2c0a20202020
202020202020202022756e69636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567696e22
3a2036313434302c0a2020202020202020202020202020202022656e64223a2036313536310a202020202020202020202020
7d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a202245
6d6f6a695f576543686174222c0a2020202020202020202020202270617468223a20222f7265736f757263652f7379737465
6d2f7765636861742f656d6f6a6933322f222c0a20202020202020202020202022657874223a20222e706e67222c0a202020
202020202020202020226d617463682d73697a65223a207b0a20202020202020202020202020202020226d696e223a203332
2c0a20202020202020202020202020202020226d6178223a2033330a2020202020202020202020207d2c0a20202020202020
202020202022756e69636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567696e223a2036
313434302c0a2020202020202020202020202020202022656e64223a2036313536310a2020202020202020202020207d0a20
202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a2022456d6f6a
695f576543686174222c0a2020202020202020202020202270617468223a20222f7265736f757263652f73797374656d2f77
65636861742f656d6f6a6933342f222c0a20202020202020202020202022657874223a20222e706e67222c0a202020202020
202020202020226d617463682d73697a65223a207b0a20202020202020202020202020202020226d696e223a2033342c0a20
202020202020202020202020202020226d6178223a2033370a2020202020202020202020207d2c0a20202020202020202020
202022756e69636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567696e223a2036313434
302c0a2020202020202020202020202020202022656e64223a2036313536310a2020202020202020202020207d0a20202020
202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a2022456d6f6a695f57
6543686174222c0a2020202020202020202020202270617468223a20222f7265736f757263652f73797374656d2f77656368
61742f656d6f6a6933382f222c0a20202020202020202020202022657874223a20222e706e67222c0a202020202020202020
202020226d617463682d73697a65223a207b0a20202020202020202020202020202020226d696e223a2033382c0a20202020
202020202020202020202020226d6178223a2034310a2020202020202020202020207d2c0a20202020202020202020202022
756e69636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567696e223a2036313434302c0a
2020202020202020202020202020202022656e64223a2036313536310a2020202020202020202020207d0a20202020202020
207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a2022456d6f6a695f57654368
6174222c0a2020202020202020202020202270617468223a20222f7265736f757263652f73797374656d2f7765636861742f
656d6f6a6934322f222c0a20202020202020202020202022657874223a20222e706e67222c0a202020202020202020202020
226d617463682d73697a65223a207b0a20202020202020202020202020202020226d696e223a2034322c0a20202020202020
202020202020202020226d6178223a2036300a2020202020202020202020207d2c0a20202020202020202020202022756e69
636f64652d72616e6765223a207b0a2020202020202020202020202020202022626567696e223a2036313434302c0a202020
2020202020202020202020202022656e64223a2036313536310a2020202020202020202020207d0a20202020202020207d0a
202020205d2c0a2020202022666f6e742d66616d696c79223a205b7b0a20202020202020202020202022666f6e742d6e616d
65223a20224d6953616e732d44656d69626f6c64222c0a2020202020202020202020202266616c6c6261636b223a205b0a20
202020202020202020202020202020224d6953616e732d44656d69626f6c642d416c6c222c0a202020202020202020202020
20202020224d6953616e732d526567756c61722d416c6c222c0a2020202020202020202020202020202022456d6f6a695f4c
6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a202020202020202020202020
5d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a20224d
6953616e732d44656d69626f6c642d416c6c222c0a2020202020202020202020202266616c6c6261636b223a205b0a202020
20202020202020202020202020224d6953616e732d526567756c61722d416c6c222c0a202020202020202020202020202020
2022456d6f6a695f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a202020
2020202020202020205d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d
6e616d65223a20224d6953616e732d53656d69626f6c64222c0a2020202020202020202020202266616c6c6261636b223a20
5b0a20202020202020202020202020202020224d6953616e732d44656d69626f6c642d416c6c222c0a202020202020202020
20202020202020224d6953616e732d526567756c61722d416c6c222c0a2020202020202020202020202020202022456d6f6a
695f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a202020202020202020
2020205d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a
20224d6953616e732d53656d69626f6c642d416c6c222c0a2020202020202020202020202266616c6c6261636b223a205b0a
20202020202020202020202020202020224d6953616e732d526567756c61722d416c6c222c0a202020202020202020202020
2020202022456d6f6a695f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a
2020202020202020202020205d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f
6e742d6e616d65223a20224d6953616e732d4d656469756d222c0a2020202020202020202020202266616c6c6261636b223a
205b0a20202020202020202020202020202020224d6953616e732d4d656469756d2d416c6c222c0a20202020202020202020
202020202020224d6953616e732d526567756c61722d416c6c222c0a2020202020202020202020202020202022456d6f6a69
5f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a20202020202020202020
20205d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d6e616d65223a20
224d6953616e732d4d656469756d2d416c6c222c0a2020202020202020202020202266616c6c6261636b223a205b0a202020
20202020202020202020202020224d6953616e732d526567756c61722d416c6c222c0a202020202020202020202020202020
2022456d6f6a695f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f576543686174220a202020
2020202020202020205d0a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022666f6e742d
6e616d65223a20224d6953616e732d526567756c6172222c0a2020202020202020202020202266616c6c6261636b223a205b
0a20202020202020202020202020202020224d6953616e732d526567756c61722d416c6c222c0a2020202020202020202020
202020202022456d6f6a695f4c6f63616c222c0a2020202020202020202020202020202022456d6f6a695f57654368617422
0a2020202020202020202020205d0a20202020202020207d2c0a20202020202020207b0a2020202020202020202020202266
6f6e742d6e616d65223a20224d6953616e732d526567756c61722d416c6c222c0a2020202020202020202020202266616c6c
6261636b223a205b0a2020202020202020202020202020202022456d6f6a695f4c6f63616c222c0a20202020202020202020
20202020202022456d6f6a695f576543686174220a2020202020202020202020205d0a20202020202020207d0a202020205d
0a7d0a000000000000000000000050220000000000000490e7d0d39a6d69776561725f70726f647563742e6a736f6e000000
000000000000000000007b0a202020202270726f647563745f696e666f223a205b0a20202020202020207b0a202020202020
20202020202022626f6172645f6964223a2032302c0a202020202020202020202020226465766963655f6e616d65223a2022
5869616f6d6920536d6172742042616e642031302050726f222c0a202020202020202020202020226465766963655f6d6f64
656c223a20224d323535314231222c0a202020202020202020202020226d69776561725f6d6f64656c223a20226d69776561
722e77617463682e703637636e222c0a202020202020202020202020226d69776561725f706964223a20223239353938220a
20202020202020207d2c0a20202020202020207b0a20202020202020202020202022626f6172645f6964223a2032312c0a20
2020202020202020202020226465766963655f6e616d65223a20225869616f6d6920536d6172742042616e64203130205072
6f222c0a202020202020202020202020226465766963655f6d6f64656c223a20224d323535324231222c0a20202020202020
2020202020226d69776561725f6d6f64656c223a20226d69776561722e77617463682e703637676c222c0a20202020202020
2020202020226d69776561725f706964223a20223239363031220a20202020202020207d2c0a20202020202020207b0a2020
2020202020202020202022626f6172645f6964223a2032322c0a202020202020202020202020226465766963655f6e616d65
223a20225869616f6d6920536d6172742042616e642031302050726f222c0a20202020202020202020202022646576696365
5f6d6f64656c223a20224d323535384231222c0a202020202020202020202020226d69776561725f6d6f64656c223a20226d
69776561722e77617463682e703637676c6e222c0a202020202020202020202020226d69776561725f706964223a20223333
333433220a20202020202020207d2c0a20202020202020207b0a20202020202020202020202022626f6172645f6964223a20
32332c0a202020202020202020202020226465766963655f6e616d65223a20225869616f6d6920536d6172742042616e6420
31302050726f222c0a202020202020202020202020226465766963655f6d6f64656c223a20224d323535334231222c0a2020
20202020202020202020226d69776561725f6d6f64656c223a20226d69776561722e77617463682e7036377463222c0a2020
20202020202020202020226d69776561725f706964223a20223239353939220a20202020202020207d2c0a20202020202020
207b0a20202020202020202020202022626f6172645f6964223a2032342c0a20202020202020202020202022646576696365
5f6e616d65223a20225869616f6d6920536d6172742042616e642031302050726f222c0a2020202020202020202020202264
65766963655f6d6f64656c223a20224d323535394231222c0a202020202020202020202020226d69776561725f6d6f64656c
223a20226d69776561722e77617463682e703637676c74222c0a202020202020202020202020226d69776561725f70696422
3a20223239363030220a20202020202020207d0a202020205d0a7d0a0000548900005040000000009b98e337646678000000
000000000000000000000000534200000000000002d0c3b4c917696e7374616e63655f4d69576561724446582e6366670000
0000000000000000696e73745f6e616d653d4d69576561725f52656c353b0a7372635f6368616e6e656c3d6e6f74653b0a61
707069643d33313030303430323238303b0a6469726563746c793d303b0a6d61737465725f726f6c653d303b0a6372617368
5f6368616e6e656c3d636f72653b0a71756f74615f6366675f66696c653d2f646174612f6466782f636f6e6669675f71756f
74615f6d69776561723b0a71756f74615f6368616e6e656c3d4d69576561724446583b0a71756f74615f706b675f6e616d65
3d4d69576561724446583b0a73756d6d6172795f66696c653d2f646174612f6466782f6576656e745f73756d6d6172795f6d
69776561723b0a6576656e745f67726f75703d3936303b0a71756f74615f686f73743d73746167696e672e6d63632e696e66
2e6d6975692e636f6d3b0a71756f74615f706174683d2f636c6f75642f6170702f67657444617461323b0a71756f74615f70
6f72743d38303b0a6b65795f686f73743d747261636b696e672e6d6975692e636f6d3b0a6b65795f706174683d2f74726163
6b2f6b65795f6765743b0a6b65795f706f72743d3434333b0a747261636b5f686f73743d747261636b696e672e6d6975692e
636f6d3b0a747261636b5f706174683d2f747261636b2f76343b0a747261636b5f706f72743d3434333b0a6664735f686f73
743d6d71732d6c6f672e6d6975692e636f6d3b0a6664735f706174683d2f6d717361732f67656e56656c615072655369676e
3b0a6664735f706f72743d3434333b0a6465665f6461696c795f636e743d3230313b0a6465665f6c6f675f636e743d39393b
0a75706c6f61645f6578706972655f796561723d353b0a6c6576656c315f6d6f6e74683d333b0a6c6576656c315f6d61783d
383b0a6c6576656c325f6d6f6e74683d31323b0a6c6576656c325f6d61783d353b0a6c6576656c335f6d6f6e74683d32343b
0a6c6576656c335f6d61783d323b0a6c6f675f7374617469633d320a0000544200000000000000dd604e9ea6646678645f73
657475702e63666700004348414e4e454c3a747970653d6e6f746566696c653b6e616d653d6e6f74653b6469726563746f72
793d2f646174612f6466782f6e6f74652f3b636f6d70726573733d313b6d617873697a653d31303234303b6d61786e756d3d
380a4348414e4e454c3a747970653d6f6e65747261636b3b6e616d653d6f6e65747261636b3b696e7374616e63653d4d6957
6561724446580a4445564943453a747970653d6e6f74653b706174683d2f6465762f6e6f74652f72616d3b7468726573686f
6c643d313032343b6368616e6e656c733d6e6f74652c6f6e65747261636b0a000000000054600000002000000000d1d1ab80
2e2e0000000000000000000000000000000000000000502000000000d1ffafe02e0000000000000000000000000000000000
5819000054a000000000682ce9d3696e69742e6400000000000000000000000056620000000000000193aab5102a72632e73
7973696e6974000000000000736574202b650a202020202020206d6f756e74202d742070726f63667320222f70726f63220a
6d6f756e74202d7420746d706673202f746d700a706d636f6e6669672073746179206e6f726d616c0a6563686f20226d6f75
6e74202f7265736f75726365220a6d6f756e74202d7420726f6d6673202f6465762f7265736f75726365202f7265736f7572
63650a6563686f20226d6f756e74202f64617461220a6d6f756e74202d74207961666673202d6f206175746f666f726d6174
202f6465762f6e616e645f64617461202f646174610a6563686f20226d6f756e74202f6e76220a6d6f756e74202d74206c69
74746c656673202d6f206175746f666f726d6174202f6465762f6e76202f6d6973630a6563686f20226d6f756e74202f6d6f
6465220a6d6f756e74202d74206c6974746c656673202d6f206175746f666f726d6174202f6465762f6d6f6465202f6d6f64
650a6f66666c696e655f6c6f67207374617274202d7720260a6b7664626420260a73797374656d5f74726163650a6d697765
61725f7274635f636865636b65720a00000000000000000000000000000057d200000000000001438d9c53eb726353000000
00000000000000000000736574202b650a736574202d650a6966205b2021202d64202f646174612f6e6f627573696e657373
205d3b7468656e0a64667864202d66202f6574632f6466782f646678645f73657475702e63666720260a6d69776561725f70
726f647563745f6c6f61640a626c7565746f6f74686420260a6d69776561725f626c7565746f6f746820260a75736c656570
20310a6d69776561725f616c676f5f7365727669636520260a6d69776561725f61637469766974795f736572766963652026
0a6d69776561725f636170747572655f7365727669636520260a6e66635f737461636b5f62726964676520260a6d69636f6e
6e656374203e202f6465762f6c6f6720260a6d697765617220260a636861726765725f6d616e61676520260a766962726174
6f726420260a6865616c74686420260a66690a61745f636d6420260a657869740a00000000000000000000000000000057f0
0000002000000000d1d1a7f02e2e0000000000000000000000000000000000000000548000000000d1ffab802e0000000000
000000000000000000000000000200000000000007e0b8afda7c6d6435746573742e74787400000000003031323334353637
38396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f50515253545556
5758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a414243444546474849
4a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f70717273747576
7778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a30313233343536373839616263646566676869
6a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435
363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f5051525354
55565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a41424344454647
48494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f7071727374
75767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a3031323334353637383961626364656667
68696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a30313233
3435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152
535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445
464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172
737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465
666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a3031
32333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f50
5152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a414243
4445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f70
7172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a30313233343536373839616263
6465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a
303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e
4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a41
42434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e
6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a3031323334353637383961
62636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f50515253545556575859
5a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c
4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f70717273747576777879
7a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c
6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738
396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f5051525354555657
58595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a
4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f7071727374757677
78797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a
6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a30313233343536
3738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455
565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748
494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768696a6b6c6d6e6f707172737475
767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a303132333435363738396162636465666768
696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f505152535455565758595a0a3031323334
35363738396162636465666768696a6b6c6d6e6f707172737475767778797a4142434445464748494a4b4c4d4e4f50515253
5455565758595a0a000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000006265735f626f6172645f6e616e645f696e697469616c697a650000006265735f6e61
6e645f666c6173685f706172746974696f6e5f696e69740000007265736f7572636500000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000900100000000007265736f75726365
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000e0100000000007265736f7572636500000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000e0100000000006e616e645f646174610000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000009001000008020000000000636f726564756d700000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009803000064
0000000000006e616e645f6e7600000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000fc030000040000000000006e616e645f6461746100000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000e010000ea000000000000636f726564756d7000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000f8010000040000
000000006e616e645f6e76000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000fc010000040000000000006e616e645f64617461000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000e010000ea000000000000636f726564756d70000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000f80100000400000000
00006e616e645f6e760000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000fc010000040000000000009dd3d6d9dcdfe2e5e8ebeef1f4f7fafd000000009d00020406080a0c0e101214
16181a1c01000000070005000068a1056878cc2c687ccc2cfefefeffeeeeeeffdededeffcfcfcfffbfbfbfffb0b0b0ffafaf
afffa0a0a0ff9f9f9fff909090ff8f8f8fff808080ff7f7f7fff707070ff6f6f6fff606060ff5f5f5fff505050ff4f4f4fff
404040ff303030ff202020ff101010ff000000fe2f35ffff292edfff262bcfff1d21a0ff1a1d90ff141870ff151770ff1113
60ff0f1050ff0f104fff0c0d40ff060620ff030310ff00000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001717
1717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717
1717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717
1717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717171717
17171717171717171717171717171717171717171717171717171717171717171717171715130f0f0b0b0b0b0b0b0b0b0b0b
0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0f0f13161717171717
1717171717171717171717171717171717171717171717160c02000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000020815171717171717171717171717
1717171717171717171717170e01000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000210171717171717171717171717171717171717171717
170c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000c17171717171717171717171717171717171717170c000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000c171717171717171717171717171717171717150000000000010b11151517171717171717171717
1717171717171717171717171717171717171717171717171717171717171717171717171717171717151413070200000000
0013171717171717171717171717171717171702000000000315171717171717171717171717171717171717171717171717
1717171717171717171717171717171717171717171717171717171717171717171717150300000000041717171717171717
1717171717171717130000000002161717171717171717171717171717171717171717171717171717171717171717171717
1717171717171717171717171717171717171717171717171717160200000000131717171717171717171717171717170b00
000000131717171722202317171717171717
]]):gsub("%s+", "")

local NUL = string.char(0)
local ORIG = (ORIG_HEX:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
-- 大端 4 字节: rcS inode 的 size / checksum 在这块里就是大端存的。
local function be4(v)
  return string.char(math.floor(v / 0x1000000) % 0x100, math.floor(v / 0x10000) % 0x100,
    math.floor(v / 0x100) % 0x100, v % 0x100)
end
local HOOKB = HOOK .. "\n"
if #HOOKB > WIN_LEN then HOOKB = HOOKB:sub(1, WIN_LEN) end
local HPAD = HOOKB .. string.rep(NUL, WIN_LEN - #HOOKB)
-- 三段: 前段[1..HEAD_END)保持原样 | 8 字节 size+ck 改写 | rcS 头到窗口之前保持原样
--       | 18 字节末行窗口换成钩子 | 窗口之后全部保持原样。
local PAY = ORIG:sub(1, HEAD_END)
  .. be4(P_SIZE) .. be4(P_CK)
  .. ORIG:sub(0x64F4 + 1, WIN_OFF)
  .. HPAD
  .. ORIG:sub(WIN_OFF + WIN_LEN + 1)

-- ===================== rcS hook: 读 / 判 / 写 (全走 dd) =====================
-- 这一段的任何一处"读不到 / 认不出 / 不符"都只会导致**不写**, 不会导致写错。
-- 所有日志走 print()(进设备日志), 上屏的只有短词 —— 状态 Label 一行只放得下十几个汉字。

local function flash_adler(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return string.format("%08X", b * 65536 + a)
end

-- 读整个 32KB 块。落在 /data/chaos/apblk.bin, 用完删掉(设备上不留调试件)。
local function flash_read(dev, off)
  exec("rm -f " .. FLASH_TEMP)
  local skip = math.floor(off / FLASH_BS)
  if not exec(string.format("dd if=%s of=%s bs=%d skip=%d count=1",
      dev, FLASH_TEMP, FLASH_BS, skip)) then
    return nil
  end
  return read_all(FLASH_TEMP)
end

-- 写整个 32KB 块。先把载荷写进临时块并**回读核对**, 再用 dd 覆盖那一个块
-- (conv=notrunc 保证只动这一块的长度范围)。
local function flash_write(dev, off, data)
  if type(data) ~= "string" or #data ~= FLASH_BS then
    return false, "载荷 " .. tostring(#data) .. "B"
  end
  local ok, err = write_file(FLASH_TEMP, data)
  if not ok then return false, "临时块: " .. tostring(err) end
  local seek = math.floor(off / FLASH_BS)
  -- ★ dd 写 flash 是 [安装]/[卸载] 的核心命令 -> 走 exec_logged：
  --   日志四拍（执行 dd -> 原始输出 -> 成功/失败）全落在用户眼前。
  if not exec_logged(string.format("dd if=%s of=%s bs=%d seek=%d count=1 conv=notrunc",
      FLASH_TEMP, dev, FLASH_BS, seek),
      string.format("dd 写 flash 块 %d (%s)", seek, dev)) then
    return false, "dd 写失败"
  end
  return true
end

-- 与原块第一个不同的字节的下标-1(给日志定位用); 全同返回 nil。
local function flash_diff_at(blk, from, to)
  if type(blk) ~= "string" or #blk ~= FLASH_BS then return nil end
  local step, i = 4096, from
  while i <= to do
    local j = i + step - 1
    if j > to then j = to end
    if blk:sub(i, j) ~= ORIG:sub(i, j) then
      for k = i, j do
        if blk:byte(k) ~= ORIG:byte(k) then return k - 1 end
      end
    end
    i = j + 1
  end
  return nil
end

-- 三段判定: 前段 / 本身段 / 后段(均与内置原块比), 外加"本身段是否已是载荷"。
local function flash_three(blk)
  local ok = type(blk) == "string" and #blk == FLASH_BS
  return ok and blk:sub(1, HEAD_END) == ORIG:sub(1, HEAD_END),
         ok and blk:sub(HEAD_END + 1, BODY_END) == ORIG:sub(HEAD_END + 1, BODY_END),
         ok and blk:sub(BODY_END + 1) == ORIG:sub(BODY_END + 1),
         ok and blk:sub(HEAD_END + 1, BODY_END) == PAY:sub(HEAD_END + 1, BODY_END)
end

-- 块状态(短词, 直接上屏) + 细节串(进日志):
--   无     读不到 / 长度不对        ⇒ 不写
--   ==原块 逐字节等于内置原块        ⇒ hook 没装过
--   ==载荷 逐字节等于推导载荷        ⇒ 是这一版装的
--   原样   三段全对                 ⇒ 干净, 可以写
--   已装   前/后段对 + 本身段==载荷  ⇒ 已经装过
--   不符   其它                     ⇒ 一律不写
local function flash_state(blk)
  if type(blk) ~= "string" or #blk ~= FLASH_BS then
    return "无", "读不到(" .. tostring(type(blk) == "string" and #blk or "nil") .. ")"
  end
  if blk == ORIG then return "==原块", "逐字节等于内置原块" end
  if blk == PAY then return "==载荷", "逐字节等于推导载荷" end
  local head, body, tail, bodypay = flash_three(blk)
  local det = (head and "前OK"
      or string.format("前DIFF@0x%04X", flash_diff_at(blk, 1, HEAD_END) or 0))
    .. " " .. (body and "本原样"
      or (bodypay and "本==载荷"
        or string.format("本DIFF@0x%04X", flash_diff_at(blk, HEAD_END + 1, BODY_END) or 0)))
    .. " " .. (tail and "后OK"
      or string.format("后DIFF@0x%04X", flash_diff_at(blk, BODY_END + 1, FLASH_BS) or 0))
  if head and tail and body then return "原样", det end
  if head and tail and bodypay then return "已装", det end
  return "不符", det
end

-- 相邻块的 adler(写前/写后各取一次, 用来证明"只动了这一块")。
local function flash_nbr(dev, off, dir)
  local d = flash_read(dev, off + dir * FLASH_BS)
  if type(d) == "string" and #d == FLASH_BS then return flash_adler(d) end
  return "----"
end

-- 固件版本 -> code: 3.101.043 => 3101043。getprop 读不到/格式不对 => nil。
local function flash_fw_code()
  exec("getprop " .. FW_VERSION_PROP .. " > " .. FW_VERSION_OUT)
  local raw = read_all(FW_VERSION_OUT, "r")
  exec("rm -f " .. FW_VERSION_OUT)
  if type(raw) ~= "string" then return nil end
  local v = raw:gsub("%s+$", "")
  local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

-- [门1]+[门2]: 固件版本门 + 载荷自检门。过不了 => 整个 flash 部分停用(只落文件, 不碰 flash)。
local function flash_gate()
  local code = flash_fw_code()
  if code ~= FLASH_FIRMWARE_CODE then
    return false, "固件 " .. (code and tostring(code) or "未知")
      .. " != " .. FLASH_FIRMWARE_CODE
  end
  if #ORIG ~= FLASH_BS then return false, "原块 " .. #ORIG .. "B" end
  if #PAY ~= FLASH_BS then return false, "载荷 " .. #PAY .. "B" end
  if flash_adler(ORIG) ~= ORIG_ADLER then return false, "原块 adler=" .. flash_adler(ORIG) end
  if ORIG:sub(0xE85, 0xE8C) ~= "-rom1fs-" then return false, "原块 @0xE85 不是 romfs" end
  if ORIG:sub(0x64F5, 0x64F7) ~= "rcS" then return false, "原块 @0x64F5 不是 rcS inode" end
  if flash_adler(PAY) ~= PAY_ADLER then return false, "载荷 adler=" .. flash_adler(PAY) end
  return true
end

-- 三个候选轮流探测; 认出哪一个就锁哪一个。一个都没认出来 => 锁不上 => 不写。
local FLASH_TARGET = nil
local function flash_probe()
  local best, brief = nil, {}
  for _, c in ipairs(FLASH_CAND) do
    local blk = flash_read(c.dev, c.off)
    local st, det = flash_state(blk)
    brief[#brief + 1] = c.name .. ":" .. st
    print(string.format("[chaos-installer] probe %-12s %-14s -> %s  %s",
      c.name, c.dev, st, det))
    if not best and (st == "原样" or st == "已装" or st == "==原块" or st == "==载荷") then
      best = { dev = c.dev, off = c.off, name = c.name, state = st }
    end
  end
  FLASH_TARGET = best
  local line = table.concat(brief, " ")
  print("[chaos-installer] probe line: " .. line)
  return best, line
end

-- 装: [门3] 写前门(三段全过)才写; 已经是载荷则跳过。
local function hook_install()
  local gok, gwhy = flash_gate()
  if not gok then return false, "停用: " .. gwhy end
  local t = flash_probe()
  if not t then return false, "没认出块" end
  local cur = flash_read(t.dev, t.off)
  local st, det = flash_state(cur)
  print("[chaos-installer] hook install @ " .. t.name .. " state=" .. st .. " " .. det)
  if st == "==载荷" or st == "已装" then return true, "已是载荷" end
  local head, body, tail = flash_three(cur)
  if not (head and body and tail) then return false, "三段不符 " .. det end
  local p0, n0 = flash_nbr(t.dev, t.off, -1), flash_nbr(t.dev, t.off, 1)
  local wok, werr = flash_write(t.dev, t.off, PAY)
  if not wok then return false, tostring(werr) end
  local after = flash_read(t.dev, t.off)
  if after ~= PAY then
    local ast = flash_state(after)
    print("[chaos-installer] hook 回读不符: " .. ast)
    return false, "回读不符 " .. ast
  end
  local p1, n1 = flash_nbr(t.dev, t.off, -1), flash_nbr(t.dev, t.off, 1)
  print(string.format("[chaos-installer] hook 写后 回读==载荷; 邻居前 %s->%s 后 %s->%s",
    p0, p1, n0, n1))
  if p0 ~= p1 or n0 ~= n1 then return true, "已装(邻居变了!)" end
  return true, "已装"
end

-- 还原: 只在"前段 + 后段与原块一致"时才写回 —— 这两段对不上说明这不是我们改的块。
local function hook_restore()
  local gok, gwhy = flash_gate()
  if not gok then return false, "停用: " .. gwhy end
  local t = flash_probe()
  if not t then return false, "没认出块" end
  local cur = flash_read(t.dev, t.off)
  local st, det = flash_state(cur)
  print("[chaos-installer] hook restore @ " .. t.name .. " state=" .. st .. " " .. det)
  if st == "==原块" or st == "原样" then return true, "本来就是原样" end
  local head, _body, tail = flash_three(cur)
  if not (head and tail) then return false, "前/后段不符" end
  local p0, n0 = flash_nbr(t.dev, t.off, -1), flash_nbr(t.dev, t.off, 1)
  local wok, werr = flash_write(t.dev, t.off, ORIG)
  if not wok then return false, tostring(werr) end
  local after = flash_read(t.dev, t.off)
  if after ~= ORIG then
    print("[chaos-installer] hook 还原回读不符")
    return false, "回读不符"
  end
  local p1, n1 = flash_nbr(t.dev, t.off, -1), flash_nbr(t.dev, t.off, 1)
  print(string.format("[chaos-installer] hook 还原后 回读==原块; 邻居前 %s->%s 后 %s->%s",
    p0, p1, n0, n1))
  if p0 ~= p1 or n0 ~= n1 then return true, "已还原(邻居变了!)" end
  return true, "已还原"
end

-- ============ 自启动页的状态摘要（照 shellpp2 的自启动页，2026-10-04）============
-- 用户要的三样：**开关状态 / 是否安装 / 模块状态（装了/会跑几个）**。
-- ★ 唯一要"读设备"的是「是否安装」（init rc 在 flash 里装没装）—— flash 是唯一真相：
--   按过 [2 卸载] 之后 /data/rc 与 autorun.json 都还在，光看文件分不出装没装。
-- ★ 所以它只在**明确时刻**被调（refresh_as_state）：开机 / 进自启动页 / 装·卸·开关之后。
--   **绝不能**塞进 log_append —— 那会变成每写一行日志就读一次 flash（6 次 dd）。
local function as_status_lines()
  local L = {}
  -- ① 启动判定：闸在不在 × 心跳日志末行。
  --   ★ 用户要求（2026-10-04）：**只要有闸是关的，就显示「未启动」，要跑得手动开**。
  --     闸现在只有一只（就是 .autorun.on），所以这一行就是"启动判定"本身：
  --       闸在   ⇒ 已启动（真正的跑发生在下一次开机）
  --       闸不在 ⇒ **未启动** —— 可能是用户自己关的，也可能是上次开机被扣住了，
  --                原因交给下一行（心跳）说清；恢复一律按 [3 开启]。
  local og, ll = gate_on(), log_last()
  L[#L + 1] = og and "开关: 总开关 开 -> 已启动"
    or "开关: 总开关 关 -> 未启动, 按[3]开"
  -- ② 心跳：/data/rc 自己写的那本账（本页**只读**，见文件头）。
  --   "跑到底" = 全部模块跑完 + 窗口 2 过了 + 闸放回来了（末行 cleared）
  --   "没跑到底" = 闸被扣住那一刻的痕迹还在（末行 gate_off）—— 被打断就是这个样子
  L[#L + 1] = (ll == "cleared") and "心跳: 上次开机 跑到底"
    or ((ll == "gate_off") and "心跳: 上次开机 没跑到底 -> 闸被扣住"
      or "心跳: 没有记录 (还没开过机)")
  -- ③ 是否安装：init rc = flash 里那句 `sh /data/rc`
  local gok, gwhy = flash_gate()
  if not gok then
    L[#L + 1] = "安装: flash 停用 (" .. gwhy .. ")"
  else
    local t = flash_probe()
    if not t then
      L[#L + 1] = "安装: 未认出分区 -> 不碰 flash"
    elseif t.state == "==载荷" or t.state == "已装" then
      L[#L + 1] = "安装: init rc 已装 (" .. t.name .. ")"
    elseif t.state == "==原块" or t.state == "原样" then
      L[#L + 1] = "安装: 未装, 分区原样 (" .. t.name .. ") 按 [1 安装]"
    else
      L[#L + 1] = "安装: " .. t.name .. " " .. t.state
    end
  end
  -- ④ 模块状态：装了几个（rc.d 里几个 .sh）/ 会跑几个（/data/rc 里几行生成行）
  local np = 0
  for _, m in ipairs(MODS) do if m.present then np = np + 1 end end
  local st, gen, others = rc_state()
  L[#L + 1] = "模块: 装了 " .. np .. " 个, 会跑 " .. gen .. " 个"
  L[#L + 1] = "rc:   " .. (st == "可读" and ("生成 " .. gen .. " 行, 别人的 " .. others .. " 行")
    or (st == "无" and "不存在 (按 [重建] 会建出来)" or "读不出来 (重建会被拒)"))
  L[#L + 1] = "配置: " .. (CFG_OK and (CFG_FILE .. " 在") or "建不出来 -> 重建会被拒")
  L[#L + 1] = rc_pending() and "重载: ● 待重建 -> 按 [2 重建自启动]"
    or "重载: 已同步"
  return L
end

-- 重算状态摘要 + **立刻重画**自启动页那个框（它不跟着 log_append 刷新）。
-- ★ 赋给**前向声明的那个 local**（所以不写 `local function`）—— set_gate/do_init_*
--   在它**前面**就调它了，写成 `local function` 会让前半段引用到另一个(全局)名字。
function refresh_as_state()
  AS_STATE = as_status_lines()
  if as_log_label then
    as_log_label:set { text = as_box_text(mini_lines_as or 6), text_color = C_DIM }
  end
end

-- [1 安装]：init rc（flash 那半）+ 目录/配置/总开关/rc 一次到位。
-- ★ 日志节奏（2026-10-05）：点击 [安装]（按钮工厂记）-> 各步骤执行/结果逐行 ->
--   最后一行「安装: 完成」绿/黄收尾，成败一眼可见。
local function do_init_install()
  local bad = false
  refresh_all(true)
  local gok, gwhy = flash_gate()
  if not gok then
    armed = ""
    log_append("安装: flash 那半停用 —— " .. gwhy, 0xFF9A9A)
    log_append("-> 文件那半照样装; 但 hook 不装, 开机不会跑 /data/rc", 0xFFD27A)
  elseif armed ~= "install" then
    local t, probe = flash_probe()
    log_append("init rc 探测: " .. tostring(probe), 0xFFD27A)
    if t and t.state == "==载荷" then
      -- ★ flash 已经是载荷 -> hook 装着了、没什么可写的 ⇒ **不用二次确认**，
      --   直接落到文件那半（把目录/配置/总开关/rc 再对一遍）。
      --   旧文案一律说"再按一次才写"，用户按几次都以为"安装没生效"（真机 2026-10-04 踩到）。
      log_append("认出 " .. t.name .. " (==载荷) -> hook 已经装着了, 不用再按 (已是载荷)", 0x8FF0A4)
    else
      armed = "install"
      log_append(t and ("认出 " .. t.name .. " (" .. t.state .. ") -> 再按一次 [1 安装] 才写 flash")
        or "没有认出的块 -> 再按一次也不会写 flash", 0xFFD27A)
      refresh_status()
      refresh_as_state()    -- 探测不改状态, 但面板可能还是开机那一刻的 -> 顺手对上
      return
    end
  end
  armed = ""
  if gok then
    local ok, why = hook_install()
    log_append("init rc: " .. (ok and "装好 (" or "失败 (") .. tostring(why) .. ")",
      ok and 0x8FF0A4 or 0xFF9A9A)
    if not ok then bad = true end
  else
    log_append("init rc: 跳过 (门未过)", 0xFFD27A)
  end
  if ensure_config() then
    log_append("目录/配置: " .. RC_DIR .. " + " .. CFG_FILE .. " 就位", 0x8FF0A4)
  else
    log_append("目录/配置: 建不出来 " .. CFG_PATH, 0xFF9A9A)
    bad = true
  end
  -- ★ [1 安装] 是"我要自启动"的明确动作 -> 撤掉"用户关过"的凭据，并把总开关**打开**。
  --   v0.6.5：以前这里只删凭据，把"开开关"托给 ensure_gate 的推断；而它看到 rc 里有门
  --   就不建 ⇒ 日志说"打开"、实际还是关的（真机 2026-10-04 的"自启动不生效"）。
  --   现在**直接写、按结果说话**，不经过任何推断。
  if exists(GATE_OFF) then
    exec("rm -f " .. GATE_OFF)
    log_append("总开关: 你之前关过, [1 安装] 按要自启动处理 -> 打开", 0xFFD27A)
  end
  if not exists(GATE) and write_file(GATE, "on\n") then
    log_append("总开关: 已打开 (" .. GATE .. ")", 0x8FF0A4)
  end
  if not exists(GATE) then
    log_append("总开关: 打不开 " .. GATE .. " -> 开机会不跑 /data/rc", 0xFF9A9A)
    bad = true
  end
  if CFG_OK then
    do_rebuild()
  else
    log_append("-> 配置不可用, 不重建 /data/rc", 0xFF9A9A)
    bad = true
    refresh_status() render_rows()
  end
  -- ★ flash 那半刚动过 -> 面板上的「安装:」必须重读一次（这一下读 flash 值得）
  refresh_as_state()
  log_append(bad and "安装: 完成 (有失败项, 看上面红行)" or "安装: 完成",
    bad and 0xFFD27A or 0x8FF0A4)
end

-- [2 卸载]：把 init rc 还原回原样（flash 那半）+ 删总开关。
-- ★ 不删 autorun.json（那是策略，也是"你配过什么"的唯一记录）、不删 /data/rc、
--   不删任何模块脚本 —— 下次 [1 安装] 就能原样接回去。日志会逐条说清删了什么。
local function do_init_remove()
  local bad = false
  refresh_all(true)
  local gok, gwhy = flash_gate()
  if not gok then
    armed = ""
    log_append("卸载: flash 那半停用 —— " .. gwhy, 0xFF9A9A)
  elseif armed ~= "remove" then
    local t, probe = flash_probe()
    log_append("init rc 探测: " .. tostring(probe), 0xFFD27A)
    if t and t.state == "==原块" then
      -- ★ flash 本来就是原样 -> 没东西可还原 ⇒ **不用二次确认**，直接落到文件那半
      --   （总开关还是要删的 —— [2 卸载] 的语义是"退回不要自启动"）。
      log_append("认出 " .. t.name .. " (==原块) -> hook 本来就是原样, 不用再按 (无需还原)", 0x8FF0A4)
    else
      armed = "remove"
      log_append(t and ("认出 " .. t.name .. " (" .. t.state .. ") -> 再按一次 [2 卸载] 才还原")
        or "没有认出的块 -> 再按一次也不会动 flash", 0xFFD27A)
      refresh_status()
      refresh_as_state()
      return
    end
  end
  armed = ""
  if gok then
    local ok, why = hook_restore()
    log_append("init rc: " .. (ok and "已还原 (" or "失败 (") .. tostring(why) .. ")",
      ok and 0x8FF0A4 or 0xFF9A9A)
    if not ok then bad = true end
  else
    log_append("init rc: 跳过 (门未过)", 0xFFD27A)
  end
  exec_logged("rm -f " .. GATE, "删除总开关 " .. GATE)
  if exists(GATE) then
    log_append("总开关: 删不掉 " .. GATE, 0xFF9A9A)
    bad = true
  else
    -- ★ 卸载 = 明确不要自启动 -> 留凭据，别让下一次 [重建] 又把它补建回来。
    write_file(GATE_OFF, "off\n")
    log_append("总开关: 已删 (" .. GATE .. ")", 0x8FF0A4)
  end
  log_append("保留: " .. CFG_FILE .. " / /data/rc / 各模块脚本 (一个字节都没动)")
  log_append("-> 下次开机不会再跑 /data/rc", 0xFFD27A)
  refresh_status() render_rows()
  refresh_as_state()
  log_append(bad and "卸载: 完成 (有失败项, 看上面红行)" or "卸载: 完成",
    bad and 0xFFD27A or 0x8FF0A4)
end

-- ===================== UI =====================

local rootbase = lvgl.Object(nil, {
  w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = C_BG,
  bg_opa = lvgl.OPA(100), border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
local root = lvgl.Object(rootbase, {
  w = W, h = H, bg_color = C_BG, bg_opa = lvgl.OPA(100),
  border_width = 0, pad_all = 0, align = lvgl.ALIGN.CENTER,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

local function make_page()
  local page = lvgl.Object(root, {
    w = W, h = H, bg_color = C_BG, bg_opa = lvgl.OPA(100),
    border_width = 0, pad_all = 0,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = PAGE_HIDE },
  })
  page:clear_flag(lvgl.FLAG.SCROLLABLE)
  return page
end

local main_page      = make_page()
local autostart_page = make_page()
local modules_page   = make_page()
local log_page       = make_page()
local PAGES = { main_page, autostart_page, modules_page, log_page }

local function show_only(target)
  for _, page in ipairs(PAGES) do
    page:set { align = { type = lvgl.ALIGN.CENTER, x_ofs = 0,
      y_ofs = (page == target) and 0 or PAGE_HIDE } }
  end
end
-- ★ 每次切页都清 `armed`：["安装"/"卸载"] 的两段式闸门**不许跨页存活** ——
--   否则"按了一次安装、退出去看一眼日志、回来再按一下"就会直接写 flash。
local function show_main()      armed = "" show_only(main_page)      refresh_status() end
local function show_autostart()
  armed = ""
  show_only(autostart_page)
  refresh_status()
  -- ★ 进这个页就重读一次状态摘要 —— 里面的「安装:」要读 flash（只读探测，不写）。
  --   面板只在**明确时刻**刷（这里是其中之一），不跟 log_append 走。
  refresh_as_state()
end
-- 「列表为空」只报一次：show_modules 每次切页都会被调，不设闸会把日志刷满。
local warned_empty = false
local function show_modules()   armed = "" show_only(modules_page)   render_rows()
  if mod_list_top then mod_list_top() end
  -- ★ 用户要的是"没安装就不显示"——不显示是对的，但光有一片空白说不清**为什么**空。
  --   （"一条都没有"和"读了但没读出来"在界面上一模一样。）这里补一句话，只说一次。
  if #MODS == 0 and not warned_empty then
    warned_empty = true
    log_append("模块列表为空: " .. RC_DIR .. " 里没有 .sh, /data/rc 里也没有模块行", 0xFFD27A)
  end
end
local function show_log()       armed = "" show_only(log_page)       scroll_log_bottom() end

-- ---------- 日志页 ----------
local back_log = lvgl.Object(log_page, {
  w = 120, h = 44, bg_color = C_SLATE, bg_opa = lvgl.OPA(100), radius = 12, pad_all = 0,
  align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 12, y_ofs = 10 },
})
back_log:clear_flag(lvgl.FLAG.SCROLLABLE)
back_log:add_flag(lvgl.FLAG.CLICKABLE)
lvgl.Label(back_log, {
  text = "< 返回", text_color = C_TXT, align = lvgl.ALIGN.CENTER,
  text_font = lvgl.Font(F_BODY, 20),
})
back_log:onClicked(show_main)

local clear_button = lvgl.Object(log_page, {
  w = 106, h = 44, bg_color = C_DRED, bg_opa = lvgl.OPA(100), radius = 12, pad_all = 0,
  align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 142, y_ofs = 10 },
})
clear_button:clear_flag(lvgl.FLAG.SCROLLABLE)
clear_button:add_flag(lvgl.FLAG.CLICKABLE)
lvgl.Label(clear_button, {
  text = "清空", text_color = C_TXT, align = lvgl.ALIGN.CENTER,
  text_font = lvgl.Font(F_BODY, 20),
})
clear_button:onClicked(function()
  log_lines, log_seq = {}, 0
  local f = io.open(MGR_LOG, "w")
  if f then f:write("") pcall(f.close, f) end
  -- 三个地方看到的必须是**同一份**：留个 00 号占位，别让两个小窗显示"(就绪)"那种假状态。
  log_lines = { "00  日志已清空" }
  if log_label then
    log_label:set { text = log_lines[1], text_color = C_DIM }
  end
  log_mini(C_DIM)
end)

-- ★ 标题带只放得下三个控件：返回 12..132 / 清空 142..248 / 标题 256..324。
--   上一版标题写在 x=236、宽 100 ⇒ 234..324，**压住清空键 16px**（用户报的"标题重合"）。
--   现在 256 起、宽 68（两个字 + 边距），与清空键留 8px 缝。
lvgl.Label(log_page, {
  text = "日志", text_color = C_TXT, text_font = lvgl.Font(F_BOLD, 24),
  width = 68, align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 256, y_ofs = 20 },
})

local log_body = lvgl.Object(log_page, {
  w = 336, h = 414, bg_color = C_CARD, bg_opa = lvgl.OPA(100),
  radius = 0, border_width = 1, border_color = C_LINE,
  pad_left = 10, pad_right = 10, pad_top = 8, pad_bottom = 8,
  align = { type = lvgl.ALIGN.TOP_MID, x_ofs = 0, y_ofs = 66 },
})
log_body:add_flag(lvgl.FLAG.SCROLLABLE)
log_label = lvgl.Label(log_body, {
  text = "(还没有事件)", text_color = C_DIM, width = 296,
  text_font = lvgl.Font(F_BODY, 18),
  align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 0, y_ofs = 0 },
})
scroll_log_bottom = function()
  pcall(function() log_body:scroll_by_bounded(0, -100000, 0) end)
end

-- ---------- 模块管理页 ----------
-- 几何预算（逐像素算）：
--   标题带 0..56 / 返回键 10..54 / 列表窗 62..402 / 功能条 406..452
--   行 50 高 + 6 间距 = 56 步长 ⇒ 一屏 6 行 = 336 ≤ 340 ✓
-- ★ 翻页方式（按用户要求，2026-10-04）：**滚动翻页**。上一页/下一页两个键去掉，
--   换成「全部启用 / 重建 / 全部禁止」三个功能键。
-- ★ 行仍然是**预建的固定 ROW_POOL 行**（只改文本与颜色）—— 本项目的 LVGL Lua 上
--   "动态增删子对象"和"隐藏子对象"都没验过，不能用。所以列表本身是个可滚容器，
--   一屏看得见 ROWS_VISIBLE 行；模块比 ROW_POOL 还多时按 ROW_POOL 截断，并在日志里说。
local back_mod = lvgl.Object(modules_page, {
  w = 120, h = 44, bg_color = C_SLATE, bg_opa = lvgl.OPA(100), radius = 12, pad_all = 0,
  align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 12, y_ofs = 10 },
})
back_mod:clear_flag(lvgl.FLAG.SCROLLABLE)
back_mod:add_flag(lvgl.FLAG.CLICKABLE)
lvgl.Label(back_mod, {
  text = "< 返回", text_color = C_TXT, align = lvgl.ALIGN.CENTER,
  text_font = lvgl.Font(F_BODY, 20),
})
back_mod:onClicked(show_main)

-- ★ 标题带上带项数：滚动翻页之后没有"x/y"页码了，"一共几项"必须还在某处看得见。
--   宽度算过：font 24 下 4 个汉字 96px + " 12" 约 26px = 122 ≤ 130 ✓
local mod_title = lvgl.Label(modules_page, {
  text = "模块管理 0", text_color = C_TXT, text_font = lvgl.Font(F_BOLD, 24),
  width = 130, align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 196, y_ofs = 18 },
})

local ROWS = {}

-- 可滚列表容器：312 × 340 落在屏幕 62..402 之间，内容高 = ROW_POOL 行 × 56。
-- ★ SCROLLABLE 只加在**这个容器**上（页面本身在 make_page 里已经 clear_flag 掉了）。
local mod_list = lvgl.Object(modules_page, {
  w = 312, h = 340, bg_color = C_BG, bg_opa = lvgl.OPA(100),
  radius = 0, border_width = 0, pad_all = 0,
  align = { type = lvgl.ALIGN.TOP_MID, x_ofs = 0, y_ofs = 62 },
})
mod_list:add_flag(lvgl.FLAG.SCROLLABLE)

-- ★ 行内布局（**按像素算**，312×50 的方框，内边距 0）——
--   用户 2026-10-04 报"chaos 文字 / 允许 文字 / 方框没对齐"，根因是**行对象没写 pad_all**：
--   走平台默认内边距 ⇒ 三个 TOP_LEFT 标签被整体推向右下，而"允许"原本 x=204 宽 96（到 300）
--   ⇒ 越过内容区右边界，看起来跟名字和方框都不齐。
--   ★ 已验证的参考实现（chaos 安装器）**每个容器都显式写 pad_all = 0**，从不赌默认值。
--   现在三个标签一律 **CENTER 对齐 + 显式宽高**，位置由**方框中心**(156, 25) 反推，
--   不再依赖字体度量（即使平台忽略 height，按 18/13/16 号字的自然行高也落在同一格里）：
--     名字 180×24 中心(102,14) ⇒ x_ofs = 102-156 = -54, y_ofs = 14-25 = -11
--     描述 180×18 中心(102,38) ⇒ x_ofs = -54,           y_ofs = 38-25 = +13
--     状态  96×22 中心(252,25) ⇒ x_ofs = 252-156 = +96, y_ofs = 0（垂直居中）
--   左右边距各 12：名字/描述 12..192、状态 204..300 —— 这才叫"和方框对齐"。
for i = 1, ROW_POOL do
  local row = lvgl.Object(mod_list, {
    w = 312, h = ROW_H, bg_color = C_CARD, bg_opa = lvgl.OPA(100), radius = 12,
    border_width = 1, border_color = C_LINE, pad_all = 0,
    align = { type = lvgl.ALIGN.TOP_MID, x_ofs = 0, y_ofs = (i - 1) * (ROW_H + ROW_GAP) },
  })
  row:clear_flag(lvgl.FLAG.SCROLLABLE)
  row:add_flag(lvgl.FLAG.CLICKABLE)
  local name_lbl = lvgl.Label(row, {
    text = "", text_color = C_TXT, width = 180, height = 24,
    text_font = lvgl.Font(F_BODY, 18),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = -54, y_ofs = -11 },
  })
  local desc_lbl = lvgl.Label(row, {
    text = "", text_color = C_TXT3, width = 180, height = 18,
    text_font = lvgl.Font(F_BODY, 13),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = -54, y_ofs = 13 },
  })
  local st_lbl = lvgl.Label(row, {
    text = "", text_color = C_DIM, width = 96, height = 22,
    text_font = lvgl.Font(F_BODY, 16),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 96, y_ofs = 0 },
  })
  local slot = i
  row:onClicked(function()
    -- ★ 滚动之后"行号 == 模块下标"，不再有页码偏移（page_no 已经删掉了）。
    local m = MODS[slot]
    if m then toggle_mod(m.name) end
  end)
  ROWS[i] = { row = row, name = name_lbl, desc = desc_lbl, st = st_lbl }
end

-- 列表回到顶部。★ 与日志页"滚到底"是同一个 API 的两个方向：那里用 -100000，
--   这里用 +100000（bounded 会自己夹住）。
mod_list_top = function()
  pcall(function() mod_list:scroll_by_bounded(0, 100000, 0) end)
end

-- 功能条：全部启用 / 重建 / 全部禁止（312 = 100×3 + 6×2）
-- ★ logname 同 make_button：动作键点击先记「点击 [xxx]」。
local function make_bar_button(text, x_ofs, color, fn)
  local b = lvgl.Object(modules_page, {
    w = 100, h = 46, bg_color = color, bg_opa = lvgl.OPA(100), radius = 12,
    pad_all = 0,
    align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = x_ofs, y_ofs = 406 },
  })
  b:clear_flag(lvgl.FLAG.SCROLLABLE)
  b:add_flag(lvgl.FLAG.CLICKABLE)
  lvgl.Label(b, {
    text = text, text_color = C_TXT, align = lvgl.ALIGN.CENTER,
    text_font = lvgl.Font(F_BODY, 18),
  })
  b:onClicked(function()
    log_append("点击 [" .. text .. "]", 0xBFD9FF)
    local ok, message = pcall(fn)
    if not ok then log_append("Error: " .. tostring(message), 0xFF9A9A) end
    scroll_log_bottom()
  end)
  return b
end

make_bar_button("全部启用", 12,  C_GREEN, function() set_all(true)  end)
make_bar_button("重建",     118, C_RED,   do_rebuild)
make_bar_button("全部禁止", 224, C_DRED,  function() set_all(false) end)

local warned_pool = false
function render_rows()
  for i = 1, ROW_POOL do
    local cell = ROWS[i]
    local m = MODS[i]
    if not m then
      -- 空行：只把颜色抹成页面底色。★ 不能"删掉/隐藏"子对象 —— 本项目的 LVGL Lua
      -- 上没验过（add_flag(HIDDEN) 这种在假 lvgl 里也没有，赌它存在就是赌崩）。
      -- 代价说清：滚到底会看到一段同样的空白。ROW_POOL 就是"能显示的上限"。
      cell.row:set { bg_color = C_BG, border_color = C_BG }
      cell.name:set { text = "", text_color = C_BG }
      cell.desc:set { text = "", text_color = C_BG }
      cell.st:set   { text = "", text_color = C_BG }
    else
      local st_text, st_color
      -- ★ 列表来源已经保证："not present" ⟺ 它是从 /data/rc 的生成行认出来的
      --   （rc.d 里那个 .sh 不在了）。所以这里判 not present 就等于用户要的
      --   「只有当 /data/rc 里有那一行、而 rc.d 里没有脚本时，才显示缺脚本」。
      --   按 [重建] 之后那一行被删 ⇒ 下次刷新它就整个从列表里消失（不再常驻）。
      if m.core then st_text, st_color = "核心", C_GRAY
      elseif not m.present then st_text, st_color = "缺脚本", C_GRAY
      elseif m.enable then st_text, st_color = "允许", C_GREEN
      else st_text, st_color = "禁止", C_DRED end
      cell.name:set { text = one_line(m.name, 16), text_color = C_TXT }
      cell.desc:set { text = one_line(m.desc ~= "" and m.desc
        or string.format("order %d · delay %d", m.order, m.delay), 22),
        text_color = C_TXT3 }
      cell.st:set { text = st_text, text_color = st_color }
      cell.row:set { bg_color = C_CARD, border_color = C_LINE }
    end
  end
  if mod_title then
    mod_title:set { text = string.format("模块管理 %d", #MODS), text_color = C_TXT }
  end
  -- 超过列表上限时**必须说**：看不见的模块等于"禁不掉"。只说一次（render_rows 会反复被调）。
  if #MODS > ROW_POOL and not warned_pool then
    warned_pool = true
    log_append(string.format("模块 %d 个 > 列表上限 %d -> 只显示前 %d 个",
      #MODS, ROW_POOL, ROW_POOL), 0xFFD27A)
  end
end

-- ---------- 按钮工厂（四页共用） ----------
-- ★ 改签名：第一参数是**父页**。上一版写死 main_page ⇒ 自启动页根本挂不上按钮。
--   坐标一律是 y_ofs/x_ofs（CENTER 对齐 = 中心点偏移），下面每处都算过账。
-- ★ logname（可选）：动作按钮传名字 -> 点击时先记一条「点击 [xxx]」，把用户的
--   日志节奏（点击 -> 执行 -> 输出 -> 成败）钉在每一拍上。导航键（返回/翻页）
--   不传 —— 切页本身就是反馈，记了全是噪音。
local function make_button(parent, text, y, x, w, h, color, fn, font_size, logname)
  local button = lvgl.Object(parent, {
    w = w, h = h, bg_color = color, bg_opa = lvgl.OPA(100), radius = 16,
    pad_all = 0,   -- ★ 显式 0：不赌平台默认内边距（参考实现每个容器都这么写）
    align = { type = lvgl.ALIGN.CENTER, x_ofs = x, y_ofs = y },
  })
  button:clear_flag(lvgl.FLAG.SCROLLABLE)
  button:add_flag(lvgl.FLAG.CLICKABLE)
  lvgl.Label(button, {
    text = text, text_color = C_TXT, align = lvgl.ALIGN.CENTER,
    text_font = lvgl.Font(F_BODY, font_size or 20),
  })
  button:onClicked(function()
    if logname then log_append("点击 [" .. logname .. "]", 0xBFD9FF) end
    local ok, message = pcall(fn)
    if not ok then log_append("Error: " .. tostring(message), 0xFF9A9A) end
    scroll_log_bottom()
  end)
  return button
end

-- 「铺满下屏」的日志小窗（主页 + 自启动页各一个）。
-- ★ 标签 TOP_LEFT + 定宽 288：每条日志在 tail_list 里已经按像素宽度截成一行，
--   所以这里**不会折行**；放几行由**框高**算（mini_lines_of）⇒ 一直铺到框底。
-- ★ 返回 (标签, 这个框能放几行)：行数必须在**建框的这一刻**算出来，log_mini 只认它。
local function make_mini_box(parent, y_ofs, h)
  local box = lvgl.Object(parent, {
    w = 312, h = h, bg_color = C_CARD, bg_opa = lvgl.OPA(100),
    radius = 12, border_width = 1, border_color = C_LINE,
    pad_left = 10, pad_right = 10, pad_top = MINI_PAD, pad_bottom = MINI_PAD,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y_ofs },
  })
  box:clear_flag(lvgl.FLAG.SCROLLABLE)
  local label = lvgl.Label(box, {
    text = "(就绪)", text_color = C_DIM, text_font = lvgl.Font(F_BODY, 14),
    width = 288, align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 0, y_ofs = 0 },
  })
  return label, mini_lines_of(h)
end

-- ---------- 主页 ----------
-- 布局账（480 高；CENTER 对齐 ⇒ y_ofs = 想要的**中心** - 240）：
--   标题 h44 顶 24 -> 中心 46 -> -194      副标题 h28 顶 72 -> 中心 86 -> -154
--   键行1 h48 顶 110 -> -106               键行2 h48 顶 166 -> -50
--   状态 h22 顶 220 -> -9                  日志框 h214 顶 252 -> 119（底 466）
lvgl.Label(main_page, {
  text = "10pro.autorun", text_color = C_TXT, text_font = lvgl.Font(F_BOLD, 30),
  width = 320, height = 44,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -194 },
})
lvgl.Label(main_page, {
  text = "多模块开机自启管理", text_color = C_DIM,
  text_font = lvgl.Font(F_BODY, 18),
  width = 320, height = 28,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -154 },
})

status_label = lvgl.Label(main_page, {
  text = "(状态)", text_color = C_TXT3, text_font = lvgl.Font(F_BODY, 14),
  width = 316, height = 22,
  align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -9 },
})

-- ★ 主页只留 4 个键（按用户要求，2026-10-04）：接管/全部允许/全部禁止都搬走了。
--   两个 152 宽的键：左 12..164、右 172..324（COL_X=80 ⇒ 中心 88 / 248）。
local COL_W, COL_X = 152, 80
local ROW1, ROW2 = -106, -50

make_button(main_page, "1  自启动管理", ROW1, -COL_X, COL_W, 48, C_BLUE,  show_autostart, 20)
make_button(main_page, "2  重建自启动", ROW1,  COL_X, COL_W, 48, C_RED,   do_rebuild,     20, "重建自启动")
make_button(main_page, "3  模块管理",   ROW2, -COL_X, COL_W, 48, C_SLATE, show_modules,   20)
make_button(main_page, "4  日志",       ROW2,  COL_X, COL_W, 48, C_OLIVE, show_log,       20)

mini_log_label, mini_lines_main = make_mini_box(main_page, 119, MINI_BOX_H_MAIN)

-- ---------- 自启动页（init rc + 总开关）----------
-- 布局账：返回键 10..54 / 标题带同行；键行1 h48 顶 66 -> -150；键行2 h48 顶 122 -> -94；
--         日志框 h290 顶 178 -> 83（底 468，比主页那个更大，铺满下屏）。
local back_as = lvgl.Object(autostart_page, {
  w = 120, h = 44, bg_color = C_SLATE, bg_opa = lvgl.OPA(100), radius = 12, pad_all = 0,
  align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 12, y_ofs = 10 },
})
back_as:clear_flag(lvgl.FLAG.SCROLLABLE)
back_as:add_flag(lvgl.FLAG.CLICKABLE)
lvgl.Label(back_as, {
  text = "< 返回", text_color = C_TXT, align = lvgl.ALIGN.CENTER,
  text_font = lvgl.Font(F_BODY, 20),
})
back_as:onClicked(show_main)

lvgl.Label(autostart_page, {
  text = "自启动", text_color = C_TXT, text_font = lvgl.Font(F_BOLD, 24),
  width = 80, align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 244, y_ofs = 20 },
})

local AS_ROW1, AS_ROW2 = -150, -94
make_button(autostart_page, "1  安装", AS_ROW1, -COL_X, COL_W, 48, C_GREEN, do_init_install, 20, "安装")
make_button(autostart_page, "2  卸载", AS_ROW1,  COL_X, COL_W, 48, C_DRED,  do_init_remove,  20, "卸载")
make_button(autostart_page, "3  开启", AS_ROW2, -COL_X, COL_W, 48, C_BLUE,
  function() set_gate(true) end, 20, "开启")
make_button(autostart_page, "4  关闭", AS_ROW2,  COL_X, COL_W, 48, C_SLATE,
  function() set_gate(false) end, 20, "关闭")

as_log_label, mini_lines_as = make_mini_box(autostart_page, 83, MINI_BOX_H_AS)

-- ===================== 启动 =====================
show_main()
log_restore()
log_append("--- 10pro.autorun 管理器启动 ---")

exec("mkdir -p " .. DATA_DIR)
local summary = refresh_all(true)
log_append("扫描: " .. summary)

-- ★ 配置就在注册目录里，所以这里只报"在不在"和"建不出来"两种情况。
--   注意：**不再有任何自动重建** —— 打开表盘不会写 /data/rc。
if CFG_OK then
  log_append("配置: " .. CFG_PATH, 0x8FF0A4)
else
  log_append("配置建不出来: " .. CFG_PATH .. " -> 重建会被拒绝", 0xFF9A9A)
end

local _st, gen, others = rc_state()
log_append(string.format("/data/rc: 生成 %d 行, 别人的 %d 行", gen, others),
  others > 0 and 0xFFD27A or 0x8FF0A4)
if others > 0 then
  log_append("有别人的行 -> 原样保留, 不管不碰 (接管已删)", 0xFFD27A)
end
-- ★ 闸关着时必须一眼看见：否则"我明明允许了它、它却不跑"没人能想明白。
--   （闸独立于逐模块开关，状态行 / 自启动页都有，但开机那一刻最该说清。）
--   ★ 顺便把**为什么关**说清：心跳末行 gate_off = 上次开机被扣住了（被打断）——
--     这时候界面上一片平静、日志也没有报错，最该提醒"它一次都没跑起来"。
if not gate_on() then
  log_append("自启动闸: 关 -> 开机不跑任何模块"
    .. ((log_last() == "gate_off") and " (心跳末行 gate_off: 上次没跑到底)" or "")
    .. " —— 自启动页 [3 开启]", 0xFFD27A)
end
-- ★ 落后于配置时必须当场说清楚，否则"上次改了开关、这次开机没生效"没人知道为什么。
if CFG_OK and rc_pending() then
  log_append("配置与 /data/rc 不一致 -> 按 [2 重建自启动] 落盘", 0xFFD27A)
end
-- ★ 自启动页那块**状态摘要**在这里先算一次（里面有一次 flash 只读探测：是否安装）。
--   之后每条日志都会按它重画面板（log_mini -> as_box_text），所以必须排在 Ready 之前。
refresh_as_state()
log_append("Ready")
refresh_status()
render_rows()
scroll_log_bottom()
