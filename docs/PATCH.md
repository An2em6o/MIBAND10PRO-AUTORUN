# Chaos 自启动补丁 —— 已实施

- 日期：2026-10-04
- 基线：`Chaos-Module` master（AGPL-3.0），本地副本 `%TEMP%\chaos_probe\Chaos-Module-master`
- 工作树：`C:\zcode\chaos-autostart\Chaos-Module\`
- 依据：`AUTOSTART.md`（方案）、`CONCLUSION.md`（为什么必须走 DQ）
- **节奏按你的要求改过**：启动后 **8 s** 才干活；安全延时 **15 s**

---

## 1 改了哪两个文件（另加 1 个留底文件，全仓再无其它改动）

`diff -rq <上游 master> Chaos-Module` 的输出**只有三行**：
```
Files .../installer/chaos_installer.lua and .../installer/chaos_installer.lua differ
Only in .../supervisor/src: _moved_block.txt
Files .../supervisor/src/ipc.rs and .../supervisor/src/ipc.rs differ
```
⇒ 2 个文件被改 + 1 个新增留底（`_moved_block.txt`，**不参与编译**，只为逐字节复核）。

| 文件 | 改动 |
|---|---|
| `supervisor/src/ipc.rs` | 新增 DQ 块（`CMD_BOOT_DQ` / `DQ_SEQ` / `dq_timer_cb` / `dq_start`）；把 `chaos_write` 里 `match arg0 {…}` **原样**搬成 `run_install_cmd(arg0, arg1)`；`chaos_write` 的派发换成两行 |
| `installer/chaos_installer.lua` | 自启动那半：常量 + `build_chaos_rc` / `build_boot_frame` / `autostart_install` / `autostart_strip` / `autostart_flag` / `autostart_state_text`；界面拆成**主视图 + 自启动页**，新增 4 个按钮 |

补丁全文：`patches/ipc.rs.diff`（197 行）、`patches/chaos_installer.lua.diff`（327 行）。
被搬走的那段代码留底在 `Chaos-Module/supervisor/src/_moved_block.txt`（2334 B，供逐字节复核）。

三个文件的 md5（复核用）：

| 文件 | md5 | 大小（字符 / 字节） |
|---|---|---|
| `supervisor/src/ipc.rs` | `b3c33d4152292373d177142faab290c1` | 16198 → **19157** / 19696 → **23731** |
| `installer/chaos_installer.lua` | `6104a1df825fdd4174ad72a0644e5e3c` | 17119 → **105212** / 21691 → **115170** |
| `supervisor/src/_moved_block.txt` | `228f944a48e65a416f45da44bfc59e62` | 2334 / 3098（新增） |

> 同一份文件"字符数"和"字节数"会差 1.2~1.3 倍（中文注释、UTF-8 三字节）——
> 报大小别只报一个数，否则复核时对不上。
>
> `chaos_installer.lua` 这一行是 **v2** 的数（含 flash rcS hook 那半）：v1 是
> `8269f259f82b0a6ee63819fe323774f6` / 25203 字符 / 31827 B。v2 增量 83,343 B 里
> **65,536 B 是原样搬进来的 32 KB 原块 hex**（占 78.6%），其余是门 / 读写块 / 还原 / UI。

**没有改的**：`chaos_read` / 状态块长度 192 / 驱动节点 / 14 个页面 / 容器格式 / 手机端 App。

---

## 2 节奏（本次唯一与上游平台不同的地方）

| 参数 | 位置 | 值 | rc 里对应 |
|---|---|---|---|
| `AUTOSTART_DELAY` | `chaos_installer.lua` | **8** | `sleep 8`（启动后 8 秒才开始） |
| `SAFETY_WAIT_S` | `chaos_installer.lua` | **15** | `sleep 15`（安全延时拉长到 15 秒） |

⇒ **防砖窗 = 8 + 15 = 23 秒**：`t=0` 删开关 → `t=8` insmod → `t=9` 发触发命令
→ `t=24` 整段走完才重建开关。窗内任何一次重启（掉电 / 看门狗 / 主动重启）
都让开关停在【关】，下次开机整段跳过。

---

## 3 生成的 `/data/chaos/rc`（仿真门实测输出，722 B）

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

语法逐条取自 Shell++ II 已跑通的 nsh 子集：`set` / `if` / `rm` / `echo` / `sleep` /
`insmod` / `dd` / `fi`。**不含** `&&` `||` `$()` `[ -e ]`。

## 4 `/data/chaos/boot.bin`（16 字节）

```
31 43 48 53 33 43 48 53 00 00 00 00 00 00 00 00
└── "1CHS" ─┘└── "3CHS" ─┘└── arg0 ──┘└── arg1 ──┘
  CMD_MAGIC    CMD_BOOT_DQ
```

两个"魔数"都挑成了可打印 ASCII ⇒ 整串就是 `"1CHS3CHS"` + 8 个 `\0`，落盘后肉眼能核。

---

## 5 UI 侧（和 Shell++ II 一样的地方 / 不一样的地方）

**一样**
* 自启动的操作**由安装器的 UI 侧落盘**，不由人手打 nsh。
* 操作放**独立一页**（Shell++ II 是 `自启动` 页，这里是主视图的「自启动」入口）。
* 开关语义同形：`autostart.on` 存在 = 开；rc 里"先删后建 + 安全窗"。
* `装文件` 与 `开关` 分开两个动作（对应 Shell++ II 的 `3 安装文件` 与 `5 开 / 6 关`）。
* 落盘后**回读核对**（`write_file` 内置），失败会明说原因，不假装成功。
* **v2 起和 Shell++ II 一样也写 flash 那句 rcS hook** —— 移植的就是它那份实现。

**不一样**
* 两档延时：**8 s / 15 s**（Shell++ II 是 5 s / 10 s）。
* 写 flash 是**五个候选偏移里的三个**（Chaos 只带 `FLASH_CAND`，见 `FACE.md` §1.5(4)），
  且界面上做成**两段式**：第一次按只探测 + 报状态，第二次按才写。

**Chaos 特有、Shell++ II 没有的**
* **二跳而不是整体覆盖**：`/data/rc` 已被 Shell++ II 占用，Chaos **只追加一行**
  `sh /data/chaos/rc &`，且**幂等**（已有就不再加）；「清除重置」只摘掉**我们自己那一行**，
  不动别人的内容。仿真门 D1/G1/G2 三条就是冲这个来的。
* rc 里**没有** `cmds.bin`、**没有**多段相对时序 —— 序列写死在 ko 里，rc 只发 1 条命令。
* **「移除文件」是"只删自启动"**：Shell++ II 的移除是 `rm -rf` 它自己的目录；Chaos 的
  `/data/chaos` 里同时住着**主功能**（`sup.ko` / 图标 / 字体 / 图标包），所以移除只按
  `AS_FILES` 那张白名单删，且**先还原 flash**（临时块就在 `/data/chaos` 下，必须赶在
  任何 `rm` 之前）。判据 L8/L9 + "删除表里没有主功能路径 ×5"就是冲这个来的。
  要连主功能一起清，用主视图的「清除重置」。

### 界面

| 视图 | 控件 |
|---|---|
| 主视图 | 标题 + 状态卡 + `运行` / `自启动` / `清除重置`（h=64） |
| 自启动页 | 标题 + 状态行 + `装自启文件` / `开自启动` / `关自启动` / **`移除文件`** / `< 返回`（**h=56**，5 个才塞得进一屏） |

自启动页的 `装自启文件` 与 `移除文件` 是**两段式确认**（`as_armed` 闸，和主视图那个
`wipe_armed` 同一套做法）：第一次按只探测 + 报状态、**一个字节都不写**；第二次按才动手；
`开自启动` / `关自启动` / `< 返回` / 进页 / 清除重置都会**清闸**，免得下次进来第一按就动手。
`make_button` 从 v2 起收一个可选的 `opts = {h, r, font}`（默认 64 / `V_R` / 24），
**只有自启动页传 `AS_BTN = {h=56, r=20, font=22}`** —— 高度变了圆角要跟着收，
56px 配 24 圆角就快成胶囊形了（那条"不用胶囊形"的约束还在）。

切页用 `align` 的 `y_ofs` 位移（`OFF_Y=3000`），**不用 hidden 标志**——
位移是纯布局，不依赖任何在本设备上没验证过的属性。
状态行**单行、不设 width**（本设备实测"设宽度 + text_align"那套不生效）。
flash 那半的完整理由（三段 DIFF 偏移 / adler / 邻居指纹）**只走 `print()` 进日志**，
不上屏 —— 状态行一行放不下，硬塞就会被裁切。

---

## 6 交付前门（三道，全部带负向对照）

```
$ python check_all.py --selftest
== Chaos 自启动补丁 · 交付前门 ==
  ok   G1-负向: 故意注入语法错必须被咬住
  ok   G1 ko 编译门 (宿主 type-check)
       -> 0 error / 0 warning
  ok   G2 搬移块逐字节相同
       -> 2334 B  md5 228f944a48e65a416f45da44bfc59e62
  ok   G3 安装器行为门
       -> SIM-AUTOSTART: PASS (61)
       -> 退用 venv: C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe

CHECK-ALL: PASS (3/3)
```

> G3 要在**装了 `lupa` 的解释器**里跑。`check_all.py` 会自己探：当前解释器没有 `lupa`
> 就退到上面的 venv；两处都没有就把门报成一句 `环境缺失: lupa 未安装`，
> **不再崩成 traceback**（原先用裸解释器跑会得到一个看不懂的 `ModuleNotFoundError`，
> 很容易被误读成"补丁坏了"）。

| 门 | 怎么判 | 负向对照 |
|---|---|---|
| **G1** `rustc --emit=metadata`（宿主目标，整个 crate 一起 type-check） | 0 error / 0 warning + 产出 `libchaos_sup.rmeta` | 往 `ipc.rs` 尾巴塞 `fn broken( { }` ⇒ 必须报 `unclosed delimiter` ✅ |
| **G2** 搬移块逐字节 | 把 `run_install_cmd` 的函数体减掉 4 格缩进，必须与搬走前的原文逐字节相同 | 任一字符改动即 md5 不符 |
| **G3** `_sim_autostart.py`（真 Lua + 假 lvgl / 假 io / 假 `os.execute` + **假 flash**） | **61 项** | 把延时改回 5/10 ⇒ `C1 rc 19 行逐条相同` 立刻 FAIL ✅ |

G3 覆盖：载入不报错 / 8 个按钮都在 / `boot.bin` 16 B 逐字节 / rc 19 行逐条 + 两条延时 +
行首词白名单 + 无 `&&`/`||`/`$()` + 每行 ≤255 B / 只追加不覆盖 / 二跳幂等 /
开关开与关 / 清除只摘自己那行 + 还原 flash；**flash 那 12 项**：两段式第一次按零写盘、
目标块逐字节 == 载荷、只动目标块（窗口内 diff 全落在 `[32768, 65536)`）、相邻块 adler 未变、
三段任一不符（前段坏 / 本身段坏）零写盘、固件 code 不符整体停用但文件照落、
移除写回原块 + 邻居不变 + 自启动文件全删 + **主功能 4 个文件一个不少**。

> 假 shell 里 `dd` 是**真实现**的（`if/of/bs/skip/seek/count/conv=notrunc`，作用在内存
> flash 镜像上）。不实现它，"写 flash"就只是往命令表里记一条字符串 —— 那样任何写错误
> 都测不出来（假阳性）。

---

## 7 设备侧落地

```sh
# PC 侧
cd Chaos-Module/supervisor
sh ../tools/build_ko.sh          # Windows: tools/build_ko.ps1
# → supervisor/chaos_sup.ko（脚本自带四道: cargo / rust-lld / fix_ko_layout / verify_undefined=0）
```

1. **重编 ko** 并部署到 `/data/chaos/sup.ko`（旧的那份是没补丁的）。
   首次仍要**手动跑一次安装器**：`/data` 掉电不掉，落盘之后后面每次开机 rc 都能用。
2. **把新的 `installer/chaos_installer.lua` 重新打进表盘容器**（你原来的装机流程）。
3. 手环上进安装器 → `运行`（11 步走完，桌面出现 Chaos）。
4. 进「自启动」页 → **`装自启文件`（按两次）** → **`开自启动`**。
   - **第一次按只探测**（一个字节都不写），状态行应是 `块ap-rel 原样 再按=写入`；
     若设备上跑过 Shell++ II 的自启动，会看到 `块ap-rel ==载荷 再按=写入` 或 `已装`；
     若固件 code 不对/认不出块，会是 `写盘停用 再按=只落文件` / `没认出块 再按=只落文件`。
   - **第二次按**：落 `/data` 侧文件 +（过门就）写 flash 的 rcS hook，上屏 `文件+hook 已装`。
   - 再按 `开自启动`，状态行应显示 `开关:ON  文件:就位  rc:722B  延:8+15`。
   - 设备日志（前缀 `[chaos-installer]`）里应有
     `hook install @ ap-rel state=原样 前OK 本原样 后OK` 与
     `hook 写后 回读==载荷; 邻居前 X->X 后 Y->Y`。
   - 想撤掉自启动但**保留已装好的应用**：`移除文件`（也按两次）—— 还原 flash hook +
     摘 `/data/rc` 那行 + 删全部自启动文件；`sup.ko` / 图标 / 字体 / 桌面注册项都不动。
5. **先做 G1'（手动，别急着冷启）**：

```sh
# 在任意能拿到 nsh 的地方, insmod 之后:
dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc
sleep 6
dd if=/dev/chaos of=/data/chaos/s1.bin bs=192 count=1 conv=notrunc
```

回读 `s1.bin` 判据（**别拿 `dd` 返回 ok 当通过**，那只说明入了队）：

| 字 | 偏移 | 期望 |
|---|---|---|
| `words[1]` | 0 | `0x53484332`（`STAT_MAGIC`） |
| `words[3]` | 8 | ≥ 1（dd 真的到了 `chaos_write`） |
| `words[48]` | 188 | **不是 `0xAA`(170)**，应落在 `10..17`（`17` = register 链走到底）← **DQ 真跑了的判据** |
| `words[45]` | 176 | 非 0 ⇒ 注册生效 |

6. 过了再铺冷启：冷启 **3/3**、图标自动出现、`/data/chaos/autostart.log` 尾行 = `cleared`。

---

## 8 未做 / 风险（不打包票）

1. **ko 已经本机编出来了**（补装了 nightly + `rust-src` + `thumbv8m.main-none-eabi`）：
   85,896 B，未定义符号 0，`.text` 28,344 B（**非 0**），符号面貌见 `FACE.md` §1。
   但 G1 仍是**宿主目标**的完整 type-check，跟真机加载是两回事：`insmod` 认不认
   （`e_flags` / `.ARM.attributes` 没跟固件自带模块逐字段比过）只有设备能给答案。
2. **`fw_api::timer_create`（thunk `0x0C587ED1`）没在 Chaos 的 ko 上真机验过**。
   它和 Shell++ II 直接用的 `0x0C16D475` 是同一条路的两个入口（`register_driver` 两工程逐位相同、
   `lv_timer_create` 只差 Thumb 位），但这是**静态核对**不是实测。
   * 失败签名：`dq_start()` 返回 `-19`、`DQ_TIMER` = 0、步号永远停在 `0xAA`。
   * 兜底（一行）：把 `fw_api::timer_create(...)` 换成裸地址
     `let f: unsafe extern "C" fn(u32, u32, u32) -> u32 = core::mem::transmute(0x0C16_D475usize); f(cb, 1000, 0)`。
3. **息屏期间序列会暂停** —— ko 那 3 步在 UI 任务的 `lv_timer` 里，息屏不跑、亮屏继续。
   rc 那半（`sleep` / `dd` / `echo`）是任务级挂起 + VFS，**息屏照跑**。
   所以"开机就插上充电、屏幕黑着"的场景：rc 跑完了，图标要等亮屏才出现（可接受，但要知道）。
4. **`/data/rc` 会被上游平台的「安装文件」重写** ⇒ 那行二跳会被冲掉，需要重按一次
   `装自启文件`（它是幂等的，重复按安全）。
5. **第二阶段没做**：重启后**用户选的字体不会自己回来**（`FA_LIVE` 是纯 BSS、不落盘）；
   桌面图标清单落盘，但"把条目指过去"那一步由 `on_resume` 才建的 timer 消费
   ⇒ 仍要"进一次 Chaos"。要真完整得加落盘 + boot 重放，属于新增功能，没混进这次补丁。
6. **★ v2 新加的写 flash 那段，是本机"照搬已跑通实现 + 离线门"，没在真机上走过一次**。
   - 已能保证的：认不出块 / 三段不符 / 固件 code 不符 ⇒ **一个字节都不写**（J/K 两组判据）；
     写后回读必须逐字节等于载荷（I1）；相邻块 adler 必须不变（I5/I6，安装器自己也核）。
   - **不能保证的**：`/dev/ap` 或 `/dev/bes_flash` 在这台设备上到底存不存在、能不能读、
     第 408 块（byteoff 12582912）内容是不是我们内嵌的那份原块。上游是在同型设备上跑通的，
     但不是**这台**、也不是**这个固件构建**逐字节核对过的。
   - 操作纪律：**第一次按只探测**，必须看到 `块ap-rel 原样`（或 `==原块`）才按第二次；
     看到 `没认出块` / `写盘停用` 就别按第二次。
   - 另外 `HOOK_STR` 只改 rcS **末行 18 字节** + inode 的 size/checksum，**其余 32 KB 一个
     字节不动**（判据 I3/I4：窗口内 diff 全落在目标块内、且 ≤30 字节）。但这条是静态
     推导 + 离线门，真机上"改完内核还认这个 romfs 块"没有实测过。

---

## 9 文档同步（收尾记录）

| 产物 | 状态 | 备注 |
|---|---|---|
| `AUTOSTART.md` | **已同步为落地版** | md5 `3ab8d7739885d96eb9d4996ba883cffa` / 20268 B；改写脚本 `_patch_doc.py`（**一次性**，重复跑会被断言咬住） |
| `AUTOSTART.md.pre-patch` | 留档 | md5 `bee3c4c8db820e4eaffdb6a0837cc65b`（改写前原文，只作对照） |
| `PATCH.md` | 本文 | —— |
| `CONCLUSION.md` | 未动 | 前面研究的结论冻结，与本次实施无关 |
| `ANALYSIS.md` | 未动 | §11 记录"G0 支点已由真机代偿" |
| `FACE.md` | **v2 已同步** | 表盘产物 / 判据数 / 设备侧操作单 / 风险表都按 v2 改过；`_port_flash_hook.py`（一次性）把原块搬进去 |
| `AUTOSTART-GUIDE.md` | **新建** | 《自启动适配指南》—— 对外可复用：改了哪些东西 / 每处怎么改（代码级）/ **换成别的模块怎么做**（决策表 + 10 步 + 判据 + 坑清单 + 常量速查） |

`AUTOSTART.md` 那次改了四处：① 文首插入状态说明；② §5 换成"已由安装器 UI 落地"
版本（rc 全文改为 **8 s / 15 s**、防砖窗 **23 s**）；③ §9 指向本文件 §7；
④ 全文不再出现旧的 5 / 8 延时。

`FACE.md` 这次改了七处：① 文首 ⚠️"本包不含 ①"→ ✅"4 件全含"；② 新增 §0 v1→v2 对照表；
③ §1.5(3) 的 ⚠️ 改成"现在也归本包管"+ 新增 §1.5(4) flash rcS hook（常量表 / 载荷推导 /
五道门表）；⑤ §4 判据 56→100 项并补上 flash 那两组；⑥ §6 设备侧加"两段式按钮"表 +
"已装过 Shell++ II 时怎么办"；⑦ §7 第 0 条从"最大缺口"改成"已关闭 + 剩下没真机验的是什么"。

---

## 10 打包成表盘（`FACE.md`）

`chaos_installer.lua` + 新编的 `chaos_sup.ko` + `chaos_icon.bin` 已打成表盘：

| 产物 | 大小 | md5 |
|---|---|---|
| `face/chaos_inst/output/chaos_inst.face` | 305,836 B | `c89fcca5a77c2fa9b4771188cde21d18` |
| `…/Desktop/Chaos自启动安装器.face`（副本） | 同 | 同 |

> v1 的产物是 221,692 B / `36780117fb96f11b172fb3cf913cd8b8`；v2 因为把 32 KB 原块
> 内嵌进 lua，包体 +84,144 B。

- 流水线 `face/make_chaos_face.py`，**100 项判据全绿**（含"容器内三份文件逐字节 == 源"；
  12 项 ko 符号级判据：搜 `.strtab` 证明**本轮新增的 `dq_timer_cb` / `DQ_SEQ` / `DQ_FIRED`
  真编进了这枚包**，同时证明 14 页应用那半也在；11 项**改 `/data/rc`**那组判据；
  **32 项 flash rcS hook** 判据 + 2 项原块判据 + 5 项"删除表里没有主功能路径"）。
- **★ v2 的关键新增**：v1 缺的第 ① 件（**flash 里 rcS 末行的开机 hook**）已**移植进本包**
  —— 移植源 `shellpp2-autostart/.../_Lua/main.lua`，几何 / 门 / 读写块 / 写回**原样搬**，
  32 KB 原块 65,536 个 hex 字符与上游**逐字符比对过**。界面上是 `装自启文件` /
  `移除文件` 两个**两段式**按钮（第一次按只探测，第二次才动 flash）。
- `chaos_sup.ko` 是本机新编的（补装了 nightly + `rust-src` + `thumbv8m.main-none-eabi`）：
  85,896 B，未定义符号 0，`.text` 28,344 B（**非 0** —— `merge_sections.ld` 少写会让它变 0
  而加载器照样"装成功"）。
- 离线门 `_sim_autostart.py` 也扩了：假 shell 里**真实现 `dd`**（`if/of/bs/skip/seek/count/
  conv=notrunc`）+ 内存 flash 镜像，判据从 24 项加到 **61 项**，其中 flash 那 12 项覆盖
  两段式（第一段零写盘）/ 写后回读 == 载荷 / 只动目标块 / 相邻块 adler 不变 /
  三段任一不符零写盘 / 固件门停用 / 还原回原块 / 移除只删自启动文件（主功能 4 个文件仍在）。
- 详细理由、5 条新量出来的格式事实（`compile.exe` 收 `app/**` 全部文件 / 终止记录判据 /
  缩略图对齐填充 / 包名不可控 / 中文小字要中文字体）、设备侧步骤与 G1' 判据表 → **`FACE.md`**。
