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

## Apache-2.0 与 AGPL-3.0 放在同一个仓里，法律上是什么关系

**是「聚合」（aggregate），不是「单一作品」。**

| | |
|---|---|
| 两块东西怎么交互 | 各自独立分发、独立运行，只通过**文件系统**（`/data/rc.d/*.sh`）与**设备节点**（`/dev/…`）通信 —— 没有编译到一起、没有共享内存、没有链接 |
| 法律性质 | GPL/AGPL 第 5 条**明确允许**把互相独立的作品聚在一处分发（"发行版把不同许可的软件放一张光盘"就是这个模型） |
| 后果 | **每一块按自己的许可**：只取 `manager/` ⇒ 只受 Apache-2.0；只取 `Chaos-Module/` ⇒ 受 AGPL-3.0 |

⚠️ **兼容性有方向，别记反**：

| 方向 | 能不能 |
|---|---|
| **Apache-2.0 的代码 → 并入 AGPL-3.0 项目** | ✅ 可以（GPLv3 §7 认可 Apache-2.0 的附加条款；AGPLv3 与 GPLv3 同源） |
| **AGPL-3.0 的代码 → 并入 Apache-2.0 项目** | ❌ **不行** —— copyleft 会顶上来，整包必须变成 AGPL-3.0 |

⇒ 所以本仓是「**上宽下严**」：**整包**分发时，因为含 AGPL 部件，**整包按 AGPL-3.0 对待**才安全。
⇒ ★ **由此得到一条设计硬约束**：**不要把 `Chaos-Module/` 的代码并进 `manager/` 的 `.face`**。
一旦两边"打成一个作品"（编译进去、或把它的 Lua 复制进表盘），Apache-2.0 那半就保不住了。
现在两边只通过文件交互，正是为了守住这条线。

## 实务提示（这个项目的具体含义）

| 你要做什么 | 你的义务 |
|---|---|
| 拿 `manager/` 去改、甚至**闭源**分发 | ✅ 随意 —— Apache-2.0 不是 copyleft，保留声明即可 |
| 把 `chaos_sup.ko` 装在**自己**的表上自己用 | 无义务 —— AGPL 只在**分发**时触发 |
| **把装好 Chaos 的表（或 `.face` 包）分发 / 卖给别人** | ⚠️ **必须给源码**；且 AGPL **§6** 还要求提供 **"安装信息"**（能让对方刷入他自己修改版的必要信息）—— 在**嵌入式设备**上这一条比 GPL 更严格 |
| 拿它做**网络服务**（例如远程控制一台表） | ⚠️ AGPL **§13**：同样要给源码 |
| 用 `modules/shellpp2-autorun/` | ✅ Apache-2.0，同上，宽松 |

## Chaos-Module 的内部来源（完整版见它自己的 README §许可）

- 早期有一部分逻辑与容器实现派生自上游 **Canopus**（同为 AGPL-3.0）；**派生点已逐文件重写**，
  留下来的只有固件地址、结构偏移、协议字节格式这类**逆向得到的事实**（事实不受版权保护）。
- 字体与图标素材**不在本仓**，各自授权不同（其字体改作物属 **SIL OFL-1.1**）。

## 第三方组件

| 组件 | 上游 | 许可 |
|---|---|---|
| Shell++ II（安装器 / 原生模块基座） | 见 `modules/shellpp2-autorun/README.md` 附录中的上游说明 | Apache-2.0 |

## 固件与设备

本仓库**不含**任何厂商固件镜像（`*_full_*.bin`、`vela_ap.bin` 等一律不入库）。
设备地址、`insmod` 参数、寄存器偏移等是对**特定固件版本**（小米手环 10 Pro / `miwear.watch.p67tc` /
v3.101.043）逐条核出来的，换固件不适用 —— 详见各文档顶部的版本声明。
