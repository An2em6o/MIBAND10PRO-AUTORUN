# 旧表盘归档 —— `chaos_inst.v2-flash.face`

**为什么要留它**：从 v3（新标准）起，Chaos 安装器**不再具备写 flash 的能力** ——
flash 里那句 `sh /data/rc &` 的装/卸按新标准归管理器（`10pro.autorun`）的"装 init rc"。

而管理器的那个功能**还没做**（`MANAGER.md` §9 的 M3）。所以在 M3 落地之前，
**这一份 `.face` 是全机器唯一还能装 / 卸那 18 字节 hook 的东西**。
删掉它 = 在这台设备上失去"装/卸开机钩子"的唯一手段（`清除重置` 里的 `hook_restore` 也在这一份里）。

## 指纹

| 项 | 值 |
|---|---|
| 文件 | `chaos_inst.v2-flash.face` |
| 大小 | **305,836 B** |
| md5 | **`c89fcca5a77c2fa9b4771188cde21d18`** |
| 显示名（容器 `0x68`） | `Chaos 自启动` |
| 功能键 | 装自启文件 / 开自启动 / 关自启动 / 移除文件 / 返回（**5 个**，旧版） |
| 内嵌 | 32 KB rcS 原块（`ORIG_HEX`）+ flash 四道门 + 二跳 |

## 与它的关系

| 版本 | 文件 | 能力 |
|---|---|---|
| v2（本归档） | `_archive/chaos_inst.v2-flash.face` | 投文件 **+ 写 flash hook** + 往 `/data/rc` 追加二跳 |
| v3（当前产物） | `../chaos_inst.face` | **只投文件**（`/data/rc.d/chaos.sh`）；管理器没装就报错 |

来源：`../chaos_inst.face.prev` 被下次构建轮转**之前**的副本。

## 什么时候可以删

M3 做完、并且**真机验过**管理器能装/卸 hook 之后。
在那之前：不要删。
