# 许可与来源说明（NOTICE）

本仓库是**多个许可**的组合体。逐目录对应关系如下 —— 取用前请对准你要的那一块。

| 目录 / 内容 | 许可 | 说明 |
|---|---|---|
| `manager/`（`10pro.autorun` 管理器：`app/_lua/_Lua/dotui.lua` 唯一真源、`build_manager.py`、`tools/_sim_manager.py`、`tools/_prove_regression.py`） | **Apache-2.0** | 本项目自研 |
| 仓根全部 `*.md` 文档（`MANAGER.md` / `REGISTER.md` / `MODULE-STANDARD.md` / `FACE.md` 及历史文档） | **Apache-2.0** | 本项目自研 |
| 仓根脚本（`check_all.py` / `_sim_autostart.py` / `_patch_*.py` / `_port_flash_hook.py`）、`examples/`、`patches/` | **Apache-2.0** | 本项目自研 |
| `modules/shellpp2-autorun/`（Shell++ II 安装器 · 自启动页接入件） | **Apache-2.0** | 基座来自上游 **Shell++ II**（同样 Apache-2.0），改动部分见该目录 `README.md` |
| `Chaos-Module/`（Rust 内核模块 `module/` + `supervisor/` + Lua 安装器 `installer/`） | **AGPL-3.0** | **独立授权**，全文见 `Chaos-Module/LICENSE`。与仓根 Apache-2.0 **互不覆盖**；分发该目录时按 AGPL-3.0 履行义务 |

## 为什么仓根是 Apache-2.0，而 `Chaos-Module/` 是 AGPL-3.0

两者是**可独立分发的两块东西**，只是在同一棵树上协同工作：

- 管理器与"接入标准"是**通用基础设施**，希望别人能自由地拿去做自己的模块 ⇒ Apache-2.0。
- `Chaos-Module/` 是一个**完整的上游派生项目**（自带 `LICENSE` / `README.md` / `.gitignore`），
  其上游按 AGPL-3.0 发布 ⇒ **逐字节保留它的许可，不因并入本仓而改变**。

## 第三方组件

| 组件 | 上游 | 许可 |
|---|---|---|
| Shell++ II（安装器 / 原生模块基座） | 见 `modules/shellpp2-autorun/README.md` 附录中的上游说明 | Apache-2.0 |

## 固件与设备

本仓库**不含**任何厂商固件镜像（`*_full_*.bin`、`vela_ap.bin` 等一律不入库）。
设备地址、`insmod` 参数、寄存器偏移等是对**特定固件版本**（小米手环 10 Pro / `miwear.watch.p67tc` /
v3.101.043）逐条核出来的，换固件不适用 —— 详见各文档顶部的版本声明。
