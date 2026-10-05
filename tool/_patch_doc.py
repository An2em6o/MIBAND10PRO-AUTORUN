# -*- coding: utf-8 -*-
"""把 AUTOSTART.md 的 §5（rc 侧）换成"已实施"版本，并在开头加状态说明、把 §9 指向 PATCH.md。"""
import io

P = r"C:\zcode\chaos-autostart\AUTOSTART.md"

NEW5 = '''## 5 rc 侧（已由安装器 UI 落地，见 `PATCH.md`）

### 5.1 二跳，别覆盖

`/data/rc` 已被 Shell++ II 占用，而且它可能是**被生成器写出来的**
（重跑那个项目的「安装文件」会把你追加的行冲掉）⇒ 只能追加一行，且必须幂等。

**这一步现在由安装器 UI 的「装自启文件」自动完成**（`autostart_install()`）：
先 `read_all("/data/rc")` 看有没有那一行，没有才用 `io.open(path, "a")` 追加。
「清除重置」对应地把**我们自己那一行**摘掉（`autostart_strip()` 逐行过滤，
不动别人的内容）。仿真门 D1 / D3 / E1 / G1 / G2 五条就是冲这个来的。

追加的那一行：

```sh
sh /data/chaos/rc &
```

> **不要**写 `[ -f … ] && sh … &` —— nsh 是子集解释器，`&&` / `[ -e ]` 没证据。
> 把判断题留在 `/data/chaos/rc` 里面（它内部 `if [ -f 开关文件 ]`），
> 文件不在时 `sh` 失败也无害（rc 开头 `set +e`）。

### 5.2 `/data/chaos/rc` 全文

语法逐条取自 Shell++ II 已跑通的 nsh 子集：`set +e` / `if [ -f ]…then…fi` /
`rm -f` / `echo >` `>>` / `sleep` / `insmod` / `dd`。**不含** `&&` `||` `$()`。

两档延时是本项目的参数，写死在安装器里（`AUTOSTART_DELAY` / `SAFETY_WAIT_S`）：

| 参数 | 本机取值 | rc 里对应 |
|---|---|---|
| `AUTOSTART_DELAY` | **8** | `sleep 8` —— 启动后 8 秒才开始干活 |
| `SAFETY_WAIT_S` | **15** | `sleep 15` —— 安全延时拉长到 15 秒 |

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

**防砖语义**（窗口 = 8 + 15 = **23 s**）：

```
t=0    rm -f autostart.on        ← 先关（第一刀）
t=8    insmod
t=9    dd boot.bin               ← 触发 DQ；ko 自己按 1 s 一拍走 3 步
t=24   echo on > autostart.on    ← 整段唯一的重建点
```

⇒ **这 23 秒内任何一次重启（掉电 / 看门狗 / 主动重启），开关都停在【关】**，
下次开机整段跳过。**这就是"防砖"的全部机制**，别把重建开关挪进模块里。

> `sleep 15` 的理由：ko 里 3 步 × 1 s = 3 s，再加 launcher 把桌面条目发出来的时间。
> 15 s 有 3 倍以上余量。

**注意**：`t=24` 的重建由 `sh` 任务完成，**不经过 `lv_timer_handler`** ⇒ 息屏时照跑。
但 ko 那 3 步在 **UI 任务的 lv_timer** 里 ⇒ **息屏时序列会暂停、亮屏继续**。
"开机就插上充电、屏幕黑着"的场景下，Chaos 图标要等亮屏才出现（可接受，但要知道）。

### 5.3 `/data/chaos/boot.bin` —— 16 字节

帧格式 `magic | cmd | arg0 | arg1`，两个"魔数"都挑成了可打印 ASCII：

| 偏移 | 值 | 含义 |
|---|---|---|
| `+0` | `31 43 48 53` | `CMD_MAGIC` = `0x53484331` = **"1CHS"** |
| `+4` | `33 43 48 53` | `CMD_BOOT_DQ` = `0x53484333` = **"3CHS"** |
| `+8` | `00 00 00 00` | arg0 = 0 |
| `+12` | `00 00 00 00` | arg1 = 0 |

⇒ 整串就是 `"1CHS3CHS"` + 8 个 `\\0`。

**生成方式（已落地）**：安装器 Lua 用现成的 `u32le()` 拼
（`u32le(CMD_MAGIC) .. u32le(CMD_BOOT_DQ) .. u32le(0) .. u32le(0)`），
写 `/data/chaos/boot.bin` 后**回读逐字节核对**。不依赖 nsh 的 `printf` / `\\x` 转义。

---
'''

NEW9 = '''## 9 落地清单

**已实施，逐步操作见 `PATCH.md` §7。** 要点：

```sh
cd supervisor && sh ../tools/build_ko.sh     # Windows: tools/build_ko.ps1
# 脚本自带四道: cargo -> rust-lld -> fix_ko_layout.py -> verify_chaos_ko.py(未定义符号必须为 0)
```

设备侧顺序：① 重编并部署 `/data/chaos/sup.ko` → ② 重新打包表盘容器（新的
`chaos_installer.lua`）→ ③ 进安装器 `运行` → ④ 进「自启动」页 `装自启文件` + `开自启动`
→ ⑤ **先做 G1'（手动 dd + 回读状态，别急着冷启）**，过了再冷启做 G2。
'''

STATUS = '''> **状态：已实施（2026-10-04）。** 见 `PATCH.md` —— 改动只落在
> `supervisor/src/ipc.rs` 与 `installer/chaos_installer.lua` 两个文件，
> 三道交付门前全绿（ko 宿主 type-check / 搬移块逐字节 / 安装器行为仿真 24 项），
> 且都带负向对照。本文档保留为**方案与理由**；落地细节以 `PATCH.md` 为准。
> 本文的 §5 已同步为落地版本 —— 两档延时 **8 s / 15 s**、防砖窗 **23 s**。
> 如需复算，本文与 `_sim_autostart.py` 的 C1 判据（硬编码 `sleep 8` / `safehold=15`
> / `sleep 15`）必须一致。
>
'''


def main():
    src = io.open(P, encoding="utf-8", newline="").read()
    n0 = len(src)

    # --- §5：按行号定位，两侧都有断言，改错就炸 ---
    lines = src.split("\n")
    assert lines[237] == "## 5 rc 侧", repr(lines[237])
    assert lines[331].startswith("## 6 "), repr(lines[331])
    lines = lines[:237] + NEW5.split("\n") + lines[331:]
    src = "\n".join(lines)

    # --- §9：一直到文件末尾（原文档 §9 后没有 --- 分隔行）---
    k = src.index("## 9 落地清单")
    j = src.find("\n---\n", k)
    if j < 0:
        j = len(src)
    src = src[:k] + NEW9 + src[j:]

    # --- 状态说明：插在文首那份项目元信息列表之后、第一条 --- 之前 ---
    h = src.index("\n---\n")          # 文首第一处 --- 即是元信息列表的结束
    src = src[:h + 1] + STATUS + src[h + 1:]

    # --- 正向/负向判据 ---
    for must in ("sleep 8", "delay=8", "safehold=15", "sleep 15", "23 s", "PATCH.md"):
        assert must in src, must
    for ban in ("sleep 5", "delay=5", "safehold=8", "## 5 rc 侧\n"):
        assert ban not in src, ban
    assert src.count("## 5 rc 侧") == 1
    assert src.count("## 9 落地清单") == 1
    assert src.count("> **状态：已实施") == 1

    io.open(P, "w", encoding="utf-8", newline="").write(src)
    print("PATCH-DOC: OK  %d B -> %d B" % (n0, len(src)))


if __name__ == "__main__":
    main()
