# 自启动适配指南 —— 以 Chaos 模块为例

- 日期：2026-10-04
- 对象：小米手环 10 Pro（p67tc）/ 固件 **3.101.043** / openvela(NuttX) + LVGL
- 本机实测产物：`Chaos自启动安装器.face`（305,836 B，md5 `c89fcca5a77c2fa9b4771188cde21d18`）
- 相关文档：`ANALYSIS.md`（地址核对）/ `PATCH.md`（本次实施细节）/ `AUTOSTART.md`（rc 语义）/ `FACE.md`（表盘打包）

本文回答三件事：

1. **为了自启动，改了哪些东西**（第 2、3 节）；
2. **每一处怎么改**（第 4 节，代码级）；
3. **换成别的同类型模块该怎么做**（第 5 节，含决策表与逐步判据）。

> **一句话总结**：改了两处 —— ① 模块里加一套"延迟命令号（DQ）"，把会挂死的调用从
> `sh` 任务搬到 **UI 线程的 `lv_timer` 回调**里跑；② 安装器 Lua 里写 `/data/chaos/rc` +
> 开关文件 + 往 `/data/rc` 追加一行二跳，并且**把固件 `rcS` 末行的 `exit` 改成 `sh /data/rc &`**
> （v1 缺这步 ⇒ 前两条永远不生效）。再把它打进一枚 `.face` 表盘送进设备。

---

## 1 一次开机到底发生了什么

先看全貌，后面每一节都是这张图里的一格。

| # | 谁在跑 | 干什么 | 落在哪 |
|---|---|---|---|
| 1 | 固件 init（**sh 任务**） | 跑 `/etc/init.d/{rc.sysinit,rcS}` | 固件镜像里，**原版末行是 `exit`** |
| 2 | 同上 | rcS 末行是 `sh /data/rc &` ⇒ 拉起 `/data/rc` | ★ **v2 写进 flash 的那 18 字节** |
| 3 | 同上 | 跑 `/data/rc` → 我们追加的那行 → `sh /data/chaos/rc &` | `/data/rc` 末尾一行 |
| 4 | 同上 | `/data/chaos/rc`：判开关 → 删开关 → `sleep 8` → `insmod sup.ko` → `dd` 16 B 命令帧 → `sleep 15` → 回读 → 重建开关 | `/data/chaos/rc`（Lua 现生成） |
| 5 | **ko 的 write 回调**（仍在 sh 任务） | 认出 `CMD_BOOT_DQ` ⇒ **只建一台 UI 线程定时器 + 打游标，立刻返回** | 模块内存 |
| 6 | **UI 任务**（`lv_timer` 回调，1 s 一拍） | `0x18` 设中文 → `0x13` 完整注册链 → `0x22` 回读槽统计 → 切 60 s 周期 | 模块内存 |
| 7 | 固件 launcher | 收到 notify，桌面出现 Chaos 条目 | 固件 |

**为什么要有第 5/6 步之间的这次"绕道"**，见第 2 节 —— 那是整个自启动唯一真正难的地方。

---

## 2 三条上机前必须先接受的定案

### 2.1 ★ 崩点是**调用语境**，不是调用内容

同一个函数、同一份参数：

| 从哪调 | 结果（同机同固件真机实测） |
|---|---|
| `sh` / `nsh` 任务里**同步**调固件注册链 | `write()` **不返回** → `rtc_watchdog` **硬重启** |
| 同一个调用由 `lv_timer` 回调（**UI 任务**）执行 | **正常返回** |
| 从 `sh` 任务里建 `lv_timer`（`lv_timer_create`） | **安全** —— `watchface.rs` 本来就是这么干的 |

⇒ 所以 rc 里的 `dd` 只能"**入环即返回**"，真正的活在 UI 任务里按拍做。
这条是本项目的**核心定案**：换任何模块，第一步都应该是**自己复现这一次**（见 5.1），
不要凭"看起来一样"就照抄。

### 2.2 ★ `/data/rc` **不是固件自己会跑的**

| 事实 | 证据 |
|---|---|
| 固件里**没有任何**"免写 flash"的开机钩子 | init 脚本只认 `/etc/init.d/{rc.sysinit,rcS}`；`/data` 下没有脚本钩子；quickapp 注册表没有 `autostart` 字段；全镜像唯一的脚本路径 `/init.lua` 只是 Lua 的默认 `LUA_PATH` |
| 原版 rcS **末行就是 `exit`** | rcS 正文 @`0xc06512`，尾部 `b'at_cmd &\nexit\n'` |
| `/data/rc` 在整枚固件里**出现 0 次** | 直接搜原始 `vela_ap.bin`（13,795,728 B） |

⇒ **不改固件的话，你往 `/data/rc` 写什么都永远不会被执行**；表现是
"每一步都报成功、开机什么都不发生"（而且是静默的）。唯一解法 = **改 rcS 末行，写 flash**。

### 2.3 ★ 防砖只有一条机制：开关先删后建

`/data/chaos/rc` 的开头先 `rm -f autostart.on`，**整段（含 15 s 安全窗）走完才**
`echo on > autostart.on`。于是开机的任何一刻掉电 / 看门狗 / 主动重启，
开关都停在**【关】**，下次开机整段跳过 —— 这就是防砖的全部机制，不要加别的花活。

---

## 3 改了哪些东西（清单）

| 位置 | 文件 | 改了什么 | 大小 |
|---|---|---|---|
| 模块 | `supervisor/src/ipc.rs` | ① 派发段**搬移**成独立函数；② 新增 DQ 三件套；③ `chaos_write` 的 match 加一支 | 19,696 → **23,731 B** |
| 模块 | `supervisor/src/_moved_block.txt` | 搬走段落的原文留底（供逐字节比对） | 新增 3,098 B |
| 安装器 | `installer/chaos_installer.lua` | ① `/data` 侧自启动（rc / 命令帧 / 开关 / 二跳）；② flash rcS hook；③ UI 从 4 个按钮变 5 个 | 21,691 → **115,170 B** |
| 打包 | `face/make_chaos_face.py` | 把上面两份 + 应用图标打成 `.face`，100 项判据 | 新增 |
| 交付 | `Chaos自启动安装器.face` | 表盘容器（设备走侧载通道装） | 305,836 B |

**没有改的**：驱动节点名 / 状态块长度 192 / 14 个页面 / quickapp 注册表 / 改 flash 之外的固件分区。

---

## 4 每一处怎么改（代码级）

### 4.1 模块侧 ① —— 把派发段搬出来（**一字未改**）

`chaos_write` 里原本内联着这段"arg0 派发 + 尾部槽位四词"：

```rust
match arg0 {
    0    => { fops_wr(FOPS_STEP, 0); cmd_install(0x12); }   // 注册链(止于 init_buffer)
    1 | 2 => { /* no-op publish */ }
    0x13 => { fops_wr(FOPS_STEP, 0); cmd_install(0x13); }   // 完整注册链
    0x43 => { fops_wr(FOPS_STEP, 0); notify_firmware_full(); }
    0x18 => { st_wr!(LANG, 1); }  0x19 => { st_wr!(LANG, 0); }
    0x22 => { /* 回读槽统计 -> DBG0/1/2 */ }
    0x30 => { /* 字体投递, 用 arg1 带目标池位 */ }
    _   => {}
}
fops_wr(FOPS_SLOTS, ST_ACTIVE);  // 尾部四词
```

把它**原样**搬成一个函数（`ipc.rs:358`）：

```rust
/// 安装流程的 arg0 派发 + 尾部槽位四词。
/// **从 chaos_write 里原样搬出来的, 一字未改** —— 派发路径与 write 路径共用同一份代码,
/// 绝不允许出现第二份实现。arg1 只有 0x30(字体投递)用。
unsafe fn run_install_cmd(arg0: u32, arg1: u32) { /* 原封不动那段 */ }
```

`chaos_write` 的 match 变成一行：

```rust
match cmd {
    CMD_INSTALL => run_install_cmd(arg0, arg1),
    CMD_BOOT_DQ => { let _ = dq_start(); }
    _ => {}
}
```

> **为什么要搬**：DQ 派发和 write 派发必须走**同一份**实现。抄第二份的那天起，
> 两条路的命令语义就会开始漂。搬移的判据不是"看起来一样"，而是
> **把函数体减掉 4 格缩进必须与 `_moved_block.txt` 逐字节相同**（见 5.9 G2 门）。

### 4.2 模块侧 ② —— DQ 三件套

```rust
/// "3CHS", 与 CMD_MAGIC("1CHS") / STATUS_MAGIC("2CHS") 同一命名法。rc 里只发这一条。
pub const CMD_BOOT_DQ: u32 = 0x5348_4333;

/// 触发后按拍跑的序列(与安装器 Lua 的 pipeline 同序, 只留真正有固件调用的那几条):
///   0x18 = 设中文 —— 纯 BSS 写; 开机 BSS 清零, 所以必须每开一次机重设
///   0x13 = 完整注册链(内部已含 init_buffer 与 notify_firmware_full)
///   0x22 = 回读槽统计, 给"注册是否真生效"提供 d0/d1/d2 读数
static DQ_SEQ: [u32; 3] = [0x18, 0x13, 0x22];

const DQ_PERIOD_MS: u32 = 1000;  // 跑序列时(= 安装器 Lua 的原周期)
const DQ_IDLE_MS:   u32 = 60000; // 跑完切慢 —— 常驻 lv_timer 不许用固定频率(续航红线)
const DQ_TRIES_MAX: u32 = 8;

static mut DQ_STEP:  u32 = 0;   // 0 = 空闲; n = 下一个要跑 DQ_SEQ[n-1]
static mut DQ_TRIES: u32 = 0;
static mut DQ_TIMER: u32 = 0;
static mut DQ_FIRED: u32 = 0;   // 本次加载只允许开一次(模块每次开机只装一次)
```

派发回调（**跑在 UI 线程**，因为它是 `lv_timer` 的回调）：

```rust
unsafe extern "C" fn dq_timer_cb(_t: u32) {
    let step = st_rd!(DQ_STEP);
    let timer = st_rd!(DQ_TIMER);
    if step == 0 {                          // 空闲: 只在需要时把周期压回去
        if timer != 0 { fw_api::timer_set_period(timer, DQ_IDLE_MS); }
        return;
    }
    let i = (step - 1) as usize;
    if i >= DQ_SEQ.len() { st_wr!(DQ_STEP, 0); /* 切慢 */ return; }
    st_wr!(WRITE_BUSY, 1);                  // ★ 与 write 路径**同一把锁**
    run_install_cmd(DQ_SEQ[i], 0);          // notify 会触发 launcher 重发 INSTALL, 必须静默丢弃
    st_wr!(WRITE_BUSY, 0);
    st_wr!(DQ_STEP, if i + 1 >= DQ_SEQ.len() { 0 } else { step + 1 });
    if st_rd!(DQ_STEP) == 0 && timer != 0 { fw_api::timer_set_period(timer, DQ_IDLE_MS); }
}
```

入口（**从 write 上下文调，所以这里不许有任何固件框架调用**）：

```rust
/// rc 那条 dd 进来后调它: 建一台 UI 线程的定时器, 再把游标打到第 1 步。
/// 8 次都没建成 => 返回 -19, **不假装成功**。
unsafe fn dq_start() -> i32 {
    if st_rd!(DQ_FIRED) != 0 { return 0; }              // 本次加载只开一次, 不重入
    if st_rd!(DQ_TIMER) == 0 {
        if st_rd!(DQ_TRIES) >= DQ_TRIES_MAX { return -19; }
        st_wr!(DQ_TRIES, st_rd!(DQ_TRIES) + 1);
        let t = fw_api::timer_create(dq_timer_cb as *const () as u32, DQ_PERIOD_MS, 0);
        if t != 0 { st_wr!(DQ_TIMER, t); }
    }
    if st_rd!(DQ_TIMER) == 0 { return -19; }
    st_wr!(DQ_FIRED, 1);
    st_wr!(DQ_STEP, 1);
    fw_api::timer_set_period(st_rd!(DQ_TIMER), DQ_PERIOD_MS);
    0
}
```

四个设计点，缺一个都会出问题：

| 点 | 为什么 |
|---|---|
| `dq_start()` 里**不碰固件框架** | 它在 write 上下文（sh 任务）里跑；一碰就回到"看门狗硬重启"那条路上 |
| `WRITE_BUSY` 用**同一把锁** | `notify_installed` 内部的 lookup 会让 launcher 重发 INSTALL，嵌套进来就崩 |
| `DQ_FIRED` 一次性 | 模块每次开机只装一次；重复开会让序列跑第二遍 |
| 跑完切 `DQ_IDLE_MS = 60 s` | 常驻定时器用 1 s 固定频率是续航红线 |

用到的两个原语 `fw_api::timer_create`(`0x0C587ED1`) /
`timer_set_period`(`0x0C16D545`) **不是本项目新引入的**：同一模块的 `watchface.rs`
早就在用它们跑表盘 tick，所以这条定时器通路本来就是这个模块的已验证设施。

### 4.3 安装器侧 ① —— `/data` 那份 rc + 命令帧 + 开关 + 二跳

**`/data/chaos/rc`（19 行，Lua 在点按钮时现生成 → 包里搜不到全文，只能搜生成代码）**：

```sh
set +e
if [ -f /data/chaos/autostart.on ];then
rm -f /data/chaos/autostart.on
echo start > /data/chaos/autostart.log
echo delay=8 >> /data/chaos/autostart.log
sleep 8
insmod /data/chaos/sup.ko chaos_sup
echo insmod >> /data/chaos/autostart.log
dd if=/dev/chaos of=/data/chaos/stage1.bin bs=192 count=1 conv=notrunc
dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc
echo boot_cmd_sent >> /data/chaos/autostart.log
echo safehold=15 >> /data/chaos/autostart.log
sleep 15
echo safehold_ok >> /data/chaos/autostart.log
dd if=/dev/chaos of=/data/chaos/stage3.bin bs=192 count=1 conv=notrunc
echo done >> /data/chaos/autostart.log
echo on > /data/chaos/autostart.on
echo cleared >> /data/chaos/autostart.log
fi
```

| 行 | 为什么这么写 |
|---|---|
| `set +e` | nsh 是子集解释器；不要指望 `&&` / `||` / `$( )` |
| 第 2–3 行 | **先删开关**（防砖）；判据只用 `if [ -f … ]` |
| `sleep 8` | 等开机负载过去 —— 此刻 miwear / launcher 自己还在起 |
| `insmod` | 模块每次开机都要重装（模块内存不落盘） |
| 两条 `dd` | ① 先回读状态块留底（step1）；② 写 16 B 命令帧 —— 这一条**只是入环** |
| `sleep 15` | 等模块 3 步（每步 1 s）走完，并让 launcher 真把桌面条目发出来 |
| 最后 4 行 | 回读状态块（step3）→ `echo on` 重建开关（**出防砖窗**） |

**16 字节命令帧**（两个魔数都挑成可打印 ASCII ⇒ 落盘后肉眼能核）：

```lua
u32le(CMD_MAGIC) .. u32le(CMD_BOOT_DQ) .. u32le(0) .. u32le(0)
-- 0x53484331 "1CHS" | 0x53484333 "3CHS" | 0 | 0   ->  "1CHS3CHS" + 8×00
```

**二跳**（`/data/rc` 很可能已被别的项目占用，**只追加一行、幂等、绝不整体覆盖**）：

```lua
local RC_HOP = "sh /data/chaos/rc &"
local cur = read_all(RC_PATH)
if type(cur) ~= "string" then cur = "" end
if not cur:find(RC_HOP, 1, true) then
  local f = io.open(RC_PATH, "a")          -- 追加
  f:write(RC_HOP .. "\n")
end
```

**开关**：`autostart.on` 存在 = 开。建用 `write_file(FLAG_ON, "on\n")`（自带回读核对），
删用 `rm -f` 后**回读确认真的没了**。

### 4.4 安装器侧 ② —— flash 里那句 rcS hook（**v1 缺的就是这一环**）

只改 **22 个字节**：8 字节（rcS inode 的 `size=332` + `checksum=0x8D9C53E2`）
和末行窗口里的 14 字节（`exit\n` + 13×NUL → `sh /data/rc &\n` + 4×NUL）。

```lua
local FLASH_FIRMWARE_CODE = 3101043      -- 内置原块来自 3.101.043
local FLASH_BS   = 32768
local HOOK       = "sh /data/rc &"
local P_SIZE, P_CK = 332, 0x8D9C53E2
local HEAD_END, BODY_END, WIN_OFF, WIN_LEN = 0x64EC, 0x6654, 0x6642, 18
local ORIG_ADLER, PAY_ADLER = "40877019", "1E4A726D"
local FLASH_CAND = {
  { dev = "/dev/ap",        off = 12582912, name = "ap-rel" },
  { dev = "/dev/bes_flash", off = 13369344, name = "flash-abs" },
  { dev = "/dev/bes_flash", off = 12582912, name = "flash-aprel" },
}
-- 32 KB 原块(65,536 个 hex 字符) + 载荷**由原块确定性推导**(不另存第二份数据)
local ORIG_HEX = ([[ … ]]):gsub("%s+", "")
local ORIG = unhex(ORIG_HEX)
local HOOKB = HOOK .. "\n"; if #HOOKB > WIN_LEN then HOOKB = HOOKB:sub(1, WIN_LEN) end
local HPAD  = HOOKB .. string.rep(NUL, WIN_LEN - #HOOKB)          -- ★ 补到 18B
local PAY = ORIG:sub(1, HEAD_END) .. be4(P_SIZE) .. be4(P_CK)
  .. ORIG:sub(0x64F4 + 1, WIN_OFF) .. HPAD .. ORIG:sub(WIN_OFF + WIN_LEN + 1)
```

**五道门，任一不过 ⇒ 一个字节都不写**：

| 门 | 查什么 | 不过怎么办 |
|---|---|---|
| 版本 | `getprop ro.build.version` → `3101043`（读不到 / 格式不对也算不匹配） | **整个 flash 部分停用**，只落 `/data` 侧文件 |
| 载荷自检 | `adler(ORIG)` / `-rom1fs-`@0xE85 / `rcS`@0x64F5 / `adler(PAY)` | 同上 |
| 写前 | 目标块"前段 + 本身段 + 后段"**逐字节** == 原块 | **不写** |
| 写后 | 回读**逐字节** == 载荷 | 报"回读不符" |
| 相邻 | 前 / 后相邻块 adler 前后不变 | 报"邻居变了!" |

读写全走 `dd`，`conv=notrunc` 保证只覆盖那一块：

```
dd if=/dev/ap        of=/data/chaos/apblk.bin bs=32768 skip=384 count=1
dd if=/data/chaos/apblk.bin of=/dev/ap      bs=32768 seek=384 count=1 conv=notrunc
```

写之前**先把载荷写进临时文件并回读核对**，核对过了才 `dd` 进去 —— 不许把没核对过的
字节写到 flash 上。写回（还原）只在"前段 + 后段与原块一致"时才做。

### 4.5 界面：`/data` 与 flash **分成两个按钮**

| 按钮 | 第一次按 | 第二次按 |
|---|---|---|
| 装自启文件 | 探三个候选块 + 固件门，只报告（**零写盘**） | 落 `/data` 侧文件 **+ 写 flash hook** |
| 移除文件 | 只报告 | 还原 flash + 摘 `/data/rc` 那行 + 删自启动文件（**主功能不动**） |
| 开自启动 / 关自启动 | 直接生效（建 / 删开关） | — |

写 flash 是这一类工程里**唯一不可逆**的动作，所以：① **两段式确认**（第一次按一个字节都不写）；
② **绝不放进多步自动流程**（本模块安装是 11 步流水线，flash 那半独立在外）；
③ 每一段**单独报结果**，不跟"落文件"共用一个成功/失败。

### 4.6 打包：把模块 + 安装器 Lua 装进 `.face`

```
<proj>/<name>.fprj                # DeviceType=11, Name="app__lua%2F_Lua%2Fdotui.lua"
<proj>/preview.png                # 336x480（另存 images/preview.png）
<proj>/app/_lua/_Lua/dotui.lua    # ← 安装器 Lua（必须纯 LF）
<proj>/app/_lua/_Lua/<模块>.ko    # ← 与 dotui.lua 同级，安装器用 SCRIPT_PATH 取
<proj>/app/_lua/_Lua/<图标>.bin   # ← 注册原生应用必用
```

- 容器内路径 = 工程内路径去掉 `app/` 前缀；`compile.exe` 会把 `app/` 下**所有**文件收进去。
- 编译要给子进程**真控制台**，否则 `Console.WindowWidth==0` → `Array.Copy` 崩、零产物。
- 详细坑（包名不受控 / 终止记录判据 / 缩略图对齐 / 中文 Preview 字体）→ `FACE.md`。

---

## 5 换成别的同类型模块，怎么做

### 5.0 先判断你的模块属哪一类（**这一步决定后面要做多少**）

| 类型 | 特征 | 要做什么 |
|---|---|---|
| **A 纯文件 I/O** | 开机动作只是读写 `/data`、起进程、写日志，不调固件框架 | **不需要 DQ**。rc 脚本里直接干就行（第 4.3 节那套） |
| **B 要调固件框架** | 开机要调 eventbus / 注册 / notify / 改 UI 相关状态 | **必须 DQ**（第 4.1–4.2 节）。因为这类调用在 sh 任务里会挂死 |
| **C 要注册原生应用** | 开机要让桌面出现自己的条目 | 必须 DQ，且 DQ 序列里要含"注册链 + notify + 回读" |

判 A/B 的方法就是 5.1 —— **别靠读代码猜**。

### 5.1 第一步：自己复现"崩在语境"（**必做，别跳过**）

同一个调用做两组对照，只改"从哪调"这一个变量：

| 组 | 做法 | 期望 |
|---|---|---|
| 对照 1 | rc（或 nsh）里直接发命令，让 `write` 同步跑你的开机动作 | **看门狗硬重启**（如果没崩，说明你是 A 类，收工） |
| 实验 2 | 同一动作改成从 `lv_timer` 回调里跑 | 正常返回 |

判据：设备日志 + 是否重启；不要用"看起来正常"当通过。

### 5.2 改模块（B/C 类）：五个点

1. **搬移**：把 `write` 里那段"命令派发 + 收尾"原样搬成 `run_install_cmd(arg0, arg1)`，
   并留一份原文留底（用于逐字节比对）。
2. **加常量**：`CMD_BOOT_DQ`（挑一个和现有魔数同族的可打印值）、`DQ_SEQ`、
   `DQ_PERIOD_MS` / `DQ_IDLE_MS` / `DQ_TRIES_MAX`。
3. **加状态**：`DQ_STEP / DQ_TRIES / DQ_TIMER / DQ_FIRED`（都是 BSS，不落盘）。
4. **加回调 + 入口**：`dq_timer_cb` / `dq_start()`，按 4.2 那四条设计点写。
5. **接进 write**：`match cmd { … CMD_BOOT_DQ => { let _ = dq_start(); } }`。

> 注意：**执行体只能有一份**（第 1 点的搬移就是为了这个）。如果直接把 write 里那段复制一份
> 给 DQ 用，从那天起两条路的语义就会开始漂。

### 5.3 定你的 DQ 序列

- 只放**真正需要固件调用**的命令。纯 BSS 写（如"设语言"）也建议放进来，因为
  **每次开机 BSS 会清零**，开机不重设就丢了。
- 顺序 = 依赖顺序（注册链要在 notify 之前，回读要在注册之后）。
- 每拍只跑一条，别把两条塞一拍 —— 一拍保住了"中间态不会被同一拍读到"这个时序保证。
- 跑完把周期切到 `DQ_IDLE_MS`（续航红线：常驻定时器不许固定 1 s）。

### 5.4 写你的 rc（照抄骨架，改 4 处）

改：① 你的目录、② 你的模块名、③ 两档延时、④ 你需要的 `dd` / 命令。
**别改**：`set +e` / 先删开关 / 只发一条帧 / 结尾重建开关 / 行首词只用
`set if rm echo sleep insmod dd fi` 这个已验子集。

**两档延时怎么定**：
- 第一档 = 等开机负载过去（本机 **8 s**；此时 miwear / launcher 自己还在起）；
- 第二档 = 等你的 DQ 序列跑完 + 等固件真的把结果发出来（本机 **15 s**，序列 3 步 × 1 s）；
- 两者之和就是**防砖窗**（本机 **23 s**）—— 窗越短越容易"没跑完就重建开关"，别为省时间压它。

### 5.5 二跳：只追加、幂等、只摘自己那行

> ⚠️ **这一节描述的是"没有管理器"时的做法。** 装了 `10pro.autorun` 之后有了新契约：
> 模块往 `/data/rc.d/` 投脚本，`/data/rc` 交给管理器生成 —— **别再自己往 `/data/rc` 追加**。
> 两边都做会**跑两遍**（管理器把不认识的行当"别人的行"原样保留，同时又生成一行）。
> 详见 `REGISTER.md` §5。本节的老代码仍然能跑，管理器一个字都不会动它。

- 追加前先 `read` 全文判有没有那一行；有就不加（重复追加会被执行两次）。
- 摘除时**逐行过滤**，只删与自家那一行**完全相等**的行，`/data/rc` 里别人的内容一字不动。
- 「清除重置」也走这条摘除，不许整体覆盖 —— 你的设备上很可能装着**别的项目**的 `/data/rc`。

### 5.6 ★ 补 flash 那句 hook（**最容易漏的一环**）

三条路，任选：

| 路 | 做法 | 适用 |
|---|---|---|
| ① 什么都不做 | 若这台设备**已经**被同类平台装过自启动 | 零风险；但要先**确认**，不能假设 |
| ② 跑一次上游平台的「安装自启动」 | 用现成工具打一遍 | 你会拿到它的实现也可以 |
| ③ **移植进自己的包**（本项目选这条） | 见 4.4 | 想一条链闭环、不再依赖外部工具 |

**移植的六条硬要求**（少一条就别上线）：

1. **32 KB 原块原样搬**，搬完**逐字符**比对（不要"提取二进制再 base64"，多一层编解码多一个错处）。
2. **载荷不另存**，由原块确定性推导。
3. **自己复算常量**：`adler(ORIG)=40877019`、`adler(PAY)=1E4A726D`、`md5(ORIG)=ca1175d7…`、
   `md5(PAY)=0b66f9c1…`、`ORIG[0xE84:0xE8C]=="-rom1fs-"`、`ORIG[0x64F4:0x64F7]=="rcS"`。
   六个全对才说明你搬对了。
4. **五道门**（4.4 那张表）**一个都不能省**。
5. **必须可还原**（写回原块），且还原也只在"前段 + 后段相符"时才做。
6. **两段式确认 + 独立按钮**，不与"落文件"共用成败。

> 版本门读不到固件版本时**当作不匹配**（停用），不要默认放行 —— "不知道"不等于"没关系"。

### 5.7 移除：**白名单删，不许 `rm -rf` 你的目录**

这类模块的 `/data/<目录>/` 里**同时住着主功能**（模块 / 图标 / 字体 / 图标包）。
所以：

- 列一张 `AS_FILES` 白名单（`rc` / 命令帧 / 开关 / 日志 / `stage*.bin` / 临时块）；
- **顺序：先还原 flash，再删文件** —— 临时块就落在那个目录下，`rm -rf` 之后就没法还原了；
- `rm -rf <目录>` 只留给"彻底重置"那个按钮（本项目主视图的「清除重置」）；
- 判据要**反向**写：从源码里抠出那张删除表，断言里面**没有** `SUPERVISOR_PATH` /
  `ICON_PATH` / `FONT_DIR` 这些主功能路径。正向断言挡不住"顺手多写一行"。

### 5.8 上屏与日志分工

写 flash 的理由（三段 DIFF 偏移 / adler / 邻居指纹前后值）**一行屏放不下**，硬塞会被裁切。
做法：**上屏只放短词**（`块ap-rel 原样 再按=写入` / `文件+hook 已装` / `hook未写`），
**完整理由走日志**，统一前缀（本项目 `[chaos-installer]`）。排查时看日志，不看屏幕。

### 5.9 验证链（三道离线门 + 两道设备门）

| 门 | 判据 | 负向对照 |
|---|---|---|
| **G1** 模块能编 | `rustc --emit=metadata`（宿主目标，整个 crate 一起 type-check）：0 error / 0 warning | 塞一句 `fn broken( { }` ⇒ 必须报 `unclosed delimiter` |
| **G2** 搬移块没漂 | 把 `run_install_cmd` 的函数体减 4 格缩进 ⇒ 与留底**逐字节相同** | 改一个字符即 md5 不符 |
| **G3** 安装器行为 | 真 Lua + 假 `lvgl`/`io` + **假 shell（`dd` 必须真实现）**，点按钮核产物 | 把延时改错 ⇒ "rc 逐条相同"立刻 FAIL |
| **G1'** 真机手动 | `dd` 一帧后回读状态块，判**步号字**（见下表）；**先做这个，别急着冷启** | 步号停在 `0xAA` ⇒ DQ 没跑起来 |
| **G2'** 冷启 | 3/3 成功、桌面条目自动回来、`autostart.log` 尾行 = `cleared` | — |

**步号字**（状态块 word48，字节偏移 188）：

| 值 | 含义 |
|---|---|
| `0xAA`(170) | **DQ 没跑** —— rc 发了帧，但 ko 里那台 timer 没起来（查 `dq_start()` 是不是回 `-19`） |
| `10..17` | **DQ 跑完** ← 正常应到 `17`（register 链走到底） |
| `0x42` | 本次开机已注册过，重入跳过 |
| `0x33` | 白名单满，放弃注册 |

设备侧手动核：

```sh
dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc
sleep 20
dd if=/dev/chaos of=/data/chaos/s3.bin bs=192 count=1 conv=notrunc
# 判 s3.bin 的 188 字节处那 4 个字节
```

> **G3 里"假 shell"必须真实现 `dd`**（`if/of/bs/skip/seek/count/conv=notrunc`，作用在内存
> flash 镜像上）。只往命令表里记一条字符串，"写 flash"的任何错误都测不出来（假阳性）。
> 本项目 61 项判据里，flash 那 12 项全靠它。

### 5.10 交付什么

1. 模块产物（真编出来的，未定义符号 0，`.text` 非 0）；
2. 安装器 Lua（纯 LF、无 BOM）；
3. `.face` 容器（含模块 + Lua + 图标），以及一份放桌面的副本；
4. 文档：改了哪些文件 / 每处为什么 / 判据列表 / 风险与未验项；
5. 判据脚本（能一条命令重跑，全绿才算过）。

---

## 6 坑清单

| 坑 | 表现 | 对策 |
|---|---|---|
| 在 sh 任务里同步调固件框架 | `write` 不返回 → **看门狗硬重启** | 只建 timer，活搬到 UI 线程 |
| `notify` 触发 launcher 重发 INSTALL | 嵌套里崩 | 回调里用**与 write 同一把** `WRITE_BUSY` |
| 重复开序列 | 注册跑第二遍 | `DQ_FIRED` 一次性闸 |
| 常驻定时器 1 s 固定频率 | 续航红线 | 跑完切 `DQ_IDLE_MS = 60 s` |
| 忘了 `/data/rc` 靠 flash hook 才会被跑 | 全部报成功、开机什么都不发生 | 先确认 hook 在，或按 5.6 补 |
| 息屏 | DQ 那 3 步暂停（在 UI 任务的 timer 里），rc 那半照跑 | 开机黑屏时图标要等亮屏出现，可接受但要知道 |
| `/data/rc` 被上游平台重写 | 你那行二跳被冲掉 | 重按一次「装自启文件」（幂等）；或让两个项目各用各的目录 |
| 移除自启动时 `rm -rf` 自家目录 | 主功能（模块/图标/字体）一起没了 | 白名单删 + 先还原 flash |
| 移植时 Lua `sub()` 与 Python 切片差 1 | 门永远不过 | `sub(0xE85,0xE8C)` ⇔ `orig[0xE84:0xE8C]` |
| 末行窗口少补 NUL | 载荷 32,764 B、回读/adler 全不对 | `"sh /data/rc &\n"` 是 14 B，**补 4 个 NUL** 到 18 |
| 离线门里造坏块忘了加块基址 | "零写盘"判据成假阴性 | 改**目标块内**的偏移（`block_off + 0x1000`） |

---

## 7 边界：什么时候**不要**这么做

- 你的开机动作**不碰固件框架**（只读写文件）⇒ 不需要 DQ，rc 里直接干（A 类）。
- 你的应用是 **quickapp（`.rpk`）** 而不是内核模块 ⇒ 走 quickapp 的注册表与
  `autostart` 那一套，跟本指南不是同一条路。
- 厂商固件**已经在 rcS 里跑你的脚本** ⇒ 不需要写 flash（这种设备上本文 2.2 那条不成立，
  请自己搜一遍镜像确认）。
- 你没有**能写 flash 的授权 / 不可逆操作的预算** ⇒ 只做 ①（等设备已有 hook）；
  但要在文档里写清"缺 ① ⇒ 全链路不生效"，别让人以为装完就好了。

---

## 8 附录：常量速查

**命令帧**（16 B：`magic | cmd | arg0 | arg1`，小端）

| 常量 | 值 | 备注 |
|---|---|---|
| `CMD_MAGIC` | `0x53484331` | `"1CHS"` |
| `STATUS_MAGIC` | `0x53484332` | `"2CHS"` |
| `CMD_BOOT_DQ` | `0x53484333` | `"3CHS"`，开机序列触发号 |
| `CMD_INSTALL` | `2` | 安装类命令 |
| `STATUS_SIZE` | `192` | 状态块长度 |

**DQ**：`DQ_SEQ = [0x18, 0x13, 0x22]`，`DQ_PERIOD_MS = 1000`，`DQ_IDLE_MS = 60000`，
`DQ_TRIES_MAX = 8`。

**rc / 开关**：`/data/chaos/rc`、`/data/chaos/boot.bin`、`/data/chaos/autostart.on`、
`/data/chaos/autostart.log`；`RC_HOP = "sh /data/chaos/rc &"`；延时 **8 / 15**，防砖窗 **23 s**。

**flash rcS hook**：`FLASH_BS = 32768`、`FLASH_FIRMWARE_CODE = 3101043`、
`HOOK = "sh /data/rc &"`、`P_SIZE = 332`、`P_CK = 0x8D9C53E2`、`HEAD_END = 0x64EC`、
`BODY_END = 0x6654`、`WIN_OFF = 0x6642`、`WIN_LEN = 18`、`ORIG_ADLER = "40877019"`、
`PAY_ADLER = "1E4A726D"`；候选 `(/dev/ap, 12582912)` / `(/dev/bes_flash, 13369344)` /
`(/dev/bes_flash, 12582912)`。

**定时器原语**：`fw_api::timer_create` = `0x0C587ED1`，`fw_api::timer_set_period` =
`0x0C16D545`（周期在 `lv_timer_t+0x00`）。
