# -*- coding: utf-8 -*-
"""给 Chaos-Module 的 supervisor/src/ipc.rs 打「开机自启动 DQ」补丁。

做法: 不做整体重写, 只做一次**文本搬移** ——
  1. 把 chaos_write 里 `match cmd { CMD_INSTALL => { <原样内容> } _ => {} }`
     的 <原样内容> 原地取出;
  2. 把它包进新函数 `run_install_cmd(arg0, arg1)`(只减 4 格缩进, 一个字符都不改);
  3. chaos_write 里那一段换成两行派发。

这样「派发路径」与「write 路径」共用同一份代码, 且被搬动的字节可逐字节比对。
"""
import io
import os
import re
import sys

SRC = r"C:\zcode\chaos-autostart\Chaos-Module\supervisor\src\ipc.rs"

A = "    match cmd {\n        CMD_INSTALL => {\n"
B = "        }\n        _ => {}\n    }\n"

DQ_BLOCK = r'''
// ===========================================================================
// 开机自启动: 延迟命令号(DQ) + UI 任务派发
// ===========================================================================
//
// 为什么必须这么做(同机同固件真机实测):
//   * sh / nsh 任务里**同步**调固件注册链 -> write() 不返回 -> rtc_watchdog 硬重启;
//   * 同一个调用改由 lv_timer 回调(**UI 任务**)执行 -> 正常返回;
//   * lv_timer_create 本身**从 sh 任务里调是安全的** —— 同机另一路同类模块的
//     dq_ensure_timer() 就是在 fops.write 上下文里建的定时器, 真机两条 DQ 命令都
//     正常返回(状态机走到 COMPLETED)。
// => rc 里的 dd 只"入环即返回", cmd_install / notify 由 UI 任务按拍派发。
//    一格一拍也保住了安装器原有的时序保证: 注册链的中间态不会被同一拍读到。

/// 开机序列的触发命令号 —— "3CHS", 与 CMD_MAGIC("1CHS") / STATUS_MAGIC("2CHS") 同一命名法。
/// rc 里只发这一条; 序列本身写死在下面, 所以 rc 那侧没有 cmds.bin、没有相对时序。
pub const CMD_BOOT_DQ: u32 = 0x5348_4333;

/// 触发后按拍跑的序列。与 installer/chaos_installer.lua 的 pipeline 同序,
/// 只去掉在 ko 侧落进 `_ => {}` 的三条全空操作(0x0A / 1 / 2):
///   0x18 = 设中文 —— 纯 BSS 写、零固件调用; 开机 BSS 清零, 所以必须每开一次机重设
///   0x13 = 完整注册链(内部已含 init_buffer 与 notify_firmware_full)
///   0x22 = 回读槽统计, 给"注册是否真生效"提供 d0/d1/d2 读数
static DQ_SEQ: [u32; 3] = [0x18, 0x13, 0x22];

const DQ_PERIOD_MS: u32 = 1000;  // 跑序列时(= 安装器 Lua 的原周期)
const DQ_IDLE_MS: u32 = 60000;   // 跑完切慢 —— 常驻 lv_timer 不许用固定频率(续航红线)
const DQ_TRIES_MAX: u32 = 8;

static mut DQ_STEP: u32 = 0;     // 0 = 空闲; n = 下一个要跑 DQ_SEQ[n-1]
static mut DQ_TRIES: u32 = 0;
static mut DQ_TIMER: u32 = 0;
static mut DQ_FIRED: u32 = 0;    // 本次加载只允许开一次(模块每次开机只装一次)

/// 安装流程的 arg0 派发 + 尾部槽位四词。
/// **从 chaos_write 里原样搬出来的, 一字未改** —— 派发路径与 write 路径共用同一份代码,
/// 绝不允许出现第二份实现。arg1 只有 0x30(字体投递)用。
unsafe fn run_install_cmd(arg0: u32, arg1: u32) {
@INNER@}

/// DQ 派发回调 —— **跑在 UI 线程**(它是一台 lv_timer 的回调)。
unsafe extern "C" fn dq_timer_cb(_t: u32) {
    let step = st_rd!(DQ_STEP);
    let timer = st_rd!(DQ_TIMER);
    if step == 0 {
        if timer != 0 { fw_api::timer_set_period(timer, DQ_IDLE_MS); }
        return;
    }
    let i = (step - 1) as usize;
    if i >= DQ_SEQ.len() {
        st_wr!(DQ_STEP, 0);
        if timer != 0 { fw_api::timer_set_period(timer, DQ_IDLE_MS); }
        return;
    }
    st_wr!(WRITE_BUSY, 1);   // 与 write 路径**同一把锁**: notify_installed 内部的 lookup
    run_install_cmd(DQ_SEQ[i], 0);  // 会触发 launcher 重发 INSTALL, 那时必须静默丢弃
    st_wr!(WRITE_BUSY, 0);
    st_wr!(DQ_STEP, if i + 1 >= DQ_SEQ.len() { 0 } else { step + 1 });
    if st_rd!(DQ_STEP) == 0 && timer != 0 {
        fw_api::timer_set_period(timer, DQ_IDLE_MS);
    }
}

/// rc 那条 dd 进来后调它: 建一台 UI 线程的定时器, 再把游标打到第 1 步。
/// **这里不做任何固件框架调用** —— 只建定时器, 所以在 write 上下文里是安全的。
/// 8 次都没建成 => 返回 -19, **不假装成功**。
unsafe fn dq_start() -> i32 {
    if st_rd!(DQ_FIRED) != 0 { return 0; }          // 本次加载只开一次, 不重入
    if st_rd!(DQ_TIMER) == 0 {
        if st_rd!(DQ_TRIES) >= DQ_TRIES_MAX { return -19; }
        st_wr!(DQ_TRIES, st_rd!(DQ_TRIES) + 1);
        let t = fw_api::timer_create(dq_timer_cb as *const () as u32, DQ_PERIOD_MS, 0);
        if t != 0 { st_wr!(DQ_TIMER, t); }
    }
    if st_rd!(DQ_TIMER) == 0 { return -19; }
    st_wr!(DQ_FIRED, 1);
    st_wr!(DQ_STEP, 1);
    fw_api::timer_set_period(st_rd!(DQ_TIMER), DQ_PERIOD_MS);
    0
}

'''

NEW_MATCH = '''    match cmd {
        CMD_INSTALL => run_install_cmd(arg0, arg1),
        CMD_BOOT_DQ => { let _ = dq_start(); }
        _ => {}
    }
'''

ANCHOR = '#[no_mangle]\npub(crate) unsafe extern "C" fn chaos_write('


def dedent4(block):
    """整体减 4 格缩进; 任何非空行缩进不足 4 格就报错(说明锚点选错了)。"""
    out = []
    for line in block.split("\n"):
        if line.strip() == "":
            out.append("")
        elif line.startswith("    "):
            out.append(line[4:])
        else:
            raise AssertionError("缩进异常, 拒绝搬移: %r" % line)
    return "\n".join(out)


def main():
    src = io.open(SRC, encoding="utf-8", newline="").read()
    orig = src

    assert "CMD_BOOT_DQ" not in src, "看起来已经打过补丁了 (CMD_BOOT_DQ 已存在)"
    i = src.index(A)
    j = src.index(B, i)
    inner = src[i + len(A):j]
    # 被搬走的字节留底, 供逐字节比对
    io.open(os.path.join(os.path.dirname(SRC), "_moved_block.txt"), "w",
            encoding="utf-8", newline="").write(inner)

    # 1) chaos_write 里的 match 换成两行派发
    src = src[:i] + NEW_MATCH + src[j + len(B):]

    # 2) run_install_cmd 定义插到 chaos_write 之前
    k = src.index(ANCHOR)
    assert src.count(ANCHOR) == 1
    src = src[:k] + DQ_BLOCK.replace("@INNER@", dedent4(inner)) + src[k:]

    # 3) 自检: 花括号平衡 + 关键片段齐
    assert src.count("{") == src.count("}"), ("花括号不平衡", src.count("{"), src.count("}"))
    assert src.count("(") == src.count(")"), "圆括号不平衡"
    for must in ("unsafe fn run_install_cmd(arg0: u32, arg1: u32) {",
                 "CMD_BOOT_DQ => { let _ = dq_start(); }",
                 "CMD_INSTALL => run_install_cmd(arg0, arg1),",
                 "if cmd == CMD_INSTALL && st_rd!(APP_REGISTERED) != 0"):
        assert must in src, "缺片段 %r" % must
    assert "CMD_INSTALL => {" not in src, "旧的内联 arm 没被替换干净"

    io.open(SRC, "w", encoding="utf-8", newline="").write(src)
    print("PATCH-IPC: OK  %d B -> %d B" % (len(orig), len(src)))


if __name__ == "__main__":
    sys.exit(main())
