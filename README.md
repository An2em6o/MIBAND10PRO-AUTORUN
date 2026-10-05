# MIBAND10PRO-AUTORUN

小米手环 10 Pro 原生模块开机自启动工程：一套管理器 + 三个原生模块（Shell++ II / Chaos / Canopus）的接入与安装器。

> **只是想用？** 直接看 **[`docs/USAGE.md`](docs/USAGE.md)** —— 面向普通用户的中文教程（不用编程、全程在手表上手点，以 Chaos 模块为例）：装自启动 → 装模块自启动 → 日常管理 → 重建 → 卸载 → 故障急救。
> 下面是给开发者/维护者的工程说明。

## 支持设备

| 机型 | 固件 |
|---|---|
| 小米手环 10 Pro（`miwear.watch.p67tc`） | **3.101.043** |

## 项目框架

```
表盘安装器（Lua，Watchface/）
        │
        │  挂各模块自己的协议：
        │  Manager ── /data/rc.d 注册 + /data/rc 防砖闸
        │  chaos   ── chaos 协议（DQ + rc.d）
        │  canopus ── Canopus 协议（BOOT_DQ "3PC1" + rc.d）
        │  shellpp-ii ── /data/rc.d 注册
        ▼
原生模块（modules/，内核态 .ko / ELF）
        │  开机时由管理器 /data/rc 逐条拉起
        ▼
固件（openvela / NuttX + LVGL）
```

各模块安装器只投"自己要跑什么"到 `/data/rc.d/<名>.sh`（纯命令），防砖闸与安全延时统一归管理器生成的 `/data/rc`，接入规范见 [`docs/MODULE-STANDARD.md`](docs/MODULE-STANDARD.md)、[`docs/REGISTER.md`](docs/REGISTER.md)。

## 项目结构

```
MIBAND10PRO-AUTORUN/
├── Watchface/                  # 安装器表盘（可打包安装的完整 face 工程）
│   ├── module.autorun.Manager    # 管理器：自启动总闸 / 模块管理 / 日志
│   ├── module.autorun.shellpp-ii # Shell++ II 安装器
│   ├── module.autorun.chaos      # Chaos 安装器（chaos 协议）
│   └── module.autorun.canopus    # Canopus 安装器（Canopus 协议）
│
├── modules/                    # 模块源码
│   ├── Shellpp-ii               # Shell++ II（安装器，Apache-2.0）
│   ├── Chaos-Module             # Chaos 模块本体（完整源码，AGPL-3.0）
│   └── Canopus-Module           # Canopus 模块框架（完整源码，AGPL-3.0）
│
├── docs/                       # 文档（接入标准、注册契约、设计与分析记录）
├── tool/                       # 构建 / 补丁 / 仿真脚本
└── other/                      # 备份与留档（基本无用）
```

## 如何开发

**改安装器（Lua）**：改 `Watchface/<名>/_Lua/main.lua`，注意与 `resources/_Lua/` 保持逐字节一致，再用模块自带打包工具出 `.face` / `.mwz`。

**改模块源码**：

```bash
# Canopus supervisor（产物自动暂存到安装器 prod 目录）
cd modules/Canopus-Module
CANOPUS_TARGET=xiaomi-band-10-pro-3.101.043 sh scripts/build_canopus_supervisor.sh

# Chaos：ko 编译 / 搬移 / 安装器行为三道门
python tool/check_all.py
```

改完 Lua 至少跑一次语法门：

```bash
lua -e "assert(loadfile('Watchface/module.autorun.canopus/_Lua/main.lua'))"
```

各模块细节见 `modules/<名>/README.md`，设计与历史分析见 [`docs/`](docs/)。

**教程**：[`docs/USAGE.md`](docs/USAGE.md) —— 普通用户使用教程（装自启动 / 装模块自启动 / 管理 / 重建 / 卸载 / 故障判读）。

## 许可

| 范围 | 许可 |
|---|---|
| 仓根（管理器、文档、脚本） | [Apache-2.0](LICENSE) |
| `modules/Shellpp-ii` | Apache-2.0 |
| `modules/Chaos-Module` | AGPL-3.0 |
| `modules/Canopus-Module` | AGPL-3.0 |

各目录许可以其自身 `LICENSE` 为准，完整说明见 [`docs/NOTICE.md`](docs/NOTICE.md)。
