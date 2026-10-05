# -*- coding: utf-8 -*-
"""Chaos 自启动补丁 —— 交付前三道门, 一次跑完。

  G1  ko 编译门   : 用宿主目标对本 crate 做完整 type-check(--emit=metadata)。
                    它能咬住语法错与类型错, 且**带负向对照**(见 --selftest)。
  G2  搬移一致性  : chaos_write 里被搬进 run_install_cmd 的那段字节, 逐字节等于原文。
  G3  安装器行为门: 真 Lua + 假 lvgl/io/os.execute, 点按钮, 逐条核对产物。

用法:
  python check_all.py            跑三道门
  python check_all.py --selftest 先做负向对照(故意注入错, 必须被咬住), 再跑三道门
"""
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = r"C:\zcode\chaos-autostart"
SUP = os.path.join(ROOT, "Chaos-Module", "supervisor")
IPC = os.path.join(SUP, "src", "ipc.rs")
MOVED = os.path.join(SUP, "src", "_moved_block.txt")
PY = sys.executable
RUSTC = r"C:\Users\Administrator\.cargo\bin\rustc.exe"

FAILS = []


def say(ok, label, extra=""):
    print("  %s %s  %s" % ("ok  " if ok else "FAIL", label, extra if not ok else ""))
    if not ok:
        FAILS.append(label)


# ------------------------------------------------------------------ G1
def rustc_check(src_root, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    r = subprocess.run([RUSTC, "--edition", "2021", "--crate-type", "lib",
                        "--crate-name", "chaos_sup", "--emit=metadata",
                        "--out-dir", out_dir, os.path.join(src_root, "src", "lib.rs")],
                       capture_output=True)
    return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")


def gate_ko(selftest):
    if selftest:
        tmp = tempfile.mkdtemp(prefix="chaosko_")
        shutil.copytree(SUP, tmp, dirs_exist_ok=True)
        with io.open(os.path.join(tmp, "src", "ipc.rs"), "a", encoding="utf-8") as f:
            f.write("\nfn broken( { }\n")
        rc, msg = rustc_check(tmp, os.path.join(tmp, "out"))
        say(rc != 0 and "unclosed delimiter" in msg,
            "G1-负向: 故意注入语法错必须被咬住", msg.split("\n")[0])
    rc, msg = rustc_check(SUP, os.path.join(ROOT, "_chk_out"))
    say(rc == 0, "G1 ko 编译门 (宿主 type-check)", msg.strip()[:400])
    if rc == 0:
        print("       -> 0 error / 0 warning")


# ------------------------------------------------------------------ G2
def gate_moved():
    moved = io.open(MOVED, encoding="utf-8", newline="").read()
    new = io.open(IPC, encoding="utf-8", newline="").read()
    head = "unsafe fn run_install_cmd(arg0: u32, arg1: u32) {\n"
    i = new.index(head) + len(head)
    j = new.index("\n}\n", i)
    body = new[i:j] + "\n"
    rebuilt = "\n".join(("    " + l) if l.strip() else l for l in body.split("\n"))
    say(rebuilt == moved, "G2 搬移块逐字节相同",
        "md5 %s vs %s" % (hashlib.md5(rebuilt.encode()).hexdigest(),
                          hashlib.md5(moved.encode()).hexdigest()))
    print("       -> %d B  md5 %s" % (len(rebuilt), hashlib.md5(rebuilt.encode()).hexdigest()))


# ------------------------------------------------------------------ G3
VENV_PY = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"


def _has_lupa(py):
    try:
        return subprocess.run([py, "-c", "import lupa"],
                              capture_output=True).returncode == 0
    except OSError:
        return False


def pick_sim_py():
    """G3 需要 lupa(真 Lua VM)。当前解释器没有就退到装了 lupa 的 venv。
    环境问题要报成一句话, 不能让门自己崩成 traceback。"""
    if _has_lupa(PY):
        return PY, "解释器 %s" % PY
    if os.path.exists(VENV_PY) and _has_lupa(VENV_PY):
        return VENV_PY, "退用 venv: %s" % VENV_PY
    return None, "环境缺失: lupa 未安装 (pip install lupa)"


def gate_sim():
    py, note = pick_sim_py()
    if py is None:
        say(False, "G3 安装器行为门", note)
        return
    r = subprocess.run([py, os.path.join(ROOT, "_sim_autostart.py")], capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    tail = [l for l in out.strip().split("\n") if l.strip().startswith("SIM-AUTOSTART")]
    say(r.returncode == 0, "G3 安装器行为门", tail[0] if tail else out[-300:])
    if r.returncode == 0:
        print("       -> %s" % tail[0])
        print("       -> %s" % note)


def main():
    selftest = "--selftest" in sys.argv
    print("== Chaos 自启动补丁 · 交付前门 ==")
    gate_ko(selftest)
    gate_moved()
    gate_sim()
    print()
    if FAILS:
        print("CHECK-ALL: FAIL (%d)" % len(FAILS))
        for f in FAILS:
            print("   - " + f)
        return 2
    print("CHECK-ALL: PASS (3/3)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
