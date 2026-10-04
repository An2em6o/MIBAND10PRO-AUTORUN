# shellpp2-autorun —— 原版 Shell++ II 安装器 · 自启动页适配（新注册规范）

拿**原版干净安装器**（`reference/upstream-clean`，544 行 `main.lua`）**原样**作基座，
**只新增一张「自启动」页**（UI 版式抄我们改过的 `Shellpp-II-install-Lua-v2`）。
这张页按 `REGISTER.md`（管理器 10pro.autorun 的模块注册契约）落地：

> **只往 `/data/rc.d/shellpp2.sh` 投脚本** —— 和 chaos 在管理器下一样；
> **永不碰 `/data/rc`**（它是管理器的产物）；**不碰 flash**。

> ## ★ v2（2026-10-04 职责边界）—— 脚本从"带闸带延时"降级为**纯命令**
>
> 用户定的规矩：「各个模块只需要写自己的脚本放到 `rc.d` 就行，**不建议把安全延时等这些
> 重要功能加在模块本身的脚本里**，管理器和模块要分开。」
>
> ⇒ `shellpp2.sh` 里**没有 `if`、没有 `sleep`、不碰 `autostart.on`**；
> **闸（扣/放）、两个安全窗、心跳日志全部归管理器生成的 `/data/rc`**。
> v1 那套"模块自带闸 + 5 s / 10 s 延时"**已废弃**（闸写进每个模块 = N 份互相打架的副本，
> 且"被打断"只在模块自己的小圈子里留痕、管理器看不见）。**v1 包请作废，用 v2。**

基座那 544 行的**逻辑与文案一字未改** —— 只把它那 6 个控件从 `root` 改挂到 `main_page`，
并新增一张挂在 `as_page` 上的自启动页。diff 口径：**+422 / −26**（净 +396 行 → 940 行），
26 行删除全部是「挂载点 `root`→`main_page`」与「按钮几何重排」，**没有任何功能被删**。

---

## 0. 与另两个包的关系

| 包 | 基座 | 自启动怎么落地 | `/data/rc` 谁写 | flash |
|---|---|---|---|---|
| **原版** `reference/upstream-clean` | — | **没有自启动**（只有安装/卸载） | 不写 | 不碰 |
| **v7** `Shellpp-II-install-Lua-v2` + `Shellpp-II-Autostart-Lua`（旧规范） | 原版 + 独立自启动表盘 | 独立资源文件 `rc` **整体覆盖**写到 `/data/rc` | **模块自己** | **模块自己 dd 写 AP rcS hook**（`sh /data/rc &`） |
| **v1** `shellpp2-autorun`（新规范首版，**已作废**） | 原版 + **一张自启动页** | `shellpp2.sh` 里**自带闸 + 5s/10s 延时** | **管理器** | **管理器**的 `[1 安装]` |
| **本包 v2** `shellpp2-autorun`（新规范） | 原版 + **一张自启动页** | `/data/rc.d/shellpp2.sh`（**纯命令，零机制**） | **管理器**（读 `rc.d` 生成） | **管理器**的 `[1 安装]` |

**本包的脚本与 v7 的 `_Lua/rc` 是同一份命令序列**，区别在两处：① 它落在
`/data/rc.d/shellpp2.sh`（一片），而 `/data/rc` 变成管理器生成的薄壳；② v2 起**闸与两个
`sleep` 都搬走了**（归 `/data/rc`），脚本只剩"要跑的命令"。这两条合起来就是新旧规范的分界。

---

## 1. 落到设备上的东西

### 1.1 自启动页 `[1 安装]` 写什么

| 落点 | 内容 | 谁读它 |
|---|---|---|
| `/data/rc.d/shellpp2.sh` | **开机命令序列**（见 §1.3） | 管理器 → 生成 `/data/rc` → flash 里那句 `sh /data/rc &` |
| `/data/shellpp-ii/shellpp_ii.bin` | 目标固件版本的内核模块（**固定名**，脚本 `insmod` 的就是它） | 开机脚本 |
| `/data/shellpp-ii/cmds.bin` | 6 条 16 B 命令帧（96 B） | 开机脚本逐条 `dd` 进 `/dev/shellpp` |
| `/data/shellpp-ii/*_icon.bin` | 两个桌面图标 | 主视图 |

**不写**：`/data/rc`（管理器的）、flash 里任何字节、`/data/shellpp-ii/autostart.on`
（那是 v1 的模块闸 —— v2 **不但不建它，`[1 安装]`/`[2 删除]` 还会主动 `rm -f` 掉旧的**）。

### 1.2 前置：管理器没装就零写盘

`[1 安装]` 第一件事是 `rc_dir_ready()` —— **试写** `/data/rc.d/.probe`：

- 成功 ⇒ 删探针，继续；
- 失败 ⇒ 再试写 `/data/.probe` 来**区分**「管理器没装」与「/data 只读」，
  然后**直接返回，一个字节都不写**，横幅出短原因。

> 判「装没装」= 试写、不是 `exists(目录)`：NuttX 上 `open()` 开目录返回 `-6 ENXIO`，
> `io.open` 给 `nil` —— 目录明明在也会被判成不在（管理器自己踩过同一个坑）。
> 而 `write_file` **不建父目录**，所以「写不进去」恰好就是「目录不在」。
> **不自己 `mkdir /data/rc.d`**：那等于宣布「我是管理器」，装完开机却什么都不发生（静默失败）。

### 1.3 生成的 `/data/rc.d/shellpp2.sh`（全文，v2 = 纯命令）

```
set +e
echo start > /data/shellpp-ii/autostart.log
insmod /data/shellpp-ii/shellpp_ii.bin shellpp_ii
echo insmod >> /data/shellpp-ii/autostart.log
echo m1 >> /data/shellpp-ii/autostart.log
dd if=/dev/shellpp of=/data/shellpp-ii/status1.bin bs=384 count=1 conv=notrunc
echo m2 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=0 count=1 conv=notrunc
echo c0 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=1 count=1 conv=notrunc
echo c1 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=2 count=1 conv=notrunc
echo c2 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=3 count=1 conv=notrunc
echo c3 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=4 count=1 conv=notrunc
echo c4 >> /data/shellpp-ii/autostart.log
dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 skip=5 count=1 conv=notrunc
echo c5 >> /data/shellpp-ii/autostart.log
echo m3 >> /data/shellpp-ii/autostart.log
dd if=/dev/shellpp of=/data/shellpp-ii/status2.bin bs=384 count=1 conv=notrunc
echo m4 >> /data/shellpp-ii/autostart.log
dd if=/dev/shellpp of=/data/shellpp-ii/status3.bin bs=384 count=1 conv=notrunc
echo m5 >> /data/shellpp-ii/autostart.log
ls /data/shellpp-ii >> /data/shellpp-ii/autostart.log
echo done >> /data/shellpp-ii/autostart.log
```

**★ 它里面没有什么（v2 的关键）**：**没有 `if` / `fi`、没有 `sleep`、不碰 `autostart.on`**。
那三样都搬到了**管理器生成的 `/data/rc`** 里（形状由管理器负责，这里只示意）：

```sh
set +e
echo gate_off >> /data/rc.d/.autorun.log    # 心跳，在 if 外面：闸关着也留痕
if [ -f /data/rc.d/.autorun.on ];then
rm -f /data/rc.d/.autorun.on                # 先扣闸（防砖凭证）
sleep 8                                     # 窗口 1
sh /data/rc.d/shellpp2.sh                   # ← 就是上面那份脚本
sleep 1                                     # 多模块之间固定间隔 1 秒
sh /data/rc.d/<别的模块>.sh
sleep 15                                    # 窗口 2
echo cleared >> /data/rc.d/.autorun.log
echo on > /data/rc.d/.autorun.on            # 跑到底才放行
fi
```

**防砖语义（现在整条链共用一套）**：约 23 秒窗口（`sleep 8` + 模块 + `sleep 15`）内任何一次
重启 / 掉电 / 看门狗 ⇒ 闸停在【关】⇒ 下次开机**一条模块命令都不跑、且不自动恢复**。
恢复只能**手动**：管理器自启动页 `[3 开启]`。判据只看管理器那两行（启动判定 + 心跳）。

**为什么这串能跑**（6 条帧全是 DQ 或空操作）：`install`/`settings`/`notify` 三条走
**DQ（延迟命令号）** —— 入环即返回，真正的框架调用由模块自己的 UI 线程定时器派发；
另外三条（`RESTORE_AFTER_BOOT` / `INSTALL stage 0`）在模块里**就是 `rc = 0` 空操作**。
所以从 sh 任务写 `/dev/shellpp` **不会**碰到「非 UI 任务直接调 `APP_INSTALL`」那个挂死点。

### 1.4 自启动页 `[2 删除]` 做什么 / 不做什么

- **做**：删 `/data/rc.d/shellpp2.sh` + `rm -f` 掉 v1/v2 残留的模块闸 `/data/shellpp-ii/autostart.on`
  + 摘旧版残留行（`/data/rc` 里那条 `sh /data/shellpp-ii/rc &` 与 `/data/shellpp-ii/rc`）。
- **不做**：**不碰 `/data/rc`** —— 那一行是管理器生成的，要等管理器按 `[2 重建自启动]` 才消失。
  所以提示文案必须把这一步写出来，否则用户会以为「删了但还在跑」。
- **不做**：不删 `/data/shellpp-ii/` 里的模块与图标 —— 那是 App 本体的运行依赖，
  归主视图的 `Uninstall` / `Clear Env` 管。

---

## 2. 与 chaos 参考实现的对照

| 项 | chaos（`chaos_installer.lua` v3） | 本包 | 说明 |
|---|---|---|---|
| 注册目录 | `/data/rc.d` | 同 | 新标准唯一入口 |
| 脚本名 | `chaos.sh` | `shellpp2.sh` | 只含 `[%w_%-]`、小写 `.sh` ✓ |
| 脚本骨架 | `set +e` → **纯命令**（无 `if` / 无 `sleep` / 无闸） | **同构** | v2 起两边同形 |
| 等待值 | **无**（窗口归 `/data/rc`：`sleep 8` + `sleep 15`） | **无**（同一套窗口） | v2 起两边一致 —— 都由管理器提供 |
| 命令帧 | 1 条（`boot.bin`，16 B） | **6 条**（`cmds.bin`，96 B，逐条 `dd ... skip=N`） | shellpp2 要 INSTALL ×2 + SETTINGS + NOTIFY |
| `insmod` | `/data/chaos/sup.ko chaos_sup` | `/data/shellpp-ii/shellpp_ii.bin shellpp_ii` | 与 v7 的 `rc` **逐字相同**，也与原版主视图第 456 行一致 |
| 状态回读 | 2 次（stage1 / stage3） | 3 次（status1/2/3，384 B） | 埋点更多，便于查在哪一步断的 |
| 痕迹文件 | `/data/chaos/autostart.log` | `/data/shellpp-ii/autostart.log` | 落点都在**自己的**目录 |
| 管理器没装 | 试写 `.probe` → 报「管理器没装」 | **同** | |

**串行、以及"谁在等"**：`/data/rc` 里模块行**没有 `&`** ⇒ 脚本在前台串行跑；但 v2 起它
**自己不再 `sleep`**，所以它只占"`insmod` + 6 条 `dd` + 3 次状态回读"那点时间。等待完全由
管理器的 `sleep 8` / `sleep 15` 提供（**不随模块数变**）。要调等待值就改管理器，**不再改本包**。

---

## 3. 构建与打包

```bash
# ① 改完 _Lua/main.lua 之后，重建 resource.bin + hashCode（设备真正读的是 resource.bin 里那份）
python <Shellpp-ii-build>/repack_resource.py --project <本目录>

# ② 打成 .mwz（含 14 条自检）
python tools/pack_mwz.py
```

`_Lua/` 是构建源、`resources/_lua/_Lua/` 是真源，两份必须**逐字节一致**（`pack_mwz.py` 会核）。
改了 `main.lua` 忘了跑 ① ⇒ ②会在「resource.bin 内嵌 main.lua == 工程 main.lua」这条直接 FAIL。

---

## 4. 产物

| 项 | 值 |
|---|---|
| 文件 | `out/shellpp2-autorun-v2.mwz`（= 桌面同名文件） |
| 大小 | **199,055 B** |
| md5 | `6bb5ce3c708632f15736a2432b5de54d` |
| sha256 | `fd20f55a5b12077024bc57fe6fb378563a460e95fb2712ec640b241124e01dba` |
| `resource.bin` | 229,554 B（上游原版 203,740 B） |
| 模块 `043` | 70,068 B，md5 `b733ddd926edab5dc8f76c3de5111a6e`（**DQ 版**，与 v1 同一份；上游原版是 65,200 B / `cab98992…`） |
| `main.lua` | 40,789 B / 940 行，md5 `2aa31d30ad59367dc9788dcf6f5017fc` |

**可复现**：重跑 `pack_mwz.py` 两次 md5 相同（条目时间戳钉死在 `1980-01-01`）。

---

## 5. 门与核对（本轮全部绿）

| 门 | 结果 | 咬住什么 |
|---|---|---|
| 离线门 `tools/_run_sim.py` → `_sim_autorun.lua` | **PASS (63/63)** | 真 Lua + 假 lvgl/假 io（**写文件要求父目录存在**）+ 假 nsh：载入/键位、切页、**管理器没装零写盘**、安装逐字节、幂等、不写 `/data/rc`、**不碰 flash**、旧雷清理、删除、**开机脚本形态（★ 纯命令：无 `if`/`fi`、无 `sleep`、不碰 `autostart.on`）**、**安装/删除都会清掉 v1 残留的模块闸**、反向静态（**剥注释后判**） |
| 打包自检 `tools/pack_mwz.py` | **PASS (14)** | ZIP 完好 / 条目顺序 / manifest 引用逐字节 / `_Lua`≡`resources` / hashCode 三段自洽 / **包内 main.lua == 工程 main.lua** / **resource.bin 内嵌 main.lua == 工程 main.lua** / 无独立 `rc` |
| 与原版 diff | **+422 / −26** | 26 行删除全是挂载点与几何，**无功能削减**；`insmod` 参数、6 键行为、文案一字未改 |

> ★ 反向静态判据（「代码里没有 `rcS`」「没有 `do_flash_restore`」…）一律判**剥掉注释后**的正文 ——
> 头部那些解释「为什么不再写 flash」的注释是有用说明，拿整篇源文本去咬只会逼人删说明。

---

## 6. 真机验收（操作单）

**前置**：设备上已装 `10pro.autorun` 管理器，且点过它的 `[1 安装]`（这样 `/data/rc.d` 才存在）。

| # | 动作 | 期望 |
|---|---|---|
| 1 | 装 `shellpp2-autorun-v2.mwz` | 表盘列表出现 `shellpp-ii-installer` |
| 2 | 打开它 → 主页能看见 7 个键，最下面一个是 **`自启动`** | 7 键全宽、不重叠 |
| 3 | 点 `自启动` | 切到自启动页：`< Back` + 标题 + **状态框（4 行）** + 横幅 + **2 个按钮**（`1 安装` / `2 删除`） |
| 4 | 看状态框 4 行 | `管理器 / 脚本 / 模块   开关→管理器 / 命令帧`；**装之前不能出现「已投」** |
| 5 | 点 `1 安装` | 横幅变「已投 `rc.d/shellpp2.sh` → 管理器按 `[1]`」，状态框立刻刷新齐全 |
| 6 | 打开管理器 → `[2 重建自启动]` | `[4 日志]` 状态行的 `生成 N` 比之前大 |
| 7 | 重启设备 | — |
| 8 | 起来后看**两处**痕迹（见下） | 本模块 `autostart.log` 末行 `done`；管理器自启动页回「已启动 + 跑到底」 |

设备侧核对命令（可直接粘）：

```sh
# 装完之后
ls /data/rc.d
cat /data/rc.d/shellpp2.sh          # 应是**纯命令**：没有 if / sleep / autostart.on

# 管理器按过 [2 重建自启动] 之后
cat /data/rc                         # 这里才有 if / rm -f 闸 / sleep 8 / sleep 15 / echo on >

# 重启之后 —— 两处日志各判一半
cat /data/shellpp-ii/autostart.log   # 本模块内部：末行 done = 跑到底
cat /data/rc.d/.autorun.log          # 整条链：末行 cleared = 跑到底；gate_off = 闸此刻【关】
ls /data/shellpp-ii                  # status1/2/3.bin 生成了没有
```

**两处日志的分工（别只看一个）**：

| 文件 | 谁写 | 末行含义 |
|---|---|---|
| `/data/shellpp-ii/autostart.log` | **本模块脚本** | `done` = 本模块跑到底；停在 `start` / `insmod` / `m1`…`m5` ⇒ 卡在哪一步一目了然 |
| `/data/rc.d/.autorun.log` | **管理器生成的 `/data/rc`** | `cleared` = 整条链跑到底；末行 `gate_off` = 闸此刻是【关】（上次被打断过） |

`status1/2/3.bin` 是三个检查点的 384 B 状态回读，用来判模块到哪一步了。

---

## 7. 只能真机看的判据（假 lvgl 不建模几何）

`_sim_autorun.lua` 的假 lvgl **只记对象与文本**，不建模尺寸/位置/显隐。所以下面这些**必须真机**：

- 状态框（`h=170`）的**框高与该铺到框底的行数**；
- 自启动页双列按钮（152×48 / 圆角 16 / 字号 16）的**实际观感**；
- 主页 7 键的间距、是否与状态栏/日志条重叠；
- 主页 ⇄ 自启动页切换时的**显隐**（`PAGE_HIDE = 2000` 离屏切页）；
- 两张页面的日志小窗**各自铺到框底**（行数按各自框高算，不是一个常数）。

---

## 8. 已知取舍

1. **不再占前台等待**：脚本在 `/data/rc` 里是**前台串行**的（没有 `&`），但 v2 起它**自己不再
   `sleep`** ⇒ 只占"`insmod` + 6 条 `dd` + 3 次回读"那点时间。等待由管理器的 `sleep 8` /
   `sleep 15` 统一提供（**不随模块数变**）；要调就改管理器，不再改本包。
2. **包身份与 v7 相同**：`_id` = `0a209037e2acc0845fdc9966640fffdc`、`pkgName` = `000000000000`、
   显示名 = `shellpp-ii-installer`，**与 v7 完全一致** ⇒ 装上会**顶掉 v7**，两者在设备上无法分辨。
   要区分就改 `description.xml` 的 `<name>` 与 `resources/manifest.xml` 的 `name`，
   然后重跑 `repack_resource.py`（名字进 manifest ⇒ hashCode 要刷新）+ `pack_mwz.py`；
   `pack_mwz.py --name 新名字` 把这两步连起来做。
3. **不清理 v7 残留**：`legacy_cleanup()` 只摘**完全等于** `sh /data/shellpp-ii/rc &` 的那一行
   （v5 之前旧版的追加行）。v7 是**整体覆盖**写 `/data/rc`，判据不匹配 ⇒ 不碰它。
   若设备上还留着那一坨，会开机跑两遍：先 `rm -f /data/rc`，再让管理器按 `[2 重建自启动]`。
4. **`[2 删除]` 之后 `/data/rc` 里那一行还在**（它是管理器生成的），必须再按一次
   管理器 `[2 重建自启动]` 才消失 —— 提示文案里已写。
5. ★★ **必须与 v0.6.6 及以后的「10pro.autorun」管理器"一起上机"**：v2 的脚本**交出了自己的闸**
   ⇒ 若设备上还是**旧管理器**（`/data/rc` 里没有扣闸 / 放闸那两句），**防砖能力为零** ——
   模块崩一次就是开机循环。⇒ **先管理器、后本包**（或两个一起）。
   反过来（新管理器 + 旧 v1 包）只是"模块自己多 sleep 15 秒"，不会砖。

---

## 附录：上游 README 原文（保留）

# Shell++ II Installer

本仓库保存 Xiaomi Band 10 Pro 的 Lua 安装器及其打包资源。多固件运行逻辑位于 `_Lua/main.lua`，目标 bin 由相邻构建器同步到 `_Lua` 和 `resources/_lua/_Lua`。

完整技术文档统一位于 [`../Shellpp-ii/docs/README.md`](../Shellpp-ii/docs/README.md)。安装器资源模型、版本选择和 Supervisor 协议见中央文档中的安装器协议与状态/控制 ABI。

构建器管理两个 Lua 资源目录中的 `shellpp_ii-*.bin`，并从 packaged 目录重建 `resource.bin` 和 `hashCode`。它要求两处 `main.lua` 与图标逐字节一致，但不改写这些共享资源，也不改写 manifest、`uidmap.map` 或编辑器配置。
