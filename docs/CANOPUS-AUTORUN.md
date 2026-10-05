# Canopus-Module 自启动适配分析（10Pro / p67tc / 3.101.043）

- 日期：2026-10-05
- 问题：Canopus 能不能像 Chaos / shellpp2 那样接入 `10pro.autorun` 自启动？
  **能不能只改安装器 Lua、不动模块源码？**
- 结论先行：**只改 Lua 做不到"真自启动"，只能做到"开机静默 insmod"（无实际收益）。
  最小可行方案 = 模块 C 侧加一段 DQ（约 60–80 行，地址全部有同机同固件真机证据）
  + 安装器 Lua 加自启动段（投 `/data/rc.d/canopus.sh`）。**

---

## 1 两个参照是怎么适配的

| 项 | Chaos（`AUTOSTART.md`/`PATCH.md`） | shellpp2-autorun v2（`modules/`） |
|---|---|---|
| 模块侧 | supervisor `ipc.rs` 加 **DQ**（`CMD_BOOT_DQ` + `lv_timer`）：rc 的 `dd` 只"入环即返回"，真正的注册链由 **UI 线程定时器**按 1s 一拍派发 | 模块 bin 出厂就带 DQ（6 条帧全是 DQ 或空操作） |
| Lua 侧 | 安装器投 `/data/rc.d/chaos.sh` —— **9 行纯命令**（`set +e`/`insmod`/`dd`/`echo`），无 `if`、无 `sleep`、无闸、不碰 flash | 同构：`/data/rc.d/shellpp2.sh`，6 条 16B 帧逐条 `dd` |
| 闸/延时/防砖 | 全部归管理器生成的 `/data/rc`（`sleep 8` + 模块行 + `sleep 15` + 扣/放闸） | 同一套 |

共同前提（本项目两条真机定案，`AUTOSTART-GUIDE.md` §2.1）：

1. **sh/nsh 任务里同步调固件注册链（APP_INSTALL/notify 等）⇒ write 不返回 ⇒ 看门狗硬重启**；
2. 同一调用改到 **UI 任务的 lv_timer 回调**里 ⇒ 正常返回；且 `lv_timer_create` **从 sh 语境调是安全的**。

⇒ 任何模块要自启动，判据只有一个：**它的 write 路径是同步干活还是"入环即返回"**。

---

## 2 Canopus 现状（读码结论，全部有行号）

### 2.1 与前两者的关键差别：write 是**全同步**的，且没有 DQ

`/dev/canopus` 的 write 链（`manager/`）：

```
sup_control_write                                   (canopus_supervisor_platform.c:144)
  └─ canopus_supervisor_device_write                (canopus_supervisor.c:870)
       └─ canopus_supervisor_handle_command         (canopus_supervisor.c:451)
            └─ sup_dispatch                         (canopus_supervisor.c:213)  ← 当场跑完
                 ├─ INSTALL 0/1/2 → stage_package(token=0, stage)
                 │     ├─ stage 0 = canopus_manager_native_install()   (platform.c:990)
                 │     │     └─ APP_INSTALL / launcher_add / notification  ← 固件注册链
                 │     └─ stage 1/2 = publish_native_apps → 模块回调再注册
                 ├─ RESTORE_AFTER_BOOT → activate_restored_modules
                 │     └─ load_module → stock insmod 子模块 → 子模块构造器注册应用
                 └─ （ENABLE/DISABLE 等只记 boot intent + 存 registry，文件 I/O，安全）
```

- 安装器 Lua 之所以现在能跑，是因为它跑在 **lvgl.Timer 回调（UI 任务）**里，且
  `execute_step` 是"写一帧 → 当场回读 status 判 `RESULT_COMPLETED`"（`main.lua:203-213`）
  —— 这本身就证明命令在 write 里**同步执行完毕**。
- 全 `manager/` 目录 **grep 不到任何 timer**：supervisor 没有延迟派发机制。
  `struct pending` 只是 v2 传输的请求跟踪表，不是执行队列。

⇒ **rc 里对 `/dev/canopus` 的任何一条 CPC1 安装类命令，都会踩中定案 1（挂死）。**

### 2.2 已有的"半成品"设计

| 事实 | 位置 | 对自启动的意义 |
|---|---|---|
| 构造器只做 identity guard + `register_device`（注册 `/dev/canopus`），**不加载任何子模块** | `canopus_supervisor_module.c:68-112` | 开机 `insmod` 本体是**安全的**（register_driver 从 sh 语境已被本机验证） |
| `canopus_supervisor_restore_after_boot()` 有防重入闸（`g_module_activation_started`） | `canopus_supervisor_module.c:55` | Canopus 自己的方案就是"**等 Manager 页面第一次 on_create（UI 任务）再恢复模块**"（target 后端 `:1225`） |
| registry（槽表 + intent）落盘 `/data/canopus/`，开机构造器只回读元数据 | `canopus_supervisor_module.c:109` | 状态不丢，缺的只是"谁来在 UI 任务里推一把" |

⇒ Canopus 的现状 = **"有人打开 Manager 就全恢复，没人打开就一直躺着"**。自启动要补的就是这一个"推手"。

### 2.3 10Pro 目标包的定时器原语（关键可用性）

`targets/xiaomi-band-10-pro-3.101.043/generated/canopus_veneer.h`：

| 原语 | 状态 |
|---|---|
| `lv_timer_create` | **已导出**：`0xc587ed1`（veneer.h:238）—— 与 Chaos DQ 真机验证用的是**同一地址** |
| `lv_timer_del` | restricted 未导出 |
| `timer_set_period` | veneer 未导出，但 Chaos 项目在同机同固件（p67tc 3.101.043 = 10Pro）实测 `0x0C16D545` 可用（`AUTOSTART-GUIDE.md` §8） |

⇒ DQ 移植的原料齐了，且不是"猜地址"——两个地址都在这台机器上跑通过。

---

## 3 能不能只改 Lua？——逐条否掉

| Lua-only 路线 | 结果 |
|---|---|
| rc.d 脚本里 `dd` 发 INSTALL/RESTORE 帧 | ❌ write 同步执行注册链 → sh 任务挂死 → 看门狗重启（定案 1） |
| rc.d 脚本里只 `insmod` + 回读日志 | ✅ 能跑、安全，但 **Manager 不会注册、桌面无图标、模块不加载** —— 与"不装自启动"无可见差别（Run 本来就会 insmod），自启动收益 ≈ 0 |
| 让 `/data/rc` 直接跑安装器 Lua | ❌ 没有任何"开机拉起表盘"的机制（quickapp/表盘注册表无 autostart 字段，`ANALYSIS.md` §2.2） |
| 借 shellpp_ii 的 DQ 代跑 Canopus 的活 | ❌ shellpp_ii 的 DQ_SEQ 是写死自家命令的，没有通用转发能力 |
| 用 `/dev/canopus-installer` 端点（v2 INSTALL 带 token） | ❌ 该端点只做**落盘暂存**（纯文件 I/O，sh 安全），明文拒绝无 payload 的框架 INSTALL（`canopus_supervisor.c:927-945`），注册链一样进不去 |

**结论：注册链必须有人搬到 UI 任务里跑，而 Canopus supervisor 里没有任何现成的搬运工。
不动模块源码 = 没有搬运工 = 没有真自启动。**

---

## 4 最小改动方案（要改什么）

### 4.1 模块 C 侧（唯一绕不开的改动，~60–80 行）

在 supervisor 加 Chaos 同款 DQ，**新增一支命令、不改任何现有路径**：

1. 新命令号 `CANOPUS_SUP_CMD_BOOT_DQ`（帧内 cmd 字段，建议魔数族取 `"3PC1"` = `0x31435033`，
   与 `"CPS1"`/`"CPC1"` 同命名法）；在 `canopus_supervisor_device_write` 的 CPC1 分支里
   把它从 `handle_command` 分流出去。
2. `dq_start()`（write 上下文，**禁止碰固件框架**）：`canopus_fw_lv_timer_create(cb, 1000, 0)`
   建一台 UI 线程定时器 + 打游标；一次性闸 + 建不满 8 次报错，不假装成功。
3. `dq_timer_cb`（UI 任务）按 1s 一拍跑安装器同款序列，一拍一条：

   ```
   INSTALL 0 → INSTALL 2 → RESTORE_AFTER_BOOT → INSTALL 1 → INSTALL 2
   （= watchfaces/canopus-installer-prod/xiaomi-band-10-pro/main.lua 的 steps 表）
   ```

   每拍直接调 `sup_dispatch`（或 `handle_command`）+ `canopus_snapshot_begin/commit`，
   与 write 路径共用同一份实现（**不抄第二份**）；RESTORE 的失败按非致命处理
   （与安装器 `critical=false` 同语义：Manager 已注册，模块坏了进 Manager 修）。
4. 跑完降频：`timer_set_period(t, 60000)`（地址 `0x0C16D545`，需在 veneer/target_config
   里按 Chaos 的先例补一条常量；**离线门必须记"未验点：该地址在本模块内首次调用"**）。
5. 并发护栏：DQ 跑的几拍里，Manager 页面任务可能同时对 `/dev/canopus` 发 v2 命令
   （Canopus 的 Manager 是常驻 in-process 客户端，与 Chaos 的纯被动设备不同）。
   需要一把 `DQ_BUSY`（或复用 snapshot 协议的互斥语义）让重叠写安静返回 —— Chaos 的
   `WRITE_BUSY` 同款问题。

构建/验证沿用现成管线：`scripts/build_canopus_supervisor.sh`（CANOPUS_TARGET=
xiaomi-band-10-pro-3.101.043）+ verifier；G1' 门 = 手动 `dd` 一帧 DQ 后回读 384B 状态，
判 `pending_op/pending_state` 走到 `RESTORE_AFTER_BOOT/COMPLETED`。

### 4.2 安装器 Lua 侧（`watchfaces/canopus-installer-prod/xiaomi-band-10-pro/main.lua`）

照 Chaos v3 / shellpp2 v2 的模板加一段，**全部符合 REGISTER.md 新标准**：

| 改动 | 内容 |
|---|---|
| **暂存模块** | Run 成功后把 `canopus_supervisor-<target>.bin` 从 SCRIPT_PATH 复制到 **`/data/canopus/canopus_supervisor.bin`（固定名）** 并回读核对 —— rc 在开机时拿不到表盘容器里的版本化文件名（现安装器只暂存了 manager_icon.bin，`main.lua:113-143`） |
| `rc_dir_ready()` | 试写 `/data/rc.d/.probe` 判管理器在不在；失败再试 `/data/.probe` 区分原因；**不建目录、零写盘退出** |
| `build_canopus_sh()` | 生成 `/data/rc.d/canopus.sh`，**9 行纯命令**（无 if/sleep/闸/flash）：`set +e` → `echo start > /data/canopus/autostart.log` → `insmod /data/canopus/canopus_supervisor.bin canopus_supervisor` → `echo insmod >>` → `dd` 16B DQ 帧 → `echo boot_cmd_sent >>` → 状态回读 384B → `echo done >>` |
| `build_boot_frame()` | `word(CPC1) .. word(BOOT_DQ) .. word(0) .. word(0)` 写 `/data/canopus/boot.bin` + 回读逐字节核对 |
| `autostart_remove()` | 只删自家三样（`canopus.sh`/`boot.bin`/旧闸残留）；不碰 `/data/rc`、不碰 `.autorun.on`；提示"去管理器按 [2 重建自启动]" |
| `legacy_cleanup()` | 逐行过滤摘掉旧版可能追加进 `/data/rc` 的 `sh /data/canopus/rc &` 行（若历史上发过过实验版） |
| UI | 在现有 `Run`/`Clear Env` 基础上加一个自启动入口（Run 的一次性锁不影响自启动段；两者独立） |

### 4.3 交付门（沿用项目惯例）

| 门 | 判据 |
|---|---|
| G1 ko 编译/verifier | build_canopus_supervisor.sh 四件套全绿、未定义符号 0 |
| G2 DQ 行为仿真 | 真 C 不可仿真则用状态机单测（`tests/host/test_supervisor_device.c` 已有底座） |
| G3 Lua 行为仿真 | 真 Lua + 假 lvgl/io：管理器没装零写盘、脚本是纯命令形态、幂等、不碰 `/data/rc` |
| G1' 真机手动 | insmod 后手打 `dd boot.bin` → 等 5s 回读 status：`pending_state=COMPLETED`、Manager 出现在桌面 |
| G2' 冷启 3/3 | `autostart.log` 末行 `done`；`.autorun.log` 末行 `cleared`；与 chaos/shellpp2 三包共存 |

---

## 5 风险与未验点

1. **`timer_set_period`（0x0C16D545）在 Canopus ko 内是首次调用** —— 地址本身在同机同固件
   被 Chaos 验证过，但"没人在这台设备的 Canopus 里调过它"（Chaos 文档 §7.3 同款保留意见）。
   失败表现：降频不生效，常驻 1s 空转 timer（续航红线 deviation，功能不受影响）。
2. **息屏期间 DQ 序列暂停**（UI 任务 lv_timer 的固有行为），rc 那半照跑 —— 与 Chaos 相同，可接受。
3. **DQ 与 Manager 页面任务的并发**：需要护栏（§4.1 第 5 点），否则桌面通知触发的
   Manager 刷新写可能与 DQ 拍子交叠。
4. `lv_timer_del` 未导出 ⇒ timer 只能降频不能删（与 Chaos 的"只降不删"同款约定）。
5. 首次安装仍需**人工一次**（Run 暂存 ko/icon + 装自启文件 + 管理器 `[2 重建自启动]`）。

---

## 8 落地记录（2026-10-05 实施）

已按上述方案落实并编译通过。变更清单：

### 8.1 C 侧（supervisor，043 专用 DQ）
- `manager/service/canopus_supervisor.h`：新增 `CANOPUS_SUP_CMD_BOOT_DQ`（"3PC1"）与
  `canopus_supervisor_boot_dq_start()` 声明。
- `manager/service/canopus_supervisor.c`：DQ 状态机（`canopus_supervisor_boot_dq_start`
  只在 write 上下文建 lv_timer；`canopus_sup_dq_timer_cb` 在 UI 线程按 1s 一拍跑
  INSTALL 0 → 2 → RESTORE → 1 → 2 五步序列；`g_dq_busy` 护栏在 Manager 并发写时丢弃）。
- `scripts/build_canopus_supervisor.sh`：仅 043 定义
  `CANOPUS_SUP_BOOT_DQ_TIMER_CREATE=0x0C587ED1`（10pro-043 veneer 自身导出）与
  `CANOPUS_SUP_BOOT_DQ_TIMER_SET_PERIOD=0x0C16D545`（Chaos 同机同固件真机验证）；
  036 不定义 → DQ 代码整个编译剔除，BOOT_DQ 帧走 UNKNOWN_OP 拒绝。
- `targets/xiaomi-band-10-pro-3.101.043/symbols/…ui.lv_timer_set_period.json` +
  `evidence/EVID-CHAOS-DQ-DEVICE-001.json`：verifier 白名单补充（同源证据，
  两项目分析的是同一枚 13,795,728 B 固件镜像，lv_timer_create 地址双方一致）。

### 8.2 签名验证移除（dev/universal policy）
- `manager/package/canopus_installer_bundle.c`：`canopus_install_receipt_validate`
  删除 `crypto_ed25519_check` 调用 —— 任何密钥签的 receipt 均接受；
  结构 / target / firmware 绑定校验保留。
- `manager/ui/canopus_manager.c`：`canopus_manager_can_activate` 移除
  `signature_ok` 门 —— 未签名模块同样可立即激活。
- `scripts/build_canopus_supervisor.sh`：monocypher 整库（monocypher.c +
  monocypher-ed25519.c + `-u crypto_ed25519_check`）从链接中剔除，仅保留
  EABI 内存助手；最终 ELF 中 ed25519/eddsa/monocypher 符号 0 残留。
- 测试同步：`test_installer_receipt.c`（翻转签名/artifact_sha256 现在应通过）、
  `test_manager_native.c`（signature_ok=0 仍可激活）。
- 注：`scripts/build_p65_supervisor.sh`（p65 目标）未动，其签名验证仍在。

### 8.3 Lua 侧（`watchfaces/canopus-installer-prod/xiaomi-band-10-pro/main.lua`）
- 常量：`STAGED_MODULE_PATH=/data/canopus/canopus_supervisor.bin`、
  `CMD_BOOT_DQ="3PC1"` 等。
- 新函数：`write_file` / `rc_dir_ready`（试写探测）/ `stage_module_to_data`
  （ko 暂存到 /data 固定名 + 回读核对）/ `build_boot_frame`（16B DQ 帧）/
  `build_canopus_sh`（9 行纯命令脚本）/ `legacy_cleanup` / `autostart_install` /
  `autostart_remove`。
- UI：两键扩为四键 Run / Autostart Install / Autostart Remove / Clear Env。

### 8.4 构建与验证结果
| 检查项 | 结果 |
|---|---|
| 043 verifier | PASS（19 sections, 0 undefined, 947 relocs） |
| 036 verifier | PASS（19 sections, 0 undefined, 916 relocs） |
| 043 ELF 含 DQ | `canopus_supervisor_boot_dq_start`/`dq_timer_cb`/`dq_seq` 全在 |
| 043 定时器地址 | movw/movt 编码 0x0C587ED1 + 0x0C16D545 均在 DQ 代码区 |
| 036 ELF 含 DQ | 无（正确剔除） |
| 最终 ELF 签名符号 | ed25519/eddsa/monocypher 0 残留、0 调用点 |
| host 测试 | 全绿（all host tests passed） |
| Lua 语法门 | loadfile OK（lua 5.5.1） |
| bin 尺寸 | 043 72812→53824 B、036 71848→52872 B（余量 ~19.9KB） |

产物：`watchfaces/canopus-installer-prod/xiaomi-band-10-pro/`
（main.lua + 两个 supervisor bin + manager_icon.bin）。
