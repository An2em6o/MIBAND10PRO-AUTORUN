# Chaos 安装器 → 表盘（`.face`）：已打包

- 日期：2026-10-04（**v2**：把 flash 里那句 rcS 开机 hook **移植进本包**，并加「移除文件」按钮）
- 产物：`face/chaos_inst/output/chaos_inst.face`（**305,836 B**，md5 `c89fcca5a77c2fa9b4771188cde21d18`）
- 交付副本：`C:\Users\Administrator\Desktop\Chaos自启动安装器.face`（同一 md5）
- 流水线：`face/make_chaos_face.py`（一条命令重跑，**100 项判据**，全绿才算过）

> ## ⚠️ 本文写于 **v2**，自启动的 rc 模型已被 **v3** 取代（2026-10-04 第三次改）
>
> - ✅ **仍然成立、一字未改**：**写 flash 那半**（`hook_install()` / `hook_restore()`、§4 判据、§9 那套三段门）。
> - ❌ **已废**：**「二跳」**（往 `/data/rc` 追加 `sh /data/chaos/rc &`）。现在模块只把一份**纯命令**
>   脚本投到 `/data/rc.d/chaos.sh`；**闸 / 安全窗 / 心跳全部归管理器生成的 `/data/rc`**。
>   模块**不再有**自己的闸 `/data/chaos/autostart.on`（安装器 `[安装]`/`[删除]` 都会 `rm -f` 掉）。
> - 📦 **产物已不是上面那个数**：`chaos_inst.face` = **228,452 B / md5 `635076e7e9f9c5b4457137f8f1901ada`（v3）**；
>   上面 305,836 B / `c89fcca5…` 是 **v2**。
> - 📖 最新形状与判据：`MANAGER.md` §12.7 · `Chaos-Module/README.md`「★ 闸在管理器那一层」。

> ## ✅ 自启动要落地的 4 件，**本包全含**（v1 缺的第 ① 件已在本版补上）
>
> | # | 谁做 | 在哪 |
> |---|---|---|
> | ① **flash 里把 rcS 末行 `exit` → `sh /data/rc &`**（AP `/etc` ROMFS 那块 32 KB，flash 第 408 块） | 本包 `dotui.lua` 的 `hook_install()` / `hook_restore()`（v1 缺 ⇒ v2 **已移植**） | ✓ |
> | ② `/data/rc` 末尾追加一行 `sh /data/chaos/rc &`（幂等） | 本包 `dotui.lua` 的 `autostart_install()` | ✓ |
> | ③ `/data/chaos/rc` + `boot.bin` + `/data/chaos/autostart.on` | 本包 `dotui.lua` 的 `build_chaos_rc()` / `autostart_flag()` | ✓ |
> | ④ 收到 `CMD_BOOT_DQ` 帧后按 1 s 一拍走 3 步 | 本包 `chaos_sup.ko` 的 `ipc::dq_timer_cb` | ✓ |
>
> **为什么 ① 是必须的**：原版固件的 rcS 末行是 `exit`，**从不执行 `/data/rc`**
> （实测：原始 `vela_ap.bin` 13,795,728 B 里 `/data/rc` 出现 **0 次**，rcS 尾部就是
> `at_cmd &\nexit\n`）。v1 缺它 ⇒ ②③④ 全都白搭、而且**静默地**白搭。移植源是
> `shellpp2-autostart` 那份已跑通的实现（几何/门/写回全部**原样搬**，32 KB 原块
> 65,536 个 hex 字符逐字符相同，见 §4 判据）。
>
> **写 flash 的两条硬纪律**（都在代码里，不是靠人记得）：
> 1. 界面上是**两段式**：第一次按只探测 + 报状态（`SAME()` 判据证明一个字节都没动），
>    第二次按才动手；
> 2. 任何一处"读不到 / 认不出 / 不符"⇒ **一个字节都不写**：固件版本门 + 载荷自检门
>    （4 处）+ 写前三段门 + 写后回读门 + 相邻块 adler 门。
>
> 另外新增一个 **「移除文件」**按钮（自启动页）：还原 flash hook + 摘 `/data/rc` 我们那行
> + 删全部自启动文件，而**模块 / 图标 / 字体 / 桌面注册项一个都不动**（判据 L8/L9 + §4 的
> "删除表里没有主功能路径"那 5 条）。

---

## 0 v1 → v2 改了什么

| 项 | v1 | v2 |
|---|---|---|
| flash rcS hook（第 ① 件） | ✗ 缺，靠外部工程打 | ✓ 已移植：`hook_install()` / `hook_restore()` / `flash_gate()` / `flash_probe()` |
| 自启动页按钮 | 4 个（装 / 开 / 关 / 返回） | **5 个**（装 / 开 / 关 / **移除文件** / 返回），按钮压到 h=56 |
| 「装自启文件」 | 只落 `/data` 侧文件 | 落文件 **+ 写 flash hook**（两段式确认） |
| 「清除重置」 | 摘 rc 行 + `rm -rf /data/chaos` | 先**还原 flash hook**（临时块在 `/data/chaos` 里，必须赶在 `rm -rf` 之前），再照样清 |
| `dotui.lua` | 31,827 B | **115,170 B**（+83,343 B，其中 65,536 是原块 hex） |
| 表盘 | 221,692 B | **305,836 B** |
| 判据 | 56 项 | **100 项** |

---

## 1 里面装了什么

容器内 3 个文件，**逐个逐字节核对过**（不是"看起来打进去了"）：

| 容器内路径 | 内容 | 字节 | md5 |
|---|---|---|---|
| `_lua/_Lua/dotui.lua` | 打了自启动补丁的 `chaos_installer.lua`（v2 含 flash rcS hook） | 115,170 | `6104a1df825fdd4174ad72a0644e5e3c` |
| `_lua/_Lua/chaos_sup.ko` | supervisor 内核模块（本机新编） | 85,896 | `5c94872a27554151d6575b048b794865` |
| `_lua/_Lua/chaos_icon.bin` | 应用图标（现画） | 50,188 | `4da0ee80e926b15a226480773ffeabff` |

显示名（表盘列表里显示的那行）＝ `Chaos 自启动`；缩略图 336×480，就是 `preview.png` 那张卡面。

`chaos_sup.ko` 是**这次真编出来的**（宿主机原本没有 `nightly` 也没有
`thumbv8m.main-none-eabi`，本轮补装了工具链）：

```
rustc 1.101.0-nightly (0abfedbc7 2026-10-02) / thumbv8m.main-none-eabi
cargo +nightly build --release --target thumbv8m.main-none-eabi -Z build-std=core,compiler_builtins
  RUSTFLAGS="-C target-cpu=cortex-m33 -C target-feature=-fpregs"
-> rust-lld -flavor gnu -r --gc-sections -u module_main -u chaos_ctor -T merge_sections.ld
-> fix_ko_layout.py  -> verify_chaos_ko.py
```

四个自检输出（都留了原文）：

```
未定义符号: 无 (OK)                       <- 留一个就是运行时跳飞
init_array: [('.init_array', 4)]          <- chaos_ctor 挂上了（-u 保住的入口）
重定位类型: {2: 644, 10: 417, 30: 97, 42: 231}
.text 0x6E78 = 28,344 B                   <- ★ 非 0。merge_sections.ld 少写就让 .text 大小为 0,
                                            而加载器会"一声不吭地装成功"、模块里一条指令都没有
```

`.text` + `.rodata` + `.data` ≈ 33 KB，`.bss` 40 KB，远低于 `insmod` 的 256 KB 上限。

---

## 1.5 三个必答的问题

### (1) `dotui.lua` 是怎么回事

`dotui.lua` **不是固件要求的名字**，是"lua 容器型表盘"这个模板里 **Lua 入口的约定名**：

- `.fprj` 里那行 `<Widget … Name="app__lua%2F_Lua%2Fdotui.lua">`（`%2F` = `/`）声明
  "这枚表盘只有一个 Lua 容器控件，脚本在 `app/_lua/_Lua/dotui.lua`"。`compile.exe` 按 `Name`
  去找文件，并把 `app/` 前缀剥掉当容器内路径 ⇒ `_lua/_Lua/dotui.lua`。
- 设备侧运行时把容器里那份 lua 解到 `/data/quickapp/mass/<hex>/_lua/_Lua/`，把该目录塞进
  `SCRIPT_PATH`。**它不认名字** —— 固件里的证据（`vela_ap.bin` 直接搜字符串）：
  ```
  "[%s] %s: script path: %s\n"   "SCRIPT_PATH"   "?.lua"   "failed to load: %s\n"
  "[%s] %s: run script: %s\n"
  ```
  有 `?.lua` 这个模板、有 `SCRIPT_PATH`，而**全镜像里没有 `dotui` 这个串**
  （`dotui` n=0、`_Lua` n=0、`_lua` n=1）⇒ 脚本名由容器声明，不是固件写死的。
- 名字确实能换：本机就有工程用 `app/_lua/_Lua/10p-043-os4icon.lua` +
  `Name="app__lua%2F_Lua%2F10p-043-os4icon.lua"`。
- **但我们不改**：本机**设备侧跑通过**的那 6 枚卡（`probc` / `ioch` / `diag` / `shelldiag` /
  `apblock_async` / `apblock_sync`）无一例外都是 `dotui.lua`。改名要重跑真机，收益是 0。

⇒ 容器里那份 `dotui.lua` 就是 `chaos_installer.lua` **原样改了个名字**
（md5 `6104a1df…` 两边完全相同，v2）。安装器第 48 / 50 行的
`SCRIPT_PATH .. "chaos_sup.ko"` / `.. "chaos_icon.bin"` 之所以找得到，
就是因为模块与图标跟它**同级**摆在 `app/_lua/_Lua/` 下。

### (2) "写 vela AP 的那部分"在不在

分三层说，别混：

| 说法 | 在不在 | 说明 |
|---|---|---|
| **调用 Vela AP 固件的那层封装**<br>`supervisor/src/fw_api.rs` + `fw_api/*.rs` | **在** | 它就是"对 AP 写/调"的那部分 —— 全部 `0x0C…` 绝对地址、描述符字段、`align::` / `trailing::` / `ev::` 常量表都在这里。编译后**内联进 `chaos_sup.ko`**（`--release` + 薄封装，符号级只剩 2 个没被内联的：`fw_api::gfx::obj_is_child_of` / `fw_api::page::data_row_create`） |
| **App 那半**：14 页 `PAGE_TABLE` + 页面钩子 + 派发 + 渲染 | **在** | 这个项目的原生应用**没有单独的文件** —— 模块本身就是那个应用（README：14 个页面的 `on_create` / `on_destroy` / `event` 都在模块的 `PAGE_TABLE` 里） |
| **`vela_ap.bin` 固件镜像本身** | **不在，也不该在** | Chaos **不碰固件分区**（README 第 5 行）。那些地址是**编译期常量**，运行时只是按地址调进去；包里没有、也不需要任何固件镜像 |

这条现在有**符号级判据**了（`make_chaos_face.py` 新加 12 项，直接搜 ko 的 `.strtab` 明文，
不依赖外部工具）：`dq_timer_cb` / `run_install_cmd` / `DQ_SEQ` / `DQ_FIRED` / `cmd_install` /
`PAGE_TABLE` / `chaos_on_create` / `chaos_on_resume` / `chaos_on_destroy` / `render_page` /
`chaos_row_dispatch` / `chaos_ctor` —— **12 个全中**。

其中 `dq_timer_cb` / `DQ_SEQ` / `DQ_FIRED` 是**本轮自启动补丁新增的**，它们出现在 ko 里
＝ **补丁真的编进了这枚表盘**，不是"源码改了但没重编"。

### (3) 改 init rc 的那部分（`/data/rc`）

**在，而且在 `dotui.lua` 里（不是 ko 里）。** 分工是这样：

| 谁 | 干什么 | 在哪个文件 |
|---|---|---|
| **Lua 侧**（安装器） | 写 `/data/chaos/rc`（19 行，含 `sleep 8` / `sleep 15`）；把 `sh /data/chaos/rc &` **追加**到 `/data/rc` 末尾（幂等，已有就不加）；建 / 删开关 `/data/chaos/autostart.on` | `dotui.lua`（＝`chaos_installer.lua`）第 72–77 行常量 + `build_chaos_rc()` / `autostart_install()` / `autostart_strip()` / `autostart_flag()` |
| **`sh` 任务**（开机） | 跑 `/data/rc` → 二跳 → `/data/chaos/rc` → 判开关 → `insmod` 模块 → `dd` 一帧 `boot.bin` → 整段走完才重建开关 | 设备上，**不在包里**（那份 rc 是 Lua 运行时现生成的） |
| **ko 侧** | 收到 `CMD_BOOT_DQ` 帧后建一台 UI 线程 timer，自己按 1 s 一拍走 `0x18` / `0x13` / `0x22` 三步 | `chaos_sup.ko`（`ipc::dq_timer_cb` / `DQ_SEQ`，见上一节的符号判据） |

⇒ "改 init rc"这件事**两份文件各担一半，而两份都在 `.face` 里**：
`dotui.lua` 负责**写**那行二跳，`chaos_sup.ko` 负责**响应**它触发的帧。

> ✅ **v2：固件里那份 init rc（`vela_ap` 的 `/etc/init.d/rcS`）现在也归本包管了。**
> 原版 rcS 末行是 `exit`，**它从不执行 `/data/rc`**；v1 那句 hook 靠**另一个工程**
> 写 flash 打进去，本包不含 ⇒ 只落文件永远不生效。v2 把那段实现**原样搬**进了
> `dotui.lua`：`「装自启文件」` 会一并把 rcS 末行改成 `sh /data/rc &`（同时改 inode 的
> size/checksum），`「移除文件」` 会把那块**写回原样**。细节见下一小节。

### (4) flash 里的 rcS hook（v2 新增）

一句话：**只要 32 KB 里的 22 个字节**——8 字节（rcS inode 的 size=332 + checksum）
和末行窗口里的 14 字节（`exit\n` + 13 个 NUL → `sh /data/rc &\n` + 4 个 NUL）。

| 常量 | 值 | 含义 |
|---|---|---|
| `FLASH_FIRMWARE_CODE` | `3101043` | 内置原块来自固件 3.101.043；版本不符 ⇒ flash 部分整体停用 |
| `FLASH_BS` | `32768` | 一次读/写一个 32 KB 块 |
| `HEAD_END` / `BODY_END` | `0x64EC` / `0x6654` | 前段 / 本身段边界 |
| `WIN_OFF` / `WIN_LEN` | `0x6642` / `18` | 末行窗口 |
| `P_SIZE` / `P_CK` | `332` / `0x8D9C53E2` | 改后 rcS inode 的 size / checksum |
| `ORIG_ADLER` / `PAY_ADLER` | `40877019` / `1E4A726D` | 原块 / 载荷的 adler 指纹 |
| `FLASH_CAND` | `(/dev/ap, 12582912)`、`(/dev/bes_flash, 13369344)`、`(/dev/bes_flash, 12582912)` | 三个候选块设备，谁认出来锁谁 |

**载荷不另存一份，由原块确定性推导**（`ORIG_HEX` 是唯一的原始数据，65,536 个 hex 字符）：

```lua
PAY = ORIG:sub(1, HEAD_END) .. be4(P_SIZE) .. be4(P_CK)
    .. ORIG:sub(0x64F4 + 1, WIN_OFF) .. HPAD        -- HPAD = "sh /data/rc &\n" + NUL×4
    .. ORIG:sub(WIN_OFF + WIN_LEN + 1)
```

**五道门，任一不过 ⇒ 一个字节都不写**：

| 门 | 查什么 | 不过的后果 |
|---|---|---|
| 版本 | `getprop ro.build.version` → `3101043` | flash 部分停用，**文件照落** |
| 载荷自检 | `adler(ORIG)`、`-rom1fs-`@0xE85、`rcS`@0x64F5、`adler(PAY)` | 整个 flash 部分停用 |
| 写前 | 目标块"前段 + 本身段 + 后段"三段逐字节 == 原块 | 不写（"三段不符"） |
| 写后 | 回读逐字节 == 载荷 | 报"回读不符" |
| 相邻 | 前/后相邻块 adler 前后不变 | 报"邻居变了!" |

那"生成出来的 rc 到底对不对"由另一道门管：`_sim_autostart.py`（真 Lua + 假 `lvgl`/`io`
+ **假 flash**，`dd` 是真实现的）把同一份 lua 跑一遍、按按钮、逐行核对 19 行 rc + 二跳幂等
+ 清除只摘自己那行 + flash 的写/回读/还原/零写盘（**61 项**）。
两边是**同一个 md5**（`6104a1df…`）⇒ 那 61 项判的就是包里这份 lua。

★ 一个容易找错的地方：**`/data/chaos/rc` 和 `boot.bin` 都不是预先打好放进包里的**，
而是 Lua 在点「装自启文件」时**现生成**的（`build_chaos_rc()` / `build_boot_frame()`）——
所以包里**搜不到** `set +e` 那种整段 rc 文本，搜得到的是**生成它的代码**
（`w("sleep " .. AUTOSTART_DELAY)` 这种逐行拼接）。这也正是这组判据查的是
`local RC_PATH = "/data/rc"` / `"sh /data/chaos/rc &"` / `local AUTOSTART_DELAY = 8`
这类**代码字面量**、而不是查 rc 全文的原因。

那"生成出来的 rc 到底对不对"由另一道门管：`_sim_autostart.py`（真 Lua + 假 `lvgl`/`io`
+ **假 flash**，`dd` 是真实现的）把同一份 lua 跑一遍、按按钮、逐行核对 19 行 rc + 二跳幂等
+ 清除只摘自己那行 + flash 的写/回读/还原/零写盘（**61 项**）。
两边是**同一个 md5**（`6104a1df…`）⇒ 那 61 项判的就是包里这份 lua。

---

## 2 为什么走 `compile.exe`，而不是仓库自带那条容器链

Chatting 那批卡（`probc` / `ioch` / `shelldiag`）走的是 Mi Create 的
`compile.exe -b <fprj>`，这条路在本机是**跑通过的**（产出的 `.face` 真机上装过）。
仓库自带的 `tools/container_shell.py` 也能生成同魔数的容器，但它：

- `container_shell.py` 里**没有**"从清单打包"的命令行入口 —— 只有 `build_shell()`
  这个函数，真正的调用方在手机端 `chaos-bandpack` 那个 App 里，本机没有；
- 它的样本（`chaos-installer-10p-043-v1.bin` 等三个）是构建产物、不入库，本机一个都没有
  ⇒ `parse → 重建 → 逐字节相同` 这条判据在这台机器上**无法成立**（脚本会按失败退出）；
- 缩略图块它当"参数"收，要用 `extract` 从现成容器里抠 —— 还是得先有一个。

⇒ 用 `compile.exe`：格式同族（同魔数 `0x1234A55A`），工具在手边，且能自己验到底。

---

## 3 打这条链时量出来的 5 件事（都可复用）

1. **`compile.exe` 会把 `app/` 下所有文件原样收进容器**，不是只收 fprj 里点名的那一个。
   - 现场证据：`probc` 的 `probe_module.bin`（70,856 B）在 `probcard.face` 里
     **整段连续出现**（偏移 124866 → 195658），而 fprj 只点名了 `dotui.lua`。
   - 所以 `chaos_sup.ko` / `chaos_icon.bin` 放成 `app/_lua/_Lua/` 的同级文件就能被
     `SCRIPT_PATH .. "chaos_sup.ko"` 读到（这正是安装器第 48/50 行的写法）。
   - 容器内路径 = 工程内路径**去掉 `app/` 前缀**：`app/_lua/_Lua/dotui.lua` → `_lua/_Lua/dotui.lua`。
2. **记录表的终止记录不能用 `uid == 0x05000000` 判。** 实测终止记录里的 uid 是别的槽号：
   2 个文件 → `0x05000000`、3 个文件 → `0x05000002`、真表盘 14 个文件 → `0x05000001`。
   **正确判据是 `off == 0 and len == 0`**，再拿首条记录第 3 个字核尾地址。
   （`container_shell.parse_container` 就是按 uid 判的，所以它解 `10p043_A_图标修复.face` 会报
   "记录表首条形状不符" —— 那不是包坏了，是判据不通用。）
3. **缩略图块之后允许 1~3 字节零填充**（4 字节对齐）。`probcard.face` pad=1、
   本产物 pad=3、`10p043_A_图标修复.face` pad=0。判据要写成 `0 ≤ pad ≤ 3 且全 0`，
   写成 `pad == 0` 会得到假失败（本轮就踩了一次）。
4. 容器**包名（`0x28` 那 12 字节）不由我们控制** —— `compile.exe` 一律填 `167210065`，
   跟 fprj 的 Title、命令行的 ID 参数都无关（`probc` / `ioch` / `10p043` 全一样）。
   fprj 的 `Title` 只决定 `0x68` 的显示名。
5. **中文 Preview 里的小字必须用中文字体。** 用 `consola.ttf` 画"部署模块"会全是豆腐块
   （本轮第一版就是），换 `msyh.ttc` 才对。

---

## 4 判据（`make_chaos_face.py`，**100 项**全绿）

```
== Chaos 安装器 -> 表盘 (.face) ==
  ok   lua 纯 LF（有 CR 设备端会整屏黑）              CR=0
  ok   lua 无 UTF-8 BOM
  ok   lua 以换行收尾
  ok   lua 里能看到自启动那条补丁（CMD_BOOT_DQ）
  ok   dotui.lua 与源逐字节相同                     115170 B  6104a1df...
  ok   ko 是 ELF / 小端 / < 256KB（insmod 上限）
  ok   chaos_sup.ko 与源逐字节相同                  85896 B  5c94872a...
  ok   ko 符号 ×12：dq_timer_cb / run_install_cmd / DQ_SEQ / DQ_FIRED /
       cmd_install / PAGE_TABLE / chaos_on_create / chaos_on_resume /
       chaos_on_destroy / render_page / chaos_row_dispatch / chaos_ctor   ★ §1.5(2)
  ok   icon 50,188 B（112x112 BGRA + 12 头）
  ok   icon 头字段 112x112/stride448                19 10 00 00 112 112 448
  ok   icon 左上角像素透明（四角留白）
  ok   preview.png 336x480
  ok   fprj 写好（UTF-8, DeviceType=11）
  ok   compile.exe 产出 .face                      exit=0  305836 B
  ok   容器魔数 5a a5 34 12
  ok   记录表首条形状 (0,0,tail,0x10)
  ok   slot 0/1/2 记录长度自洽
  ok   终止记录落在首条记的 tail 地址上               0x140 vs 0x140
  ok   容器内文件条数 = 3
  ok   容器内 dotui.lua / chaos_sup.ko / chaos_icon.bin 逐字节 == 源   ★ 三条
  ok   lua 明文里有 chaos_sup.ko / chaos_icon.bin / SCRIPT_PATH / CMD_BOOT_DQ
  ok   lua 里改 /data/rc 那组 ×11（读的是容器里那份，不是源文件）:        ★ §1.5(3)
       local RC_PATH = "/data/rc"        目标就是开机 rc
       "sh /data/chaos/rc &"             往 init rc 末尾补的那一行（二跳）
       io.open(RC_PATH, "a")             追加而不是覆盖
       local function build_chaos_rc     rc 全文的生成器（19 行）
       local function autostart_install  装自启文件
       local function autostart_strip    只摘自己那行（逐行过滤）
       local function autostart_flag     开关文件的建 / 删
       local AUTOSTART_DELAY = 8         启动后 8 s 才干活
       local SAFETY_WAIT_S = 15          安全延时 15 s
       if [ -f                          rc 里的 nsh 子集判句
       echo on >                         rc 结尾重建开关（防砖窗的出点）
  ok   lua 里 flash rcS hook 那组 ×32（同样读容器里那份 lua）:            ★ §1.5(4)
       FLASH_FIRMWARE_CODE = 3101043     固件版本门（只认 3.101.043）
       FLASH_BS / HEAD_END / BODY_END / WIN_OFF          块几何与三段边界
       HOOK = "sh /data/rc &"           要写进 rcS 末行的钩子
       P_SIZE = 332 / 0x8D9C53E2        rcS inode 改后 size / checksum
       ORIG_ADLER / PAY_ADLER           两处 adler 指纹
       ORIG_HEX / PAY = ORIG:sub(...)   原块 + 载荷由原块推导
       -rom1fs-                          romfs 超级块门
       FLASH_CAND / /dev/ap / /dev/bes_flash              三个候选
       flash_gate / flash_probe / flash_read / flash_write / flash_state
       hook_install / hook_restore / autostart_purge
       as_install_all / as_remove_all / AS_BTN / as_armed
       dd … skip=… / dd … seek=… conv=notrunc             读块 / 写块命令形状
       local rok, rmsg = hook_restore()                   清除重置也还原 flash
  ok   容器内 ORIG_HEX = 65536 个 hex 字符 (32KB)
  ok   容器内原块 == 上游 main.lua 里的原块（逐字符）       src=65536   ★ "原样搬"的硬判据
  ok   删除表 AS_FILES 含 CHAOS_RC / BOOT_FRAME / FLAG_ON / AS_LOG
  ok   删除表里**没有**主功能路径 ×5:
       SUPERVISOR_PATH / ICON_PATH / ICON_DIR / FONT_DIR / FONT_NAMES
       ⇒ 移除自启动不可能误删模块 / 图标 / 字体           ★ §0 那行"不影响主功能"
  ok   缩略图块 336x480 tag=0x400
  ok   缩略图块之后只剩 0 填充（≤3B 对齐）             pad=1
  ok   显示名 = fprj 的 Title                      'Chaos 自启动'

MAKE-FACE: PASS
```

**这条链的门里没有"设备侧"那一环** —— 下面第 6 节的 G1' 才是真判据。
flash 那半另有 12 项在 `_sim_autostart.py` 里（写/回读/还原/零写盘/固件门/两段式），
它由 `check_all.py` 的 G3 自动带上（`SIM-AUTOSTART: PASS (61)`）。

---

## 5 怎么重跑

```sh
cd C:\zcode\chaos-autostart\face
python make_chaos_face.py          # 需要能 import PIL / Pillow
```

它会重摆 3 个文件、重画 preview、重写 fprj、重编译、重验容器。
前置：`Chaos-Module/supervisor/chaos_sup.ko` 得先在（见 §1 那条命令）。

---

## 6 设备侧怎么用

1. 把桌面那份 `Chaos自启动安装器.face` 传到手机，走**表盘侧载**那条路装进去
   （跟平时装第三方表盘/图标包完全一样）。
2. 表盘列表里切到它（显示名 **Chaos 自启动**），安装器界面出现。
3. 点 **`运行`** → 11 步：部署模块 → 部署图标 → (字体槽跳过) → 加载模块 → 检查设备 →
   设置语言 → 恢复占位 → 注册应用 → 通知系统 → 发布应用 → 发布桌面条目。
4. 走完桌面出现 Chaos 图标。

**自启动**：进「自启动」页 → `装自启文件`（**按两次**）→ `开自启动`。

「自启动」页现在 5 个按钮（为了塞进一屏，高度压到 56），其中两个是**两段式**——
第一次按只探测 + 报状态，**一个字节都不写**；第二次按才动手：

| 按钮 | 第一次按 | 第二次按 |
|---|---|---|
| `装自启文件` | 探三个候选块 + 固件门，上屏 `块ap-rel 原样 再按=写入`（或 `写盘停用 再按=只落文件` / `没认出块 再按=只落文件`） | 落 `/data` 侧文件（`boot.bin` + `rc` + rc 二跳）**+ 写 flash 的 rcS hook**，写后回读逐字节核对 |
| `移除文件` | 上屏 `再按一次: 还原hook+清文件` | 还原 flash hook（写回原块）+ 摘 `/data/rc` 里我们那行 + 删全部自启动文件；**模块 / 图标 / 字体 / 桌面注册项一个不动** |
| `开自启动` / `关自启动` | 直接生效（建 / 删开关 `autostart.on`） | — |
| `< 返回` | 回主视图（并清掉两段式的闸，免得下次进来第一按就动手） | — |

> 状态行装不下完整原因；**完整理由**（三段 DIFF 的具体偏移、adler 值、邻居指纹前后对比）
> 全部走 `print()` 进设备日志，前缀 `[chaos-installer]`。要不要动 flash、动没动成功，
> 以日志那几行 + 回读结果为准。

**如果这台设备上已经跑过 Shell++ II 的「1 安装自启动」**，那块 flash 已经是"已装"状态：
- `装自启文件` 第一次会显示 `块<名> ==载荷 再按=写入` 或 `块<名> 已装 再按=写入`；
- 第二次按走"已经是载荷"分支，**不重写**（幂等），文案 `文件OK 已是载荷`；
- 想还原就用 `移除文件`（它认前/后段相符才写回，不会误伤别人的改动）。

### ★ 先做 G1'（别急着冷启）

```
dd if=/dev/chaos of=/data/chaos/s1.bin bs=192 count=1 conv=notrunc
dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc
sleep 20
dd if=/dev/chaos of=/data/chaos/s3.bin bs=192 count=1 conv=notrunc
```

判 `s3.bin` 状态字 word48（字节偏移 192）：

| 值 | 含义 |
|---|---|
| `0xAA`(170) | **DQ 没跑** —— rc 发了帧，ko 里那台 timer 没起来（先查 `dq_start()` 返回值是不是 `-19`） |
| `10..17` | **DQ 跑完** ← 正常应该是 **17**（register 链走到底） |
| `0x42` | 本开机内已注册过，重入跳过 |
| `0x33` | 白名单全占，放弃注册 |

过了 G1' 再冷启做 G2（不装任何东西，重启后看桌面图标是否自己回来）。

---

## 7 未做 / 风险（不打包票）

0. **★ v1 最大的那个缺口（vela_ap 里的 rcS hook 不在本包里）已在 v2 关闭**：
   - **问题**：原版固件从不跑 `/data/rc`。硬证据：直接搜原始 `vela_ap.bin`（3.101.043，
     13,795,728 B）—— `/data/rc` 出现 **0 次**；rcS 正文 @`0xc06512`（对应路径串
     `/etc/init.d/rcS` @`0xa6d434`）**末行就是 `exit`**：`at_cmd &\nexit\n\0\0…`。
     Shell++ II 自启动的 README 把这条穷举过、写死了结论：
     「**固件里没有任何"免写 flash"的开机钩子。** 穷举过：init 脚本只认
     `/etc/init.d/{rc.sysinit,rcS}`；`/data` 没有脚本钩子；quickapp 注册表无 `autostart` 字段；
     全镜像唯一的脚本路径 `/init.lua` 只是 Lua 的默认 `LUA_PATH`。」
     后果：没有那句 hook，本包的「装自启文件 / 开自启动」会**全部报成功、但永远不生效**。
   - **v2 的处置**：把 `shellpp2-autostart` 里那份**已跑通**的实现原样搬进 `dotui.lua`
     —— 32 KB 原块（65,536 个 hex 字符，与上游逐字符比对过）、块几何、adler/三段判定、
     读写块、五道门、写回；界面上是 `装自启文件` / `移除文件` 两个**两段式**按钮。
   - ★ **还没真机验的**：这台设备上 `/dev/ap`（或 `/dev/bes_flash`）到底能不能读、
     第 408 块内容是不是就是我们内嵌的那份原块。**第一次按 `装自启文件` 只探测**，
     固件 code 不符或认不出块都会走"只落文件、不碰 flash"这条路 —— 这一步不会造成任何写入。
     真正写 flash 是**第二次按**，且写前必须先过三段门。
   - **零风险对照**：如果这台设备已经跑过 Shell++ II 的「1 安装自启动」，
     那块 flash 就已是"已装"，本包第二次按会走"已是载荷 ⇒ 不重写"分支。

1. **★ 包名跟别的卡撞车。** `compile.exe` 一律填 `167210065`（§3.4），
   跟 `10p043_A_图标修复.face`、`probcard.face` 等**同一个包名**。
   固件按包名判"是不是同一个包" ⇒ 装这个可能**顶掉**你手上同包名的表盘。
   想要一个独立包名，只能走仓库那条 `container_shell.build_shell(files, pkg_name=...)`
   —— 但那条链本机缺样本、没有前端，见 §2。
2. **`.face` 这条链没在本机验证过设备行为** —— 结构判据只证明"文件齐、位置对、字节一致"，
   不证明固件会跑它。真正的第一个判据是 §6 第 3 步：界面有没有出来。
3. **`fw_api::timer_create`（thunk `0x0C587ED1`）仍未真机验过**（`PATCH.md` §8.2 同一条）。
   失败签名 = `dq_start()` 回 `-19`、步号永远停在 `0xAA`；兜底一行换裸地址 `0x0C16D475`。
4. **字体槽是空的**（`lxgw.ttf` 未放）。安装器第 2.5 步会自己跳过（"容器里没这一槽：
   交给投递包"），不影响主流程；要换字体得另打字体投递包。
5. **息屏期间 ko 那 3 步会暂停**（在 UI 任务的 `lv_timer` 里），rc 那半照跑。
6. **符号/节区没做真机对照** —— `e_flags` 与 `.ARM.attributes` 是照 README 的 flag 配出来的，
   但没有跟固件自带模块逐字段比过；`insmod` 会不会认，只有设备能给答案。
7. **写 flash 这一段是"照搬已跑通实现"，不是本机独立验证过的** —— 五个候选偏移里
   Chaos 只用得上 `FLASH_CAND` 那三个；上游是在同一型设备上跑通的，但**本机的 flash
   布局没被独立核对过**。真正会写盘的那一次，务必先看第一次按的探测文案 + 设备日志：
   必须是 `块ap-rel 原样`（或 `==原块`）才继续。判据侧能保证的是"**认不出/不符就不写**"。
