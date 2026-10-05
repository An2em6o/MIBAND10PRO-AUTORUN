# 结论（冻结）—— p3 崩点定案 + 规避

- 日期：2026-10-04
- 对象：p67tc（小米手环 10 Pro）/ 固件 3.101.043
- 相关：`shellpp2-autostart`（Shell++ II 自启动）、`probcard.face`（p3 探针卡）
- 上游分析：`chaos-autostart/ANALYSIS.md` §1–§10

---

## 一、问题

`/data/rc`（开机脚本，`sh` 任务）跑到**第 3 条命令**就 `rtc_watchdog(1)` 硬重启，日志永远停在 `p3`。
探针卡上用同一个 callee 复现：`P3 钩子 n=0`（同步 `HOOK_N`）崩 2/2。

---

## 二、定案：崩点 = **调用语境**，不是代码内容，也不是栈

### 2.1 单变量对照（真机，同一 callee / 同一 desc / 同一 g_pages）

| 命令 | 号 | 执行语境 | 真机结果 |
|---|---|---|---|
| `APP_INSTALL(desc, pages, 0)` | `0x5351001e` | `dd` → sh 任务，**同步** | **崩 2/2** |
| `APP_INSTALL(desc, pages, 0)` | `0x53510020` | `dd` → 入环 → **lv_timer 回调（UI 任务）** | **`state=5`，返回 0** |
| `EVENTBUS_SEND(class=0x1C)` | `0x5351001d` | `dd` → sh 任务，**同步** | **崩 2/2** |
| `EVENTBUS_SEND(class=0x1C)` | `0x5351001f` | UI 任务（`state=5` 蕴含，`APP_INSTALL` 成功路径必经该投递） | 不崩 |

> 唯一变量就是**谁在跑**。

### 2.2 三条独立判据

1. **栈被排除**：`app_install` 关键路径固定帧下界 **1612 B**、单帧最大 **272 B**；
   而 `sh`(8192) 与 `lua`(32768) **一起崩** —— 栈不足解释不了 32 K 档位的失败
   （20 倍余量，差两个数量级）。
2. **"框架自身需要 UI 语境"被排除**：从 `0x0CA6A30C` 做的 192 个可达函数里
   **没有 LVGL / Lua / UI 状态**，只有链表 / `strdup` / `malloc` / djb2 hashmap / 名字表。
3. **失败形态是"阻塞等待"而非崩溃**（`write()` 不返回）⇒ 指向"等一个只有特定任务才会给的信号"。

⇒ 若"必须 UI 语境"成立，它**只能来自两个运行期间接调用**，且都在**框架尾部**：

* `*(g_appmgr+0x0c)` 逐页钩子（`0x0CA6A3F8 ldr.w r3,[sl,#0xc]` + `blx r3`；n=0 时整段跳过）；
* 结尾 `lvx_eventbus_send_with_cb(0x1C, name, 0)`（`0x0CA6A44A`，**n=0 也走到**）。

---

## 三、规避（定案做法）

**同步号 + 0x10 = DQ 号** ⇒ `dd` 只"入环即返回"，真正的框架调用由 UI 任务的 `lv_timer` 按 50 ms/条派发。

| 命令 | 同步号（必崩） | DQ 号（安全） |
|---|---|---|
| `HOOK_N`（页数） | `0x5351001e` | `0x53510020` |
| `EVBUS_PING` | `0x5351001d` | `0x5351001f` |
| `INSTALL` | `0x53510002` | `0x53510012` |
| `UNINSTALL` | `0x53510003` | `0x53510013` |
| `NOTIFY_LOADED` | `0x53510004` | `0x53510014` |
| `SETTINGS_START` | `0x5351000b` | `0x5351001b` |
| `PEEK_APPMGR` | `0x5351001c` | 无（**本来就纯读，不崩**） |

**这不是新发明**：在产 `Shellpp-II-install-Lua-v2/_Lua/main.lua` 的 `build_cmds()` 里
install/settings/notify 用的**全是 DQ 号**，安装器日志字符串直接写着「**DQ 号**」。
且 `build_rc()` 生成的 `/data/rc` 消费方式同样是 `dd ... bs=16 count=1 conv=notrunc`
⇒「我们的卡用 `dd`、生产不用」这个混杂因子**已被排除**。

### 两条支撑（把"能不能行"也钉住）

1. `lv_timer_create` **从 `dd` 语境调是安全的** —— `dq_ensure_timer()` 就在 `dq_enqueue()` 里被
   `control_write()` 调用；真机 `C <ptr>` 标记非 0，两条 DQ 命令都正常返回。
2. 回调**确实落在能把 `APP_INSTALL` 跑通的语境**（`state=5`，即 `dq_timer_cb` 派发后 `rc==0`）。

---

## 四、仍然未知（**决定不追**）

`*(0x200EB690)` 的身份（逐页钩子）：全镜像 **0 写入者**、镜像里 **没有 `.data` 初始化块**，
所以它的定值发生在 `vela_ap.bin` 之外。

**判断：它挡住的是"解释"，不是"解决"。** DQ 已经能绕过，继续挖的边际收益为零。

> 留一句话：`S <sp>` 标记已经在 `/data/shellpp-ii-supervisor.log` 里**永久留档**
> （每写一次记一行写命令时的栈指针）——将来若想回头验栈，不必再加探针。

---

## 五、判读陷阱（已入库，别重犯）

1. `dd 返回 ok` 对 DQ **不构成成功判据**（只是入队）⇒ 必须回读状态看 `state` 8→5/15。
2. 手动 `P8 回读` **不打日志**；要按首页 `回读状态`。
3. `log_seq` 从 `025` 倒退 = **重启指纹**（`log_restore()` 行为）。
4. `APP_INSTALL` 去重命中会**短路**（`[node+0x10]==desc+0x10` 直接返回）⇒ 注册表会被污染，
   `P3`/`P5`/`P6` 之后的探针都退化；重启清空。
5. `INSTALL_DQ` 的 `stage==0` 是**空操作**（`dq_dispatch` 直接 `return 0`）
   ⇒ 拿 stage 0 测 DQ 通道会**假绿**，要测通道用 `HOOK_N_DQ` / `EVBUS_PING_DQ`。
6. `HO_RING=8` 只能放 **7 条**，第 8 条被 `'B'` 掉（`-16`）。

---

## 六、工程状态

| 项 | 状态 |
|---|---|
| `CARD-MANUAL GATE` | **PASS** |
| `sim_card.py`（行为仿真门） | **57 项全绿**（`lupa` 缺失改为硬失败，不再静默跳过） |
| `verify_install_loop.py` | **PASS**（从固件重新证出：页数 guard → 跳过逐页钩子 → 仍投递 eventbus） |
| 交付物 `probcard.face` | **256020 B / md5 `83b876e66caae15f46d299099c3bc5c0`**（全程未变） |

**待办**：卡 v2 —— 自动矩阵 `P1 → P3(n=0) → P4(n=11)` 三步**全是同步号**（这就是它会崩的原因），
改成 `P1 → P7 DQ evbus → P5 DQ n=0 → P6 DQ n=11` 即整条自动链不崩。只改 Lua 命令号，模块 md5 不变。
