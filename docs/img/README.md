# docs/img —— 界面配图

这几张图是**离线渲染**出来的，不是真机截图。生成方式见 [`../../tool/render_manager_ui.py`](../../tool/render_manager_ui.py)。

## 文件

| 文件 | 内容 |
|---|---|
| `manager-main-seeded.png` | 主页（四键 + 状态行 + 日志框） |
| `manager-autostart-seeded.png` | 自启动页（安装/卸载/开启/关闭 + 状态面板） |
| `manager-modules-seeded.png` | 模块管理页（装着 chaos + shellpp2 两行） |
| `manager-log-seeded.png` | 日志页 |

`-seeded` = 预置了一台**典型设备**（装了 chaos + shellpp2、闸开着、上次开机跑到底），
这样面板是全绿状态，配文档才有信息量。不加 `--seed` 出来的是"空设备"（什么都没装）。

## 重新生成

```bash
python tool/render_manager_ui.py --seed --scale 2 --out docs/img
```

需要 `lupa` 与 `Pillow`（本机 `~/.workbuddy/binaries/python/envs/default` 里都有）。

## ⚠️ 这是几何近似，不是观感判据

渲染器用真 Lua + 假 lvgl 载入真源、按对象树画出来，所以**文案/颜色/层级/大致布局是真的**，
但假 lvgl 没有真实 LVGL 的布局引擎，字体也是拿系统字体近似的。
⇒ 它**能**用来看"大概长什么样 / 有没有重叠"，**不能**当作真机观感的判据。
按本项目一贯的规矩：**UI 观感、尺寸、显隐一律以真机为准。**
