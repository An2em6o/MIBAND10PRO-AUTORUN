# Chaos-Module 自启动：怎么做

- 对象：`https://github.com/WenHuaYiYang/Chaos-Module`（master, AGPL-3.0）
- 设备：p67tc / 固件 3.101.043（与该仓库声明一致）
- 本地副本：`%TEMP%\chaos_probe\Chaos-Module-master\`
- 前提结论见 `CONCLUSION.md`；静态逆向细节见 `ANALYSIS.md` §1–§10

> **状态：已实施（2026-10-04）。** 见 `PATCH.md` —— 改动只落在
> `supervisor/src/ipc.rs` 与 `installer/chaos_installer.lua` 两个文件，
> 三道交付门前全绿（ko 宿主 type-check / 搬移块逐字节 / 安装器行为仿真 24 项），
> 且都带负向对照。本文档保留为**方案与理由**；落地细节以 `PATCH.md` 为准。
> 本文的 §5 已同步为落地版本 —— 两档延时 **8 s / 15 s**、防砖窗 **23 s**。
> 如需复算，本文与 `_sim_autostart.py` 的 C1 判据（硬编码 `sleep 8` / `safehold=15`
> / `sleep 15`）必须一致。
>
---

## 0 一句话

**给 `chaos_sup` 加一个"延迟命令号"（DQ）+ 一台 `lv_timer`，rc 里只发 1 条 `dd`。**
ko 侧约 60 行，全是它自己 `fw_api` 已有的 API；Chaos 的 Lua 安装器、14 个页面、
容器格式、手机端 App **一律不动**。

---

## 1 它现在为什么没有自启动

| # | 证据 | 位置 |
|---|---|---|
| 1 | 装机路径写死：配对端投递 → 表盘管理切到它 → 界面点 Run，11 步走完 | `README.md` |
| 2 | 唯一驱动入口是按钮 `onClicked`；跑过一次就拒（`started_once`） | `installer/chaos_installer.lua:68, 480-485` |
| 3 | 全仓无 `rcS` / `/etc` / 开机脚本 | `ls -R` |
| 4 | README 自述"从不 `rmmod`"，"第二次点 Run 会在加载模块那步失败" | `README.md` |
| 5 | **ko 唯一的 UI 线程入口在 `shake_arm()`，而它只被自己页面的 `on_resume` 调用** | `watchface.rs:465-482`、`ui.rs:365` |

第 5 条最关键：**开机那一刻 ko 里没有任何代码跑在 UI 线程上**。
它那个常驻 `lv_timer` 要等你**点开 Chaos 图标**才建起来。
⇒ 就算 rc 里 `insmod` 成功，"没有人"能把注册链推一把。

---

## 2 拦路石：`chaos_write` 是**同步**的

```
chaos_write (ipc.rs:322-413)  ← 谁调它, 整条链就在谁的任务里跑完
  └─ CMD_INSTALL, arg0=0x13
       └─ cmd_install(0x13)                        (ipc.rs:198-300)
            ├─ app_lookup × N                       (0x0CA69935)
            ├─ app_install(meta, items, 14)          (FW_APP_INSTALL 0x0CA6A30D)
            ├─ init_buffer(app_id)                   (0x0C513A45)
            └─ notify_firmware_full()                (ipc.rs:305-319)
                 └─ lvx_notification_insert_message  (FW_NOTIFY 0x0CA9A899)
```

ko 自己的注释（`lib.rs:2`）只说"register_app 内部 malloc/memset 是 thunk→段B(LVGL)，
**需 `fops.write` 上下文**"——它拿它跟"模块上下文"（insmod 任务）做区分，
**但它没有区分"哪个任务的 fops.write"**。

我们把它量出来了（同机同固件，见 `CONCLUSION.md` §2）：

| 执行语境 | 进框架的结果 |
|---|---|
| `sh` / `nsh`（`dd` 在里面跑） | **挂死 → 看门狗硬重启** |
| UI 任务的 `lv_timer` 回调 | 正常返回 |

⇒ **rc 里给 `/dev/chaos` 的那一写，如果 ko 当场就把 `cmd_install` 跑掉，必崩。**
"加个 rcS hook + 复用安装器的写"这条最直觉的路是走不通的。

---

## 3 但 Chaos 有一个**关键差别**（别搞错）

Chaos 的安装器**不是**用 `dd` 写的设备节点：

```lua
-- installer/chaos_installer.lua:257-265
local function send_command(arg0)
  local frame = u32le(CMD_MAGIC) .. u32le(CMD_INSTALL) .. u32le(arg0) .. u32le(0)
  local fh = io.open(DEVICE_PATH, "wb")
  ...
end
```

而 `send_command` 是从 `lvgl.Timer` 回调里调的（`start_runner()`，`:371-387`，周期 1000 ms）。
**那个 Timer 回调就是 UI 任务** ⇒ 它现在能跑通，靠的不是"没走设备节点"，
而是"走设备节点的人是 UI 任务"。

**这条差别不救自启动**：rc 是 `sh`，`sh` 里没有 LVGL。所以还是得改 ko。

---

## 4 解法：给 ko 加一个 DQ 号

### 4.1 我方**已由真机代偿**的 G0 支点

`ANALYSIS.md` §5 原计划先做 G0（"从 sh 任务创建的 lv_timer，回调会不会在 UI 线程跑"）。
**这一条已经不用再单独做实验了** —— 2026-10-04 真机给出：

* `lv_timer_create` **从 `dd`/`sh` 语境调，建得成**（Shell++ II 的 `dq_ensure_timer()`
  就是在 `fops.write` 上下文里建的；`C <ptr>` 标记非 0）；
* 回调**落在能把 `APP_INSTALL(desc, pages, 0)` 跑成 `rc=0` 的语境**（`state=5` = `RESULT_COMPLETED`）；
* 同一调用从 `dd` 语境同步跑 = **崩 2/2**。

⇒ **可以直接跳到 G1（跑完整序列）。**

### 4.2 补丁（`supervisor/src/ipc.rs`，追加 + 两处改动）

新增：`CMD_BOOT_DQ`、`DQ_SEQ`、`dq_timer_cb`、`dq_start`，以及把 `chaos_write` 里的
`match arg0 {...}` 整段抽成 `run_install_cmd`（**只搬不改，不许出现第二份实现**）。

```rust
// ===== 开机自启动: 延迟命令号(DQ) + UI 任务派发 =====
//
// 为什么必须这么写(同机同固件真机实测):
//   * sh / nsh 任务里**同步**调固件注册链 -> write() 不返回 -> rtc_watchdog 硬重启;
//   * 同一个调用改由 lv_timer 回调(UI 任务)执行 -> 正常返回;
//   * lv_timer_create 本身**从 sh 任务里调是安全的** —— 同类模块的 dq_ensure_timer()
//     就是在 fops.write 上下文里建的定时器, 真机两条 DQ 命令(state=5)都正常返回。
// => rc 里的 dd 只"入队即返回", 真正的 cmd_install / notify 由 UI 任务按拍派发。
//    这也保住了安装器原有的时序保证: 一格一拍, 注册链的中间态不会被同一拍读到。

/// 开机序列的触发命令号 —— "3CHS", 与 CMD_MAGIC("1CHS") / STAT_MAGIC("2CHS") 同一命名法。
/// rc 只发这一条; 序列写死在下面, rc 里没有 cmds.bin、没有相对时序。
pub const CMD_BOOT_DQ: u32 = 0x5348_4333;

/// 触发后按拍跑的序列。与 installer/chaos_installer.lua 的 pipeline 同序,
/// 只去掉在 ko 侧落进 `_ => {}` 的三条全空操作(0x0A / 1 / 2):
///   0x18 = 设中文 —— 纯 BSS 写、零固件调用; 开机 BSS 清零, 所以必须每开一次机重设
///   0x13 = 完整注册链(内部已含 init_buffer 与 notify_firmware_full)
///   0x22 = 回读槽统计, 给"注册是否真生效"提供 d0/d1/d2 读数
static DQ_SEQ: [u32; 3] = [0x18, 0x13, 0x22];

const DQ_PERIOD_MS: u32 = 1000;   // 跑序列时(= 安装器 Lua 的原周期)
const DQ_IDLE_MS: u32   = 60000;  // 跑完切慢 —— 常驻 lv_timer 不许用固定频率(续航红线)
const DQ_TRIES_MAX: u32 = 8;

static mut DQ_STEP: u32 = 0;      // 0 = 空闲; n = 下一个要跑 DQ_SEQ[n-1]
static mut DQ_TRIES: u32 = 0;
static mut DQ_TIMER: u32 = 0;
static mut DQ_FIRED: u32 = 0;     // 本次加载只允许开一次(模块每次开机只装一次)

/// 把 chaos_write 里那个 `match arg0 { ... }` **原样**搬过来(含 0x30 的四道门与尾部四词槽位)。
/// 派发路径与 write 路径共用同一份代码 —— 这是本补丁唯一的重构, 不新增任何逻辑。
unsafe fn run_install_cmd(arg0: u32, arg1: u32) {
    match arg0 {
        0    => { fops_wr(FOPS_STEP, 0); cmd_install(0x12); }
        1 | 2 => { /* no-op publish: 不调固件, 仅置 ACTIVE */ }
        0x13 => { fops_wr(FOPS_STEP, 0); cmd_install(0x13); }
        0x43 => { fops_wr(FOPS_STEP, 0); notify_firmware_full(); }
        0x18 => { st_wr!(LANG, 1); }
        0x19 => { st_wr!(LANG, 0); }
        0x22 => {
            fops_wr(FOPS_DBG0, st_rd!(APP_ID));
            fops_wr(FOPS_DBG1, st_rd!(FREE_COUNT));
            fops_wr(FOPS_DBG2, st_rd!(FREE_BITS));
        }
        0x30 => {
            // ← 这里放原 0x30 那一整段(四道门 + commit + request), 逐字不动
            let slot = arg1;
            if slot >= 1 && slot <= font_apply::FONT_SLOT_MAX
                && slot != font_apply::live_get()
                && !font_apply::busy()
                && font_slot_file_ok(slot)
            {
                font_apply::commit(slot);
                font_apply::request();
            }
        }
        _ => {}
    }
    // 每条 INSTALL 类命令收尾都把槽 0 刷成"激活"记录, 与原实现逐词相同
    fops_wr(FOPS_SLOTS, ST_ACTIVE);
    fops_wr(FOPS_SLOTS + 1, 0);
    fops_wr(FOPS_SLOTS + 2, MOD_ID);
    fops_wr(FOPS_SLOTS + 3, 0);
}

unsafe extern "C" fn dq_timer_cb(_t: u32) {
    if DQ_STEP == 0 {
        if DQ_TIMER != 0 { fw_api::timer_set_period(DQ_TIMER, DQ_IDLE_MS); }
        return;
    }
    let i = (DQ_STEP - 1) as usize;
    if i >= DQ_SEQ.len() {
        DQ_STEP = 0;
        if DQ_TIMER != 0 { fw_api::timer_set_period(DQ_TIMER, DQ_IDLE_MS); }
        return;
    }
    let arg0 = DQ_SEQ[i];
    st_wr!(WRITE_BUSY, 1);          // 与 write 路径同一把锁: 拦 notify 触发的 launcher 重入
    run_install_cmd(arg0, 0);
    st_wr!(WRITE_BUSY, 0);
    DQ_STEP = if i + 1 >= DQ_SEQ.len() { 0 } else { DQ_STEP + 1 };
    if DQ_STEP == 0 && DQ_TIMER != 0 {
        fw_api::timer_set_period(DQ_TIMER, DQ_IDLE_MS);
    }
}

unsafe fn dq_start() -> i32 {
    if DQ_FIRED != 0 { return 0; }              // 本次加载只开一次, 不重入
    if DQ_TIMER == 0 {
        if DQ_TRIES >= DQ_TRIES_MAX { return -19; }
        DQ_TRIES += 1;
        let t = fw_api::timer_create(dq_timer_cb as *const () as u32, DQ_PERIOD_MS, 0);
        if t != 0 { DQ_TIMER = t; }
    }
    if DQ_TIMER == 0 { return -19; }            // 8 次都没建成 = 明确失败, 不假装成功
    DQ_FIRED = 1;
    DQ_STEP = 1;
    fw_api::timer_set_period(DQ_TIMER, DQ_PERIOD_MS);
    0
}
```

`chaos_write` 里**只改一处**（把原来那段 `match cmd { CMD_INSTALL => { match arg0 {...} ...槽位四词 } _ => {} }`
换成下面两行 + 保留原有的入口级重入拦截不动）：

```rust
    match cmd {
        CMD_INSTALL => run_install_cmd(arg0, arg1),
        CMD_BOOT_DQ => { let _ = dq_start(); }
        _ => {}
    }
```

**不动 `chaos_read` / 状态块长度 / ABI / 页面 / 容器。** 不新增状态字。

### 4.3 为什么不需要额外加"心跳"

**白拿的活体判据**：`FOPS_STEP`（状态字 word48）足够区分"DQ 跑没跑"——

* 写路径收尾必写 `0xAA`（`ipc.rs:411`），而 `dq_start()` 在它**之前**；
* DQ 回调比写返回晚 ~1000 ms，它会用 `cmd_install` 的 `10..17` 覆盖掉 `0xAA`。

| 状态字 word48 | 含义 |
|---|---|
| `0xAA`（170） | **DQ 没跑**（写返回了，回调没执行） |
| `10..17` | **DQ 跑了** ← 正常值应该是 **17**（register 链走到底） |
| `0x42`（66） | 已注册过，重入跳过（本次开机里跑第二遍） |
| `0x33`（51） | 白名单全占，放弃注册 |
| `0x1F`（31） | 竞态重占 |
| `9` | register 未生效，跳过 init_buffer |

---

## 5 rc 侧（已由安装器 UI 落地，见 `PATCH.md`）

### 5.1 二跳，别覆盖

`/data/rc` 已被 Shell++ II 占用，而且它可能是**被生成器写出来的**
（重跑那个项目的「安装文件」会把你追加的行冲掉）⇒ 只能追加一行，且必须幂等。

**这一步现在由安装器 UI 的「装自启文件」自动完成**（`autostart_install()`）：
先 `read_all("/data/rc")` 看有没有那一行，没有才用 `io.open(path, "a")` 追加。
「清除重置」对应地把**我们自己那一行**摘掉（`autostart_strip()` 逐行过滤，
不动别人的内容）。仿真门 D1 / D3 / E1 / G1 / G2 五条就是冲这个来的。

追加的那一行：

```sh
sh /data/chaos/rc &
```

> **不要**写 `[ -f … ] && sh … &` —— nsh 是子集解释器，`&&` / `[ -e ]` 没证据。
> 把判断题留在 `/data/chaos/rc` 里面（它内部 `if [ -f 开关文件 ]`），
> 文件不在时 `sh` 失败也无害（rc 开头 `set +e`）。

### 5.2 `/data/chaos/rc` 全文

语法逐条取自 Shell++ II 已跑通的 nsh 子集：`set +e` / `if [ -f ]…then…fi` /
`rm -f` / `echo >` `>>` / `sleep` / `insmod` / `dd`。**不含** `&&` `||` `$()`。

两档延时是本项目的参数，写死在安装器里（`AUTOSTART_DELAY` / `SAFETY_WAIT_S`）：

| 参数 | 本机取值 | rc 里对应 |
|---|---|---|
| `AUTOSTART_DELAY` | **8** | `sleep 8` —— 启动后 8 秒才开始干活 |
| `SAFETY_WAIT_S` | **15** | `sleep 15` —— 安全延时拉长到 15 秒 |

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

**防砖语义**（窗口 = 8 + 15 = **23 s**）：

```
t=0    rm -f autostart.on        ← 先关（第一刀）
t=8    insmod
t=9    dd boot.bin               ← 触发 DQ；ko 自己按 1 s 一拍走 3 步
t=24   echo on > autostart.on    ← 整段唯一的重建点
```

⇒ **这 23 秒内任何一次重启（掉电 / 看门狗 / 主动重启），开关都停在【关】**，
下次开机整段跳过。**这就是"防砖"的全部机制**，别把重建开关挪进模块里。

> `sleep 15` 的理由：ko 里 3 步 × 1 s = 3 s，再加 launcher 把桌面条目发出来的时间。
> 15 s 有 3 倍以上余量。

**注意**：`t=24` 的重建由 `sh` 任务完成，**不经过 `lv_timer_handler`** ⇒ 息屏时照跑。
但 ko 那 3 步在 **UI 任务的 lv_timer** 里 ⇒ **息屏时序列会暂停、亮屏继续**。
"开机就插上充电、屏幕黑着"的场景下，Chaos 图标要等亮屏才出现（可接受，但要知道）。

### 5.3 `/data/chaos/boot.bin` —— 16 字节

帧格式 `magic | cmd | arg0 | arg1`，两个"魔数"都挑成了可打印 ASCII：

| 偏移 | 值 | 含义 |
|---|---|---|
| `+0` | `31 43 48 53` | `CMD_MAGIC` = `0x53484331` = **"1CHS"** |
| `+4` | `33 43 48 53` | `CMD_BOOT_DQ` = `0x53484333` = **"3CHS"** |
| `+8` | `00 00 00 00` | arg0 = 0 |
| `+12` | `00 00 00 00` | arg1 = 0 |

⇒ 整串就是 `"1CHS3CHS"` + 8 个 `\0`。

**生成方式（已落地）**：安装器 Lua 用现成的 `u32le()` 拼
（`u32le(CMD_MAGIC) .. u32le(CMD_BOOT_DQ) .. u32le(0) .. u32le(0)`），
写 `/data/chaos/boot.bin` 后**回读逐字节核对**。不依赖 nsh 的 `printf` / `\x` 转义。

---

## 6 分阶段验证（按"每关先做零风险测试"的红线）

**每关都要设备侧原始输出当判据，不许拿"看起来好了"当通过。**

| 关 | 动作 | 判据（期望串，逐字节） | 风险 |
|---|---|---|---|
| **G1'** | 手动：`insmod` 后**手打** `dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc`，等 5 s，`dd if=/dev/chaos of=/data/chaos/s1.bin bs=192 count=1 conv=notrunc` | `s1.bin` 长 192 B；word1(idx0)=`0x53484332`；word3(idx2) ≥ 1（dd 真到了 `chaos_write`）；**word48(idx47) 落在 `10..17`**（DQ 真跑了）而不是 `0xAA`；word45(idx44) 非 0 ⇒ 注册生效 | 一次 panic 预算内 |
| **G1** | 同 G1'，但看**桌面出现 Chaos 图标** | 图标在；点进去 14 页都在 | 同上 |
| **G2** | 铺 rc（`autostart.on` + `/data/chaos/rc` + rc 二跳），**拔电冷启** | `/data/chaos/autostart.log` 尾行 = `cleared`；图标自动出现；连续 3 次冷启 3/3 | 同上 |
| **G3** | 与 Shell++ II 自启动共存 | 两个包各自状态文件都在、互不覆盖；两边图标都在 | 同上 |

**G1' 是支点**：它只验"从 sh 任务建的 lv_timer，回调会不会落在能跑 `APP_INSTALL` 的语境"。
这一条成立，后面全是抄已跑通的配方。

---

## 7 前提、坑与未验点

### 7.1 前提（不在本方案范围内，必须**先**满足）

1. **rcS hook 已在 flash 里**（`sh /data/rc &`）—— 由 Shell++ II 项目打的，本机已成立
   （`/data/rc` 能在开机跑、并且会跑到第 3 条命令，就是证据）。
   没打就得再动 flash 块 —— 那才是真正高风险的一步，与 Chaos 无关。
2. **`/data/chaos/sup.ko` 与 `/data/chaos/chaos_icon.bin` 已在盘上** —— `/data` 掉电不掉，
   所以**手动跑一次官方安装器**（点一次 Run）落盘之后，后面每次开机 rc 都能自启。
   rc 不重复落盘这两份文件。
   * 注意：这两份是**旧版**。改完 ko 要重新部署 `/data/chaos/sup.ko`（再手动跑一次 Run，
     或单独把新 ko 写进去）。

### 7.2 坑

1. **`/data/rc` 会被 Shell++ II 的 `[3] 安装文件` 重写** ⇒ 那条二跳会被冲掉，要重加。
2. **Chaos 从不 `rmmod`**：注册链表条目在卸载后悬空，launcher 下一轮回巡碰到就崩。
   我们的设计是**每次开机 `insmod` 一次**，天然满足 —— **绝不要在 rc 里加卸载逻辑**。
3. **同一开机内不能 `insmod` 第二次**（`/dev/chaos` 已存在 ⇒ insmod 失败）。
   rc 每次开机只跑一次，不冲突；手动调试时注意。
4. **常驻 `lv_timer` 不许用固定频率**（README 的续航红线）。本方案跑完切 `60000 ms`，
   与 `shake_arm` 的"只建一次、永不重建"约定一致（`lv_timer_delete` 地址**未确认**，
   所以只降频不删除）。`TIMER_CREATE_N` 诊断值会从 1 变 **2**（多了一台 boot timer），
   这是预期的，别当回归。
5. **`CMD_BOOT_DQ` 与 `CMD_MAGIC` 不冲突**：magic 校验在 `frame[0]`，命令在 `frame[1]`。
6. **`WRITE_BUSY` 是同一把锁**：DQ 回调跑的那 3 拍里，launcher 的重入写会被静默丢弃 ——
   **与现有设计同语义**，不是新引入的竞态。

### 7.3 未验点（不打包票）

1. `fw_api::timer_create`（thunk `0x0C587ED1`）与另一路直接用的 `0x0C16D475` 是同一个函数 ——
   `ANALYSIS.md` §3 已交叉核对（`register_driver` 两工程逐位相同、`lv_timer_create` 差 Thumb 位），
   但**没人在这台设备的 Chaos ko 里调过它**。失败表现：`dq_start()` 返回 `-19`，
   `DQ_TIMER` = 0，且循环 8 次后停在 `0xAA`。
2. **息屏期间序列暂停**（见 §5.2）。
3. 首次安装仍需**人工一次**（`sup.ko` + 图标 + `boot.bin` + `rc` 落盘）。

---

## 8 第二阶段（本方案之外，但会立刻被问到）

**重启后字体 / 图标会不会自己回来？**

* **字体：不会。** `font_apply::live_get()` 读的是 `FA_LIVE`，**纯 BSS、不落盘**
  （`font_apply.rs:124`）。模块每次开机重新加载 ⇒ BSS 归零 ⇒ 字体池位回 0（安装器自带那份）。
  ⇒ 用户"换了字体"这件事**天生是单次开机内有效**的。
* **图标**：`icon_apply` 的包清单真实来源是 `/data/chaos/icons/index.txt`（**落盘**），
  但把桌面条目指过去的那一步 (`plan_apply`/`step_apply`) 由 `RENDER_REQ` 驱动，
  而那台消费 `RENDER_REQ` 的 timer 只在 `on_resume` 里建 ⇒ 开机后仍要等一次"进 Chaos"。

⇒ 想让自启动"真的完整"，第二阶段要做的是：
**把池位/选择落盘（如 `/data/chaos/font.live`），并在 boot 序列末尾加一步重放**。
属于新增功能，不是本补丁的内容 —— 先别混进来。

---

## 9 落地清单

**已实施，逐步操作见 `PATCH.md` §7。** 要点：

```sh
cd supervisor && sh ../tools/build_ko.sh     # Windows: tools/build_ko.ps1
# 脚本自带四道: cargo -> rust-lld -> fix_ko_layout.py -> verify_chaos_ko.py(未定义符号必须为 0)
```

设备侧顺序：① 重编并部署 `/data/chaos/sup.ko` → ② 重新打包表盘容器（新的
`chaos_installer.lua`）→ ③ 进安装器 `运行` → ④ 进「自启动」页 `装自启文件` + `开自启动`
→ ⑤ **先做 G1'（手动 dd + 回读状态，别急着冷启）**，过了再冷启做 G2。
