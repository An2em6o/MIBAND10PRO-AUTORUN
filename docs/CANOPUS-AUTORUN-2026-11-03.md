# Canopus / 10pro.autorun 启动修正（2026-11-03）

打包入口以用户的导入流程为准：`Watchface/module.autorun.canopus/_Lua/`。
本轮不再改 `resource.bin`，也没有向手表写入文件或 flash。

## 已确认与已修正

- Manager 旧 `gate_off` 在 `if` 外写入，闸原本关闭时也会留下该末行，不能单凭它断言模块崩溃。
- Manager 曾把 flash 门拒绝、`/data/rc` 写入失败汇总为普通“安装: 完成”；现在失败明确显示“安装: 未完成”。
- 保留原来的防砖闸与恢复规则：应用配置不会重开因 `gate_off` 留下的关闭状态；必须由用户明确开启。
- 新增独立 `/data/rc.d/.autorun.trace`，记录最近一次到达生成区的 check、entered、各模块 start/return 和 finished；不参与开关决策。它是最新执行记录，不是历次崩溃档案。
- 上一轮 Canopus 改为 foreground 推进后仍要求熄屏，和熄屏暂停 heartbeat 冲突。现仅 `.036` / `.043` 在 guarded foreground heartbeat 中逐步注册；background/generic poll 不会推进，回调重入被拦住。其它型号保留原策略。
- Canopus 注册时只读 Manager 总开关并提示 Enable/Apply；不会自行开闸。旧二跳清理失败会向 UI 报告，不再吞掉错误。

## 最终导入文件

`Watchface/module.autorun.canopus/_Lua/` 四个文件须一起保留：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| canopus_supervisor-xiaomi-band-10-pro-3.101.036.bin | 120564 | db87d15d8ec64966d361aebf025e1664a06e0a11b47fa0cf4a7df6f641485e7e |
| canopus_supervisor-xiaomi-band-10-pro-3.101.043.bin | 127472 | b19505f4f598289a12007c16adcce4beb76274f5f00e2c0148e3a33b334ddb74 |
| main.lua | 22082 | e0b7894f499f4416c508637aa3eb4c3acc4a48fc2b3e380e1584eddabafe946c |
| manager_icon.bin | 54768 | d0573a7caae7e6534934f7567c2060be92dae2bc0fa7cd8e7026b1e46848452c |

Manager 的修正入口是 `Watchface/module.autorun.Manager/_Lua/module-autorun-manager.lua`；两项目 resources 镜像也已同步行为。

## 更新及设备验收

1. 重新导入、打包并更新 Canopus 和 Manager 的 `_Lua` 源。
2. Canopus 点 `Autostart Install`，将新 bin、boot frame 和 canopus.sh 回读校验后写到手表；不要用 `Clear Env`，不需要清空已有模块。
3. Manager 查看安装状态。`.043` 应认到 `init rc 已装`；未装时 `[1 安装]` 是两阶段，第一次仅探测，明确提示后第二次才写 flash。不能只看最后一行。
4. 如果总开关关闭，显式按 `[3 开启]`，随后确认 `[2 应用自启动]` 已同步，Canopus 为允许。重启前不要用 Run 来代替冷启动验证。
5. 重启后点亮屏幕并留出至少六秒让 foreground 各阶段推进；若期间熄屏，待唤醒继续。检查 Manager/Launcher 与总开关。

注意：Canopus 两个固件的 bin 不等于 Manager flash hook 同时支持两个固件。现有 Manager 的内置原块只适用于 `.043`，`.036` 会拒绝安装该 hook；本次未放宽固件/逐字节校验门。

仍失败时，先保存手表上的 `/data/rc`、`/data/rc.d/.autorun.log`、`/data/rc.d/.autorun.trace`、`/data/canopus/autostart.log`、`/data/canopus/boot_reply.bin` 和 `/data/10pro.autorun/manager.log`，再进行开启或重装。`start_canopus` 未返回与 Canopus 内部 start/insmod/boot_cmd_sent/done 可一起定位中断步骤；日志标记只说明命令执行到了哪里，不证明 insmod/注入成功。

## 已执行的验证及边界

- 两个目标构建与 ELF verifier PASS：17 sections，0 undefined，resident 分别为 155206 / 166454 字节。
- `lua tool/test_canopus_autorun.lua`：22 个场景，通过（直接加载导入目录 main.lua，使用实际 bin/icon 作 fixture）。
- `lua tool/test_manager_autorun.lua`：81 项，通过；两份 Manager 源均覆盖安装失败、防砖策略、trace、旧 rc 迁移与幂等。
- `make -B -s run`、ASan/UBSan 同套 host 回归、cross-thumb：通过；boot 测试 `.036/.043` 各 93 checks、`.155/.179` 各 79 checks。
- Lua 语法与相关差异空白检查通过。

这些是主机模拟与构建证据，不是实际手表的冷启动验证；尚不能确认原先 gate_off 对应的物理复位或阻塞点已经消失。
