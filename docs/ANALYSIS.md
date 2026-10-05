# Chaos-Module 自启动可行性分析

- 对象：<https://github.com/WenHuaYiYang/Chaos-Module>（master，AGPL-3.0）
- 设备：小米手环 10 Pro `p67tc` / 固件 **3.101.043**（与该仓库声明一致）
- 本地副本：`%TEMP%\chaos_probe\Chaos-Module-master\`
- 对照工程：`C:\zcode\shellpp2` + `C:\zcode\shellpp2-autostart`（**同机型同固件，已真机跑通**）

---

## 0 结论

| 问题 | 判定 | 一句话依据 |
|---|---|---|
| 它现在支持自启动吗？ | **否** | 全仓库无开机脚本；唯一驱动入口是按钮，且带 `started_once` 一次性闸 |
| 能实现吗？ | **能** | 缺的只有一件事：把注册链从"调用者任务"搬回 UI 任务。解法在你自己的 Shell++ II 里，同机已验证 |
| 直接加个 rcS hook 把 Lua 那 6 条 dd 过去行不行？ | **不行，会看门狗硬重启** | ko 的 `chaos_write` 是**同步**的；sh/nsh 任务（栈 8K）调框架 = 挂死。见 §2/§3 |

**要动的只有 `chaos_sup` 一个文件级别的小补丁**（新增一个延迟命令号 + 一台 lv_timer，约 60 行），
`/data/rc` 侧只要 1 条 `dd`。Chaos 的 Lua 安装器、页面、容器、App 全都不动。

---

## 1 它现在为什么没有自启动（证据）

| # | 证据 | 位置 |
|---|---|---|
| 1 | 装机路径写死为"配对端投递 → 表盘管理里切到它 → 界面点 Run，11 步走完" | `README.md:96-98` |
| 2 | 唯一驱动入口是按钮 `on_clicked`；跑过一次就拒绝（`started_once`） | `installer/chaos_installer.lua:68, 480-485` |
| 3 | 全仓库无 `rcS` / `/etc` / 开机脚本：只有 `installer/`(3 lua)、`module/`、`supervisor/`、`tools/` | `ls -R` + 全仓 `grep -i "rcS\|autostart\|开机"` |
| 4 | README 自述"这套流程从不 `rmmod`"，且"第二次点 Run 会在加载模块那步失败并要求先关机再开机" | `README.md:99-101` |
| 5 | ko **唯一的 UI 线程入口**在 `shake_arm()`，而 `shake_arm` 只被自己页面的 `on_resume` 调用 | `supervisor/src/watchface.rs:465-482`、`supervisor/src/ui.rs:365` |

第 5 条最关键：**开机那一刻，ko 里没有任何代码跑在 UI 线程上**。
它的常驻 `lv_timer`（驱动字体/图标/摇一摇那一堆 tick）要等你**点开 Chaos 图标**才建起来。
所以就算 rcS 里 insmod 成功，也"没有人"能把注册链推一把。

---

## 2 真正的拦路石（不是"没写开机脚本"）

`chaos_write` 是**同步**的 —— 整条链在调用者任务里跑完：

```
chaos_write (supervisor/src/ipc.rs:322-413)
  └─ CMD_INSTALL + arg0=0x13
       └─ cmd_install(0x13)                       (:198-300)
            ├─ app_lookup × N                       (读 SRAM2 0x200EB040)
            ├─ app_install(meta, items, PAGE_COUNT) (FW_APP_INSTALL 0x0CA6A30D)
            ├─ init_buffer(app_id)                  (FW_INIT_BUFFER 0x0C513A45)
            └─ notify_firmware_full()               (:305-319)
                 └─ lvx_notification_insert_message  (FW_NOTIFY 0x0CA9A899)
```

ko 自己的注释只说"register_app 内部 malloc/memset 是 thunk→段B(LVGL)，**需 `fops.write` 上下文**"
（`supervisor/src/lib.rs:2`）——拿它跟"模块上下文"（insmod 任务）做区分。
但它**没有区分"哪个任务的 fops.write"**。

你自己的 Shell++ II 把这个区分量出来了（同机同固件，`docs/RESULTS.md`）：

| 执行语境 | 栈 (word/byte) | 进框架的结果 |
|---|---|---|
| `sh` / `nsh`（`dd` 在里面跑） | 255 / 8192 | **崩**（看门狗硬重启） |
| UI 任务的 LVGL 定时器 | 102 / 65536 | 不崩（但息屏会停，压环里等亮屏补上） |

> `RESULTS.md:115`「运行期才填充的钩子 `*(0x200EB690)` → **非 UI 任务挂死** → 看门狗硬重启。」
> `RESULTS.md:128,130` 同上表。
> `RESULTS.md:145-147`「第二层（执行语境，**真正主因**）：引入延迟命令号（DQ）……」

⇒ 结论：**rc 里 `dd` 给 `/dev/chaos` 的那一写，如果 ko 当场就把 `cmd_install` 跑掉，必崩。**
这就是为什么"加个 rcS hook + 复用 Lua 的 6 条 dd"这条最直觉的路是走不通的。

---

## 3 现成解法：Shell++ II 的 DQ（延迟命令号）

`C:\zcode\shellpp2\Shellpp-II-App\module\src\supervisor.c` 里已经有一份可抄的实现：

| 部件 | 行 | 干什么 |
|---|---|---|
| DQ 命令号 `0x53510012/13/14/1b` | 24-28 | 标记"这条别当场做" |
| `dq_is_deferred()` | 103-106 | 判是不是 DQ 号 |
| `control_write` | 190-220 | 遇 DQ 号 → `dq_enqueue` → **立即 `return 16`** |
| `dq_enqueue` | 140-153 | 入 8 槽环，返回；顺带 `dq_ensure_timer()` |
| `dq_ensure_timer` | 127-138 | **在 write 上下文里** `LV_TIMER_CREATE(cb, 50ms, 0)`，最多试 8 次 |
| `dq_timer_cb` | 108-123 | **跑在 UI 线程**，每拍取一条派发，然后 head++ |

两个关键点：
1. **`lv_timer_create` 从 sh 任务里调是成立的**（`dq_ensure_timer` 就在 `dq_enqueue` 里，被 `control_write` 调用）。
   这台设备上跑通过。剩下要做的只是让回调干活。
2. 一格一拍：`dq_timer_cb` 一次只消费一条 ⇒ 固件事件循环在两个注册阶段之间必然转一圈，
   对应 Chaos README:113-114 说的"安装器每走一步让出一个 `lv_timer` 拍…注册链的中间态在同一拍里被读到会出错"。

### 地址交叉核对（两工程互相印证，均指 p67tc 3.101.043）

| 符号 | Chaos-Module | Shell++ II | 结果 |
|---|---|---|---|
| `register_driver` | `0x0C1AFF61` (`state.rs:10`) | `ABI_REGISTER_DRIVER_ADDR=0x0c1aff61` | **逐位相同** ✔ |
| `lv_timer_create` 本体 | `0x0C16D474`（`fw_api/event.rs:32` 注释） | `ABI_LV_TIMER_CREATE_ADDR=0x0c16d475` | **同一个**（+1 = Thumb 位）✔ |
| `lv_timer_set_period` | `0x0C16D545`（`fw_api/event.rs:39-42`） | — | Chaos 侧已有封装 ✔ |
| 驱动 mode | `0x1B6` (`lib.rs`) | `0666` | 同一个值 ✔ |

⇒ **Chaos 的 `fw_api::timer_create`（`0x0C587ED1`，是 thunk）与你 Shell++ II 用的 `0x0C16D475` 是同一个函数。**
不需要新增任何 ABI 常量，改 `chaos_sup` 只用它现成的 `fw_api`。

---

## 4 落地改动

### 4.1 A1 —— 最小版（**推荐先做**）：一个 DQ 号 + 开机序列跑在 ko 里

rc 只发 **1 条** 命令；序列本身写死在 ko 里，一格一拍自己走。
好处：rc 不需要 `cmds.bin`、不需要 7 条 dd、不需要相对时序。

**改 `supervisor/src/ipc.rs`：**

```rust
// ===== 开机自启动: 延迟命令号(DQ) + UI 任务派发 =====
// 依据: 非 UI 任务(sh/nsh, 栈 8K)里直接调固件框架 = 看门狗硬重启。
// Shell++ II 在 p67tc 3.101.043 实测: sh/nsh 调用点崩, UI 任务的 lv_timer 不崩。
// => rc 里的 dd 只能"入环即返回", 真正的 cmd_install/notify 必须由 UI 任务派发。

pub const CMD_BOOT_DQ: u32 = 0x5348_4333;   // "3CHS"（对齐 1CHS=CMD_MAGIC / 2CHS=STATUS_MAGIC 的命名）

// 与 installer/chaos_installer.lua 的 pipeline 同序。
// 注意: 在 ko 侧只有 0x13 有实质动作(内部已含 notify), 0x18 只改通知文案,
//       0x0A / 1 / 2 在 match 里落进 `_ => {}`, 保留纯粹为了和已跑通的 Lua 序列对齐。
static DQ_SEQ: [u32; 6] = [0x18, 0x0A, 0x13, 0x43, 1, 2];

static mut DQ_STEP: u32 = 0;      // 0 = 空闲; n = 下一个要跑 DQ_SEQ[n-1]
static mut DQ_TRIES: u32 = 0;
static mut DQ_TIMER: u32 = 0;

unsafe extern "C" fn dq_timer_cb(_t: u32) {
    if DQ_STEP == 0 { fw_api::timer_set_period(DQ_TIMER, 60000); return; }
    let i = (DQ_STEP - 1) as usize;
    if i >= DQ_SEQ.len() {
        DQ_STEP = 0;
        fw_api::timer_set_period(DQ_TIMER, 60000);
        return;
    }
    let arg0 = DQ_SEQ[i];
    st_wr!(WRITE_BUSY, 1);        // 与 write 路径同一把锁: 拦 notify 触发的 launcher 重入
    run_install_cmd(arg0);        // ← 把 chaos_write 里那个 `match arg0` 抽成函数, 逻辑一字不改
    st_wr!(WRITE_BUSY, 0);
    fops_wr(FOPS_STEP, 0xD0D0_0000 | DQ_STEP);  // 步号格当"DQ 活着的证据", 见 G0
    DQ_STEP = if i + 1 >= DQ_SEQ.len() { 0 } else { DQ_STEP + 1 };
}

unsafe fn dq_start() -> i32 {
    if DQ_TIMER == 0 {
        if DQ_TRIES >= 8 { return -19; }
        DQ_TRIES += 1;
        let t = fw_api::timer_create(dq_timer_cb as u32, 1000, 0);
        if t != 0 { DQ_TIMER = t; }
    }
    if DQ_TIMER == 0 { return -19; }          // 8 次都没建成, 明确失败, 不假装成功
    DQ_STEP = 1;
    fw_api::timer_set_period(DQ_TIMER, 1000);
    0
}
```

`chaos_write` 的 `match cmd` 里加一支：

```rust
        CMD_BOOT_DQ => { let _ = dq_start(); }
```

**只做两件重构、不新增逻辑**：
1. `chaos_write` 里 `match arg0 { 0 => .. 1|2 => .. 0x13 => .. 0x43 => .. 0x18 => .. 0x19 => .. 0x22 => .. 0x30 => .. _ => {} }`
   连尾部那四词 `FOPS_SLOTS` 一起抽成 `run_install_cmd(arg0: u32)`。派发路径与 write 路径**共用同一份代码**。
2. 一环一拍 ⇒ 保留 Lua 路径原有的时序保证。

**节拍**：跑序列时 1000 ms（= Lua 安装器原周期），跑完切 60000 ms。
这是为了守 Chaos README:194-195 那条电池红线（"常驻 `lv_timer` 不能用固定频率"）。
`lv_timer_delete` 地址本仓未确认（`watchface.rs:463-464`），所以只降频不删除。

**关于"活着的证据"**：状态块（`chaos_read`，`STAT_LEN`=192 B = 48 word）已经排满，没有空格子。
所以复用**步号格**（Rust idx47 / Lua words[48]，`FOPS_STEP`）当心跳：
正常注册流程写 0..0xAA 的小值，DQ 心跳写 `0xD0D0_00xx`，两者不会撞。
不改 ABI、不改状态块长度。

### 4.2 A2 —— 通用版（想做"任意命令都能从 rc 发"时再用）

按 Shell++ II 原形做 8 槽环（`dq_enqueue`/`dq_is_deferred`/`dq_timer_cb` 三件套），
`CMD_BOOT_DQ` 改成 `CMD_INSTALL_DQ`，`arg0` 带真正的阶段号。rc 侧就是 7 条 `dd`。
A1 够用就先别上 A2。

### 4.3 rc 侧

**前提：`/data/chaos/sup.ko` 与 `/data/chaos/chaos_icon.bin` 必须已经在盘上** ——
`/data` 掉电不掉，所以**手动跑一次官方安装器**（点一次 Run）落盘之后，后面每次开机 rc 都能自启。
rc 不需要也不应该重复落盘这两份文件。

**⚠ 先看这一个坑**：`/data/rc` 这个文件名 **Shell++ II 已经占了**。
如果机器上装过 Shell++ II 自启动，不能用"再写一份 rc 覆盖"。两个选一个：

- **(a) 合并**：在现有 `/data/rc` 的 `fi` 之前插一段 Chaos 的（见下）；
- **(b) 二跳**：现有 rc 末尾加 `[ -f /data/chaos/rc ] && sh /data/chaos/rc &`，
  把 Chaos 那段单独放 `/data/chaos/rc`。**推荐 (b)**，两边互不干扰，也好单独禁用。

`/data/chaos/rc` 全文（可直接粘）：

```sh
# /data/chaos/rc -- Chaos 开机自启动
# 由 /data/rc 里那条 `sh /data/chaos/rc &` 二跳调起。
# 语义与 Shell++ II 的 rc 完全同形:
#   * 只在 /data/chaos/autostart.on 存在时执行; 执行前先删掉;
#   * 整段(含安全窗)走完才写回 => 窗内重启/崩了, 开关停在【关】, 下次不自启(防砖)。
#   * 只发 1 条 DQ 命令(ko 自己按格走 6 步), 所以 rc 里没有 cmds.bin / 没有多段 sleep。
set +e
if [ -f /data/chaos/autostart.on ];then
rm -f /data/chaos/autostart.on
echo start > /data/chaos/autostart.log
sleep 5
insmod /data/chaos/sup.ko chaos_sup
echo insmod >> /data/chaos/autostart.log
sleep 1
dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc
echo boot_cmd_sent >> /data/chaos/autostart.log
sleep 12
dd if=/dev/chaos of=/data/chaos/status1.bin bs=192 count=1 conv=notrunc
echo safehold=12 >> /data/chaos/autostart.log
echo on > /data/chaos/autostart.on
echo done >> /data/chaos/autostart.log
fi
```

`/data/chaos/boot.bin` 是 **16 字节**：

```
31 43 48 53  33 43 48 53  00 00 00 00  00 00 00 00
└─ CMD_MAGIC ─┘└ CMD_BOOT_DQ ┘└── arg0=0 ──┘└─ arg1 ─┘
  0x53484331    0x53484333
```

生成命令（在能写设备的任意 shell 里跑一次）：

```sh
printf '\x31\x43\x48\x53\x33\x43\x48\x53\x00\x00\x00\x00\x00\x00\x00\x00' > /data/chaos/boot.bin
```

**`sleep 12` 的理由**：ko 里 6 步 × 1 s = 6 s；「武装」文件要等整段走完才写回。
这个窗比 Shell++ II 的 10 s 长一点，因为步数多、每步 1 s。

---

## 4.4 "直接用 rc 跑 lua"行不行 —— 不行，但值得当实验

**判定：`lua` 确实存在、rc 确实能起它，但那个 lua 不是表盘 Lua，救不了"进框架"这件事。**

### 它是独立 applet，不是 miwear 的 Lua

内建 applet 表（file `0xC87114` 起，一项 4 word = `名字指针 / 优先级 / 栈 / 入口`）：

| 名字 | 优先级 | 栈 | 入口 | 说明 |
|---|---|---|---|---|
| `lua` | 100 (`0x64`) | `0x8000` = **32768** | `0x0C6C8ED5` | file `0xC87114` |
| `nsh` | 255 (`0xFF`) | `0x2000` = 8192 | `0x0C6EE76D` | file `0xC87154` |
| `sh` | 255 | `0x2000` = 8192 | `0x0C6EE7B5` | file `0xC87164` |
| `miwear` | 102 (`0x66`) | `0x10000` = **65536** | `0x0C6FCDF1` | file `0xC872F4`，**UI 任务** |

`/etc/rcS` 第 14 行的 `miwear &` 走的就是这张表 ⇒ `lua /data/x.lua` 同理可用。

它的载荷是 **stock Lua 5.4 CLI**（file `0xB44600`–`0xB46000`：`usage:`、`LUA_INIT`、`stdin`、
`LUA_PATH=/init.lua;./?.lua;./?/init.lua`）。

表盘 Lua 的绑定是**另一套**，自称 miwear lua：
- luavgl 层字符串：file `0xBF9800`–`0xBFC400`（`luavglObj`、`root.meta`、`HOR_RES`、`Timer`、
  `SCRIPT_PATH`、`miwear.topic`、`pageOnResume`）
- 模块注册函数 `luaopen_miwear` / `_screen` / `_navigator` / `_topic` / `_dataman` /
  `_activity` / `_vibrator`：file `0xD01900` 起（`luaL_Reg` 表，如 `subscribe → 0x0CAB242D`）
- 单实例保护：「multiple miwear lua instances detected.」file `0xBFC100`

**可达性验证**（capstone，从 applet 入口 `0x0C6C8ED4` 做 `bl` 调用图 BFS，深度 4，共 142 个函数）：

| 检查项 | 命中 |
|---|---|
| 触达绑定层代码 `0x0CAA0000`–`0x0CAC0000` | **0** |
| 引用绑定层字符串区 `0x2CCB9000`–`0x2CCC1000` | **0** |

⇒ 那个 lua 里**没有 `lvgl`、没有 `lvgl.Timer`、没有 `SCRIPT_PATH`**。
残余不确定：间接调用（`blx rN`）未跟；函数体按 `pop {...,pc}` 截断，可能少跟几个调用。

### 而且它是非 UI 任务

prio 100 / 32 K 栈，和 `sh` 同类（都进了 `/etc/rcS` 之外的新任务）。按 §2 的实测，
**非 UI 任务进框架 = 看门狗硬重启**；没有 lvgl 也就搭不出"UI 线程 lv_timer"那条逃生通道。

**⇒ rc 跑 lua = 换一个非 UI 任务去跑同一件注定崩的事。**纯 sh 的 `dd`/`printf` 已经够驱动 rc，
多引一个 32 K 栈的任务只有坏处。

### 但这个问题挖出了一条真东西：它是验证"未定案"的最便宜实验体

`shellpp2-autostart/docs/RESULTS.md:197` 留着：
「p3 根因未定案：非 UI 任务里调框架为何挂死（**32–64 K 之间**？或与栈无关）。」
现有两个数据点：**8 K（sh，崩）** 与 **64 K（UI lv_timer，不崩）**。
而 `lua` 是**恰好 32 K 栈的非 UI 任务** —— 正好卡在怀疑区间正中，且**不用改 ko、不用碰 flash**。

实验见 §5 的 **G0'**。

### 免改 ko 的真正路径仍然只有一条：把脚本送进 miwear 的 Lua

新证据：设置 `SCRIPT_PATH` 全局的函数在 **`0x0CAB2C34`**，它按 `?.lua` 从 script path 加载
（file `0xBFC038`「run script: %s」、`0xBFBFF0`「failed to load: %s」、`0xBFBFC0`「script path: %s」）。
**缺口**：script path 由谁给（表盘资源目录？persist？）还没定 —— 这是路径 B 剩下唯一的问题。

---

## 5 分阶段验证（按"每关先做零风险测试"的红线）

每关都要设备侧原始输出当判据，**不许拿"看起来好了"当通过**。

### G0' 用 stock lua 验"32 K 栈的非 UI 任务能不能进框架"

**目标**：判 `RESULTS.md:197` 那条未定案。**不改 ko、不碰 flash**，全程在 nsh 里手打。

**第 0 步（零风险）**：先验 `lua → io.write → 设备节点` 这条管道通不通。
用 Shell++ II 的 `INSTALL stage=0`（`control_write` 里 `g_stage == 0` 直接 `rc = 0`，**零框架调用**）。

`/data/t_lua0.lua`：

```lua
-- 1SPS(0x53505331) | 0x53510002 INSTALL | stage=0 | arg1=0   ← stage=0 = 零框架调用
local fr = string.char(0x31,0x53,0x50,0x53, 0x02,0x00,0x51,0x53, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00)
local f = io.open("/dev/shellpp", "wb")
if not f then os.exit(2) end
local ok = f:write(fr); f:close()
local g = io.open("/data/t_lua0.log", "w")
g:write("write=", tostring(ok), "\n"); g:close()
```

nsh：`lua /data/t_lua0.lua; echo rc=$?; cat /data/t_lua0.log`
**判据**：`/data/t_lua0.log` 存在且 `write=true`（或非 false） ⇒ lua 任务能写设备节点。
此时设备**不该**有任何异常 —— 因为这条命令一个固件函数都没调。

**第 1 步（会吃一次看门狗复位）**：复制成 `/data/t_lua1.lua`，只把 stage 那一字节从 `0x00` 改成 `0x01`
（同一个脚本、同一个设备节点，唯一差别是这一次**会真的进框架**）：

```lua
local fr = string.char(0x31,0x53,0x50,0x53, 0x02,0x00,0x51,0x53, 0x01,0x00,0x00,0x00, 0x00,0x00,0x00,0x00)
```

**判据分叉**：

| 现象 | 结论 | 后续 |
|---|---|---|
| 看门狗复位 / `t_lua1.log` 不存在 | "非 UI 语境"这条**判死**，与栈无关 | DQ 是唯一解 ⇒ 回 §4.1 改 ko |
| `t_lua1.log` 写出且设备活着 | 根因是**栈**不是语境（8 K 不够、32 K 够） | **rc 可直接驱动注册链，Chaos 自启动不用改 ko** |

**风险**：复位，不是变砖（与 `RESULTS.md:115` 记录的是同一形态）。命令由你手打，先跑第 0 步。

| 关 | 动作 | 判据（期望串，逐字节） | 风险 |
|---|---|---|---|
| G0 | 只加 `dq_start` + 一个**只含 `0x22`** 的 `DQ_SEQ`（`0x22` 只写 BSS，**零固件调用**）。rc 里 insmod + 1 条 dd，`sleep 12` 后把状态读回 | `/data/chaos/status1.bin` 长 192 B；word1(idx0)=`0x53484332`（STAT_MAGIC）；word3(idx2)=写计数 ≥ 1（证明 dd 真的到了 `chaos_write`）；**word48(idx47) 高 16 位 = `0xD0D0`**（证明 lv_timer 建成 + 回调真在 UI 线程跑过） | **零** |
| G1 | `DQ_SEQ` 换成完整 6 步 | 同一次读回里 `dbg_verify`(idx44/45) 非 0 → 注册生效；桌面出现 Chaos 图标 | 一次 panic 预算内 |
| G2 | 拔电冷启复现 | 连续 3 次冷启，G1 判据 3/3 成立 | 同上 |
| G3 | 与 Shell++ II 自启动共存 | 两个包各自的状态文件都在、互不覆盖；两边图标都在 | 同上 |

**G0 是整个方案的支点** —— 它只验"从 sh 任务创建的 lv_timer，其回调会不会在 UI 线程跑"。
这一条成立，后面全是抄已跑通的配方。

---

## 6 风险与未验点（不打包票）

1. **`lv_timer_create` 从 sh 任务调**：Shell++ II 是这么干的且整链跑通（`supervisor.c:127-138`），
   但**没人在 Chaos 的 ko 里验过**。G0 就是冲这个去的。失败表现：`dq_start` 返回 `-19`，状态里定时器句柄 = 0。
2. **LVGL 定时器链表并发**：Shell++ II 的定时器在 write 上下文建、在 UI 线程跑，没出问题；
   Chaos 的 ko 自己也强调"只建一次、永不重建"（`watchface.rs:459-464`）。
   我们的 DQ timer 同样只建一次、幂等（`DQ_TRIES` 上限 8，`DQ_TIMER` 建成就复用）。
3. **息屏时序列会暂停**：UI 任务的 lv_timer 在息屏时不跑（`RESULTS.md:130`）。
   压着不丢，亮屏继续 —— 但对"开机就插上充电、屏幕黑着"的场景，
   Chaos 图标要等亮屏才出现。**可接受但要知道**。
4. **`/data/rc` 文件名冲突**：见 §4.3，必须走二跳，不要覆盖。
5. **rcS hook 本身**：需要 flash 里那处 `exit → sh /data/rc &` 已经打好（Shell++ II 那套）。
   没打就得再动 flash 块 —— 那才是真正高风险的一步，与 Chaos 无关。
6. **Chaos 从不 `rmmod`**：我们的设计是**每次开机 insmod 一次**，天然满足；
   注意不要在 rc 里加卸载逻辑，否则注册链表条目悬空 → launcher 崩（`README.md:100-101`）。
7. **首次安装仍需人工一次**：`/data/chaos/{sup.ko,chaos_icon.bin}` 落盘不在本方案范围内。

---

## 7 备选：路径 B（不动 ko，让安装器 Lua 开机自己跑）

`installer/chaos_installer.lua` 本身就是**表盘资源包里的 Lua**（靠 `SCRIPT_PATH` 找 ko 与图标），
而它已经在 UI 语境的 `lvgl.Timer` 里跑整条流水线。所以最小改动版本是：

1. `chaos_installer.lua:480-485` 去掉按钮门，改成开机标记文件（`/data/chaos/installed.on`）；
2. `main` 末尾自动 `start_runner()`；保留"每步一格"。

**为什么只当备选**：watchface 的 Lua 只在**它自己是当前激活表盘**时才跑。
也就是用户必须把这张安装器表盘设成桌面 —— 自己的表盘就看不到了。
作为"证明流水线可以无人驱动"的一次性实验可以，作为交付不行。

---

## 8 一句话给下一步

先做 **§5 的 G0'**（零风险那步，10 分钟、不改任何东西）：它判的是"非 UI 任务能不能进框架"这条
从 Shell++ II 留到现在的未定案。

- 如果 **G0' 第 1 步崩**（预期）：DQ 是唯一解 ⇒ 做 **§4.1 的补丁 + §5 的 G0**，
  零风险、只验"sh 任务建的 lv_timer 回调是否落在 UI 线程"，过了就照 §4.3 铺 rc。
- 如果 **G0' 第 1 步活**：根因是栈不是语境 ⇒ **Chaos 自启动完全不用改 ko**，
  rc 里直接 `lua /data/chaos/boot.lua` 就够了（脚本只写 6 条 16 B 帧到 `/dev/chaos`）。

两条路都先看 G0' —— 它比 §4.1 的补丁便宜得多，而且不管哪种结果都会缩小后面的工作量。

---

# 9 Phase-5：逆向定案"UI 语境 vs 栈"（2026-10-03 追加）

问题：`/data/rc` 由 `sh`(prio 255 / **8192**) 执行，第 3 条命令（第一次真进框架）时
`write()` **不返回** → `rtc_watchdog(1)` 硬重启。
四个载体数据点里"是否 UI 任务"与"栈大小"**完全共线**，无法区分。本节用静态逆向拆它。

## 9.1 把框架链逐帧摊开（`app_install` @ `0x0CA6A30C`）

```
0ca6a30c cmp r0,#0 ; beq.w 0xca6a454        ; 空描述符直接返回
0ca6a312 push.w {r4,r5,r6,r7,r8,sb,sl,lr} ; sub sp,#8      ; frame = 40 B
0ca6a320 ldr.w sb,[pc] = 0x200EB640         ; &APP_REGISTRY（带哨兵环链表）
0ca6a330-0ca6a342  按 [node+0x10] 的 u16 app_id 走链表
0ca6a344 pop {...,pc}                       ; app_id 已存在 -> 直接返回（幂等，不重入）
0ca6a34a movs r0,#0x40 ; bl 0x0CAC08E0      ; malloc(64) 新节点
0ca6a358 bl 0x0CAC0C40                      ; memset(node,0,64)
0ca6a360-0ca6a37c ldm/stm x4                ; 拷 64B 调用者描述符
0ca6a382-0ca6a3a0 bl 0x0C1F06B4 x4          ; strdup [+8]名 [+0xc]图标 [+0x14] [+0x18]
0ca6a3a6-0ca6a3bc strd/str                  ; 链表插入
0ca6a3be bl 0x0C1F903C                      ; 分配 (页数+2)*4 页指针数组 -> node+0x30
0ca6a3d0 bl 0x0CABE010                      ; hashmap_new(10)
0ca6a3ee ldr.w sl,[pc] = 0x200EB684         ; &g_appmgr
   ↓ 逐页循环（页数==0 则整段跳过）
0ca6a3f4 ldr r0,[r5,#4]!                    ; r0 = page_desc[i]
0ca6a3f8 ldr.w r3,[sl,#0xc]                 ; ★ 运行期钩子 *(0x200EB690)
0ca6a3fc blx r3                             ; ★ 调用；返回值被丢弃
0ca6a410 bl 0x0CABE090                      ; hashmap_put(map, page_desc->+0x10 页名, page_desc)
0ca6a44a bl 0x0CA41584                      ; ★ lvx_eventbus_send_with_cb(0x1c, node->name, 0)
```

**段位归属（`0x0CABE090` 一度被误判成"miwear/Lua 单例层"）**：它自己的池里写着
`"/vendor/xiaomi/miwear/common/base/util/hashmap.c"`，`movw r5,#0x1505` + `r5=r5*33+c`（**djb2**）
⇒ 就是 **`hashmap_put`**；`0x0CABE010` = `hashmap_new(cap)`（容量向上取 2 的幂，`(x+2)*4` 字节桶）。
**不是 Lua，不是 LVGL。**

## 9.2 可达集审计（192 个函数）

从 `0x0CA6A30C` 做函数级 BFS（`bl` 目标，含阳性对照）：

| 段 | 数量 | 内容 |
|---|---|---|
| `0C1F` | 39 | libc/str（`strdup`/`malloc`/logger） |
| `0CAC` | 7 | libc/alloc（`malloc`/`memset`） |
| `0CAB` | 3 | **全是 `hashmap.c`**（`hashmap_new`/`put`/…） |
| `0C58` | 3 | appmgr 辅助 |
| `0CA4` | 2 | `lvx_eventbus_send_with_cb` + 其一 |
| 其它 | 138 | 零散 |

* **无 LVGL**、**无 Lua 状态机**、**无 UI 单例**。
* "miwear/luavgl 单例串"（`multiple miwear lua instances detected.` 等）在可达集里 **0 命中**。

⇒ 若"必须 UI 语境"为真，它**不可能来自框架自身**，只能来自**两个运行期间接调用**：
① `*(0x200EB690)` 钩子；② `0x0CA41584` 的 eventbus。

## 9.3 钩子 `*(0x200EB690)` —— 固件里没有写入者（负结果）

* `0x200EB684` 作为 32-bit 字面量在全镜像出现 **381** 次，构成 **174** 个加载点（`ldr`/`ldr.w`/`add pc`）。
* 对这 174 个点做**前向寄存器追踪**（跟踪 `add/mov` 偏移链、寄存器改写失效、**含后索引 `str rX,[rN],#imm` 与 `stm`**），
  搜索"有效地址落在 `0x200EB684..0x200EB6A4`"的 store，窗口放到 **16 KB / 4000 条指令**：
  **0 处**。
* 反例校验：对 `0x0C58FC94 str r2,[r3,#0xc]` 的"疑似写入者"判定是**假阳性**——
  该函数的真实基址是 `0x2011497C`（lit@`0x0C58FCBC`），不是 `0x200EB684`；它是个
  "**把对象 +0x00..+0x20 九个槽全部清 0**"的销毁例程，相邻字符串是 `"on_destroy"`/`"sport"`。

⇒ `g_appmgr+0x00..+0x20` 这 9 个槽 **不是 `vela_ap.bin` 的代码写的**。两种解释：
(a) 属 `.data`，开机由 RAM 数据镜像拷贝进来；(b) 属**运行期加载模块**（modlib/RPK）的初始化（**→ 已由 §10.3 用三套机制 + 双阳性对照复核；§10.2 进一步排除了 (a)：镜像里根本没有 data 初始化块**）。
与 `RESULTS.md` 早先"**运行期才填充的钩子**"的说法一致 —— 但**它的身份仍然未知**。

## 9.4 栈深下界：1612 B

用固定帧度量（`push` 保存寄存器 ×4 + `sub sp,#imm`），**只取子节点最大值**（真关键路径，不是求和的伪值）：

```
0x0CA6A30C (40) -> 0x0CABE090 (48) -> 0x0CABE2D8 (152) -> 0x0C1E4528 (16)
 -> 0x0C1D0A98 (104) -> 0x0C1D06B0 (72) -> 0x0C1B04C0 (168) -> ... -> 0x0C73E924 (36)
合计 = 1612 B（26 帧）  单帧最大 = 272 B（0x0C20347C）
```

* **单帧最大 272 B** ⇒ 32 KB 的 `lua` 档位**不可能因这条链栈溢出**（差两个数量级）。
* 1612 B 是**下界**（不含寄存器溢出/局部数组/alloca；34 个函数因 capstone 截断可能漏边）。
* ⚠️ 修正旧数据：`walkfun`/`p3_frame` 早先报的 `0x0CABE090 frame=576` 是**错的**
  （它们在整函数窗口里累加所有 `push`）；真实序言帧 = **48 B**。

## 9.5 定案

> **不是"栈 vs UI"二选一。崩点是"框架尾部的一次间接调用"，即语境/线程归属问题，不是栈。**

判据（四条，逐条独立）：

1. **栈被排除**：关键路径固定帧下界 1612 B、单帧最大 272 B；`lua` 档位有 **32768 B**（20 倍余量）却和
   `sh`(8192) **一起崩**。栈不足无法解释 32 K 档位的失败。
2. **"框架需要 UI 语境"也被排除**（对框架自身）：192 个可达函数里没有任何 LVGL/Lua/UI 状态，
   只有链表/strdup/malloc/djb2 hashmap/名字表。
3. **失败形态是"阻塞等待"而非崩溃**（`RESULTS.md` B4：`write()` 不返回）⇒ 指向"等一个只有特定
   任务才会给的信号"。
4. **两个运行期间接调用**是仅有的候选，且都在**框架尾部**：
   * `*(0x200EB690)`（打 11 页时调用一次/页）—— 身份未知，固件里无写入者；
   * `lvx_eventbus_send_with_cb(0x1c, name, 0)`（结尾一次）—— 首次调用会 `bl 0x0C2E14E8`
     **拉起 eventbus 派发任务**（入口 `0x0CA41419`）。若该派发链路由 UI 侧服务，
     非 UI 任务投递就会永久等待。

**"为什么 UI 任务的 LVGL 定时器能过、`sh`/`lua` 过不了"**：因为 DQ 路径下**整条框架调用跑在
miwear 任务里**（eventbus 派发任务、页面回调天然属于那个语境）；而非 UI 任务投递时，
链条在 eventbus/钩子处断开 → `write()` 永不返回 → 看门狗。

## 9.6 定案的零风险判别矩阵（不用重启设备、不写 flash）

在 `sh` 里 **只做 A**，就能把 9.5 的第 4 条坐实或推翻：

| 试验 | 调什么 | frame | 若结果 = 挂 | 若结果 = 通过 |
|---|---|---|---|---|
| **A** | 只 `app_lookup(app_id)`（`0x0CA69934`，纯读链表） | **4 B** | **语境论铁证**（4 B 栈绝不可能溢出） | 分界线在 `app_install` 深处 → 做 B |
| **B** | `app_install(desc, pages=NULL, count=0)` | 40 B | 不是逐页钩子 | 做 C |
| **C** | `app_install(desc, pages, 11)`（现状） | 40 B | 就是逐页钩子 ⇒ 只剩"钩子身份"一个未知物 | 说明差异在 `lvx_eventbus` |

* A 的调用点可以从 `native_app.c` 的 `lookup_installed_with_retry()` 单拎出来，**不动任何现有命令号**，
  新增一个只读 stage（或复用 DQ 环里一个空闲号）。
* 三条都在 `sh` 任务里跑（`/data/rc` 或手动 nsh），**不涉及 DQ、不涉及 UI 定时器**。
* 全程只读/失败即回滚：`app_lookup` 不改任何状态；B 若不改 `page_count` 语义也不落地。

## 9.7 沉淀的逆向教训（已写进 skill Step 9 / Step 13）

1. **capstone `disasm()` 遇首条不可解码指令就整段返回 0**（不是跳过继续）。
   实例：`0x0C58FB00`→32 条、`0x0C58FC00`（函数内嵌字面量池）→**0 条**、`0x0C58FC48`→162 条。
   ⇒ 任何"从入口顺序扫到 `pop pc`"的函数遍历，**函数内部只要嵌池就被静默截断**；
   必须显式审计"是否见到 `pop {..pc}`"，并把结果标成**下界**。
2. **"在站点前 N 字节内找到一个等于目标值的字面量"= 假阳性制造机**。
   `str rX,[rN,#0xc]` 的 `rN` 可能被中途改写，字面量也可能属于隔壁函数的池
   （本次在 400 B 窗口内吃到 `0x0C58FB48 = 0x200EB684`）。
   **必须做寄存器活跃性/改写失效追踪**。
3. **自己脚本里的失效 bug 会让负结果骗人**：从"加载点自身"开始做寄存器失效，
   第一条 `ldr` 就把刚设好的基址 prov 清掉了 ⇒ 恒报 0 处。**负结果必须先自证扫描器健康。**
4. **段位归属不能靠地址范围猜**：`0x0CABxxxx` 既可能是 Lua 层，也可能只是
   `common/base/util/hashmap.c`。**看函数自己池里的 `__FILE__` 字符串**才是硬证据。

## 9.8 真机 `ps` 实测档位（2026-10-04，用户回传原始输出）

**真机 `ps` 同样有 `STACK / USED / FILLED`** ⇒ p67tc 也编了 `CONFIG_STACK_COLORATION`，
**栈从"只能推"变成"可以量"**。以下全部为十进制、去掉了输出的前导零：

| 任务 | STACK | USED | FILLED | 头余量 |
|---|---|---|---|---|
| `Idle_Task` | 3000 | 1120 | 37.3% | 1880 |
| **`nsh_main`（PID 8）** | **4000** | 2364 | **59.1%** | **1636** |
| `kvdbd` | 4008 | 2372 | 59.1% | 1636 |
| **`system -c ps`（= `sh -c` 档）** | **8032** | 2164 | 26.9% | **5868** |
| `miwear-pm` | 5040 | 3396 | 67.3% | 1644 |
| **`miwear`（UI 任务, PID 45）** | **65448** | 15428 | 23.5% | 50020 |
| `miwear_algo_service` | 16280 | 4716 | 28.9% | 11564 |
| `nfc_stack_bridge` | 15256 | 1736 | 11.3% | 13520 |
| **`com.shell.liangyi`（组 45 的 quickapp 线程, 入口 `0x0C8E5798`）** | **131000** | 10952 | 8.3% | 120048 |
| `bluetoothd` / `miconnect` / `dfxd` / `vibratord` | 8072–8096 | 3092–4476 | 38–55% | ~3.6 K |

**推论 1 —— VVD 在 `sh` 这一档是可信代理，在 UI 档不是**
真机 `sh -c ps` = **8032 / USED 2164**；VVD `sh -c ps` = **8080 / USED 2112**。几乎同值
⇒ 用 VVD 量"`sh` 档位"的栈开销可以外推到真机；但 **UI 档不行**（VVD 2 MB vs 真机 65448，差 32 倍）。

**推论 2 —— 出现一个能翻转结论的变量：`/data/rc` 到底跑在哪个任务里**
`nsh_script()`（`.`/`source`/`sh <path>` 共用）在**调用者任务里原地执行**，所以调用者是谁决定了头余量：

| `/data/rc` 实际跑在 | STACK | 头余量 | 与 §9.4 的 1612 B 下界比 |
|---|---|---|---|
| `sh -c` 那类（8032） | 8032 | **5868 B** | 下界只占 27% ⇒ **栈被排除**，§9.5 结论成立 |
| `nsh_main`（4000） | 4000 | **1636 B** | 下界 1612 B **已贴到边界** ⇒ **栈论复活** |

⇒ **这个变量必须钉死**（看 `rcS` 里 `sh /data/rc` 的调用者；或行为面区分）。

**推论 3 —— RESULTS.md B8 "唯一没试过的栈档位 131072" 就活在我们眼前**
`com.shell.liangyi` 是**组 45（miwear）里的一个 quickapp 线程**，栈 **131000 B**，
入口 `0x0C8E5798`（落在 `aiotjsc`/`vapp` 区）⇒ 快应用 JS 跑在**自己的 128 KB 线程**上。

## 9.9 框架路径真实栈开销 `X` 的量法（零风险、不重启设备）

`X` 一量出来整件事就闭环（`X` = 从 `sh` 调用点进框架的**峰值**栈用量）：

* **主测（推荐）**：走 **DQ 让一次安装成功**，读 `miwear` 的 `USED` 前后差 ⇒ `ΔUSED ≤ X`
  （`USED` 是历史高水位，所以只会给出下界；若 `X` 小到不抬高 15428 的高水位就量不到，需配合辅测）。
* **辅测**：A/B/C 三个变体里**能正常返回**的那些，让命令末尾 `; sleep 60` 挂着，
  再 `ps` 读它自己的 `USED`（**通用手法：让短命任务多活一会儿，事后读高水位**）。
  真机 `sh -c` 基线 = 1072…2164 B，VVD 同档 = 1072…2112 B，两边一致。

判读表：

| 实测 `X` | 结论 |
|---|---|
| `X ≤ 5868`（8032 档的头余量） | `sh` 档的崩溃**不可能**是栈 ⇒ **语境论成立**（§9.5 定案） |
| `5868 < X ≤ ~30000` | `sh` 可被栈解释，但 **`lua`(32768) 一起崩就无法用栈解释** ⇒ 语境论仍成立 |
| `X > 30000` | 栈论可解释两档。但这要求框架路径吃 30 KB，与"单帧最大 272 B"矛盾 ⇒ 只能来自 **未知钩子 `*(0x200EB690)` 里的大局部数组/深递归**，需专项去挖 |


## 10 地址模型收官 + 钩子写入者的独立复核（2026-10-04）

本节把 §9.3 的负结果从"一次扫描的结论"升级为"三套机制 + 两个阳性对照"的结论，
并顺手把工程里一直当公理用的地址模型**用镜像自己的字节**坐实。

### 10.1 三视图地址模型（字节级证实，不再是"头注释里的假设"）

镜像尾部 `0xD28020` 起是**开机环境配置文本**，它自己报出了芯片与 flash 基址：

```
CHIP=best1503            KERNEL=NUTTX          FLASH_DUAL_CHIP=1
FLASH_BASE=0x2C000000    FLASH_NC_BASE=0x28000000   FLASH_SIZE=0x1000000
OTA_CODE_OFFSET=0xC0000  NV_REC_DEV_VER=2      __userdata_start / USER_SEC_SIZE=0x2000 ...
BUILD_DATE=Aug  4 2026 17:01:58               REV_INFO=:nx_bestbsp_ap
```

镜像最后 8 字节 = `[0xBE57341D][0x280C0000]`，后者 = **NC 视图里 AP 分区的起始地址**
（`0x28000000 + 0xC0000`）。三条视图因此全部自洽：

| 视图 | 基址 | 本镜像落点 | 谁在用 |
|---|---|---|---|
| **CPU / 执行视图** | `0x0C000000` | **`0x0C0C0000`** | 代码指针、`bl` 目标、本工程一直用的 `BASE` |
| flash 控制器视图 | `0x2C000000` | `0x2C0C0000` | rodata/字符串表指针（**同一批字节的另一个视图**） |
| 非缓存 NC 视图 | `0x28000000` | `0x280C0000` | 镜像末尾自报的加载地址 |

* `0xC0000` 三方吻合：`OTA_CODE_OFFSET` = `mkpatch.py` 的 `AP_FLASH_BASE` = 分区表里的 AP 起点。
* **证实方式（读数，不是推理）**：
  * FLSH 指针 `0x2CCA3B04` → foff `0xBE3B04` 解出 `"$on"`；`0x2CB2DF40` → foff `0xA6DF40` 解出 `"id\0\0/proc\0\0\0coun"`；
  * CODE 指针 `0x0CA6A30C` → foff `0x9AA30C` 解出 `cmp/beq.w` + `push.w {r4-r10,lr}` + `sub sp,#8`，
    与 `p5b` 的反汇编**逐字节一致**。
  * 两个视图的 **offset 完全相同** ⇒ 指的是同一批 flash 字节。

⚠️ **术语纠正（别被变量名骗）**：`an.py` / `dump_ddcmd.py` 里的 `DATA_BASE = 0x2C0C0000`
**不是"数据段基址"**，它是同一镜像的第二个视图。它的 `cstr_at_va()` 第二分支没有制造错误
（对 `0x0C..` 系地址判负而跳过），但**名字误导**，后来人容易读成"存在独立 data 段"。

### 10.2 本镜像里没有 `.data` 初始化块（文件级判据）

```
foff 0x000000..0xD26C00   代码 + rodata（含内嵌字面量池）
foff 0xD26C00..0xD2817C   manifest：模块/字符串/资产描述表
                          （全是 0x2C.. 视图的字符串指针 + 0x0C.. 视图的代码指针；
                            尾部 0xD27CD0 起是"app 框架模块(0x0CA6A0xx)"的导出符号表，
                            里面混着两个**数据导出** 0x200EB708 / 0x200EB6A0）
foff 0xD2817C..0xD28188   0 对齐 + 环境文本结束
foff 0xD28188..0xD28190   [校验 0xBE57341D][NC 加载地址 0x280C0000]
```

⇒ **文件从第 0 字节到最后一字节都 1:1 映射到 flash，没有任何"开机拷进 RAM"的数据块。**
RAM（`0x200EB684` 等）的初值**不在本镜像文件里** —— 这正好解释了 §10.3 为什么全镜像找不到
"覆盖该对象的拷贝描述符"。

### 10.3 "`g_appmgr` 全对象 0 写入者" —— 三机制 + 双阳性对照（复核 §9.3）

扫描器换成**前向寄存器溯源**（三套找基址机制并用），并且**强制带阳性对照**：

| 项 | 结果 |
|---|---|
| 找基址的机制 1：字面量池 `ldr` T1（`0x48xx`） | 已覆盖 |
| 找基址的机制 2：字面量池 `ldr.w` T2（`0xF8DF`，**`Rt`/`imm12` 在第二个半字**） | 已覆盖（§10.6 教训） |
| 找基址的机制 3：`movw/movt` 拼绝对地址（不走池） | **全镜像 `movt #0x200E` 出现 0 次** ⇒ 不存在 |
| 基址站点（值落在 `[0x200EB000,0x200EBC00)`） | **1461** |
| 走过的 store | **5253**（基址可解析 **816**） |
| 命中对象窗口 `[0x200EB684,0x200EB6A8)` 的 **store** | **0** |
| 该窗口的 load | 只有 `+0x04` / `+0x08` / `+0x0c` |
| `0x200EB690` 作为**字面量**出现次数 | **0**（连"取这个槽的地址"都没有） |
| **阳性对照 1（store 侧）** | ✅ `0x0CA6A29E strd r3,r3,[r3] → 0x200EB640`（APP_REGISTRY 哨兵自环初始化） |
| **阳性对照 2（本问题直接对照）** | ✅ `0x0CA6A3F8 ldr.w r3,[sl,#0xc] → 0x200EB690`（`app_install` 读钩子槽） |
| 簇内另一个热点（对照） | `0x200EB6E0` 被加载 **516** 次、`0x200EB708` 字面量 **275** 次 ⇒ 扫描器在簇内是活的 |

**残留盲区（明确列出，不掩盖）**：
1. 基址来自 **RAM 里的指针**的那 4437 条未解析 store —— 离线读不到 RAM 值，解不出；
2. `stm` / `vstm` 多寄存器写入（本镜像里没有可解析的命中）；
3. 本文件之外的代码：manifest 里有指向 `0x2CDFE240` 的指针，而 `0x2CDFE240-0x2C0C0000 = 0xD3E240 > 文件长 0xD28190`
   ⇒ **flash 上确实还有本文件之外的区域**。

### 10.4 钩子的真实调用约定（两个调用点，同形）

```
0ca6a546  ldr.w r8,[pc,#0x54]        ; r8 = &g_appmgr (0x200EB684)
0ca6a54a  adds  r2, r6, #2
0ca6a54c  ldr.w r0,[r3, r2, lsl #2]  ; r0 = node->pages[i]    (r3 = node+0x30, [0]=u16 页数)
0ca6a550  ldr.w r3,[r8, #0xc]        ; r3 = g_appmgr->cb
0ca6a554  blx   r3                   ; ★ cb(page_ptr)  —— 单参数
```

* 与 `app_install` 尾部 `0x0CA6A3F8` **同形**（`ldr.w r3,[sl,#0xc]` + `blx r3`），
  两处**都没有 `cbz`/空判**。
* ⇒ 在**能正常开机**的系统里 `*(0x200EB690) != 0` **必然成立**（否则 `blx 0` 立刻 UsageFault）。
* 结合 10.3 的"0 写入者"，再结合 10.2 的"镜像里没有 data 初始化块"：
  **这个槽的定值发生在 `vela_ap.bin` 之外**（NC/别的镜像做的块拷贝，或本文件之外的 flash 区）。
* 语义旁证（**推断，非证明**）：它同时出现在"装页"和"卸页"两条路径上、参数是页指针 ⇒
  形态上是**页/UI 生命周期回调**，这与 §9.5 的"语境论"方向一致。

### 10.5 定案与下一步

**PASS（结论冻结）**
* 三视图地址模型 ✅ 字节级证实；
* 本镜像无 `.data` 初始化块 ✅ 文件级证实；
* `g_appmgr` 全对象在本镜像内 **0 写入者** ✅ 三机制 + 双阳性对照。

**待定（离线不可判）**：`*(0x200EB690)` 的身份。三条路按代价排序：

| 路 | 做法 | 代价 / 前提 | 能拿到 |
|---|---|---|---|
| **2（推荐先做）** | §9.6 的 **A 探针**：在 `sh` 里只调 `app_lookup`（frame=4，纯读链表） | 走已建好的执行体；**不重启、不写 flash** | **语境论成立/被推翻**（与钩子身份无关，直接改设计） |
| 1（并行试） | 读设备 RAM 里 `0x200EB684..+0x20` 这 36 字节 | 需一个能读物理 RAM 的通道：本镜像字符串表里 **`/dev/mem` 0 命中**；候选 `/dev/ram`、`/dev/resource`、`/dev/note/ram`；且需要一个"把字节渲染成可读"的手段 | 钩子真实地址 ⇒ 可离线反汇编它，直接判定"会不会阻塞" |
| 3（兜底） | 离线继续挖 manifest（`0xD26C00` 起的导出/注册表） | 纯离线，耗时，收益不确定 | 该 RAM 对象的注册者/名字，间接逼近身份 |

**建议：2 先做（翻转的是设计层结论，且执行体已在）；1 并行试（零风险，且一旦通道打通就一锤定音）。**

### 10.6 本轮沉淀的逆向教训（本轮全是我自己的 bug，已写进 skill Step 13）

1. **32-bit `ldr.w Rt,[pc,#imm12]` 的 `Rt` 与 `imm12` 都在第二个半字**（`hw1` 恒为 `0xF8DF`）。
   我按"`Rt` 在 `hw1`"解 → **整类站点被漏掉**，表现是**阳性对照查不到 `app_install` 自己那条 `ldr.w`**。
   ⇒ 只要阳性对照不过，先怀疑自己的解码，别怀疑设备。
2. **`movw/movt` 的 `imm3` 在第二半字 `[14:12]`**（不是 `[7:5]`）。我用 capstone 逐条对拍才发现
   （不一致样例：我解 `0x301A`，capstone 解 `0x311A`）。**手写解码必须与 capstone 对拍**。
3. **capstone 对"整镜像"调用 `disasm()` 会在第一条不可解码指令处静默停**（§9.7 第 1 条的整文件版）：
   我在 13.8 MB 上跑全量 sweep 得到"movw/movt = 0 条"，这不是"没有"，是**它早就停了**。
4. **"0 写入者"这类负结果必须自带阳性对照**，而且对照要选**同一类动作**上的已知真例
   （本轮用的是 `strd r3,r3,[r3]` 哨兵自环 + `app_install` 自己读钩子槽），
   否则无法区分"没有"与"扫描器坏了"。

---

# 11 收尾：G0 支点已由真机代偿（2026-10-04）

本文 §5 把 **G0**（"从 `sh` 任务建的 `lv_timer`，回调会不会在 UI 线程跑"）当成整个方案的支点，
且 §6.1 明写"没人在这台设备的 ko 里验过"。

**2026-10-04 真机已经把这条验掉了（用另一个模块、同一台设备、同一固件）：**

| 已验证的事实 | 证据 |
|---|---|
| `lv_timer_create` **从 `dd`/`sh` 语境调，建得成** | Shell++ II 的 `dq_ensure_timer()` 就在 `control_write` 里建；`/data/shellpp-ii-supervisor.log` 里 `C <ptr>` 非 0 |
| 回调**落在能把 `APP_INSTALL(desc,pages,0)` 跑成 `rc=0` 的语境** | 探针 `P5 DQ n=0` → `state=5`（`RESULT_COMPLETED`） |
| 同一调用从 `dd` 语境**同步**跑 = 崩 | 探针 `P3 钩子 n=0` → 硬重启 2/2 |

⇒ **§5 的 G0 可以跳过，直接做 G1（跑完整序列）。**

同时 §9.5 的定案（崩点 = 语境/线程归属，不是栈）与 §10.5 的三条冻结结论**全部维持不变**；
§10.5 表里的"路 2（`app_lookup` A 探针）"也**不必再做** —— DQ 路线已经独立成立。

**仍然未知且决定不追**：`*(0x200EB690)` 的身份（§9.3 / §10.3）。
它挡住的是"解释"，不是"解决"。
另：`S <sp>` 标记已在 supervisor 日志里永久留档（每写一次记一行栈指针），
将来若回头验栈，不必再加探针。

**落地文档**：
* `CONCLUSION.md` —— p3 崩点定案 + 规避（冻结）
* `AUTOSTART.md` —— Chaos 自启动完整方案（ko 补丁全文 + rc 全文 + 验证矩阵）
