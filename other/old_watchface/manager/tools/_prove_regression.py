# -*- coding: utf-8 -*-
"""判据有效性反证（v0.6.4 / v0.6.5 两代 bug，各一条）。

做法：把某条判据**从源码里拿掉**或**加回去**（= 回到修复前），写到 `_dropped/_probe/`
下的副本，再在**子进程**里跑一次门（开新解释器，避免上一轮的 FAILS/NCHK 累积）。
期望：门 FAIL，而且**唯一** FAIL 就是那条回归判据 —— 否则说明判据是"假绿"，
压根没咬住那个 bug（改了代码照样绿，那不叫验证）。

只读原文件；副本落在归档区（留档、不删），不污染工程树。
"""
import importlib.util
import os
import subprocess
import sys

SM = r"C:\zcode\chaos-autostart\manager\tools\_sim_manager.py"
OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(SM), "..", "..", "_dropped", "_probe"))
os.makedirs(OUT_DIR, exist_ok=True)

# 只为了拿 MGR / LUPA_PY 两个值（模块有 __main__ 保护，不会跑门）
_spec = importlib.util.spec_from_file_location("sm_meta", SM)
_sm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sm)
GOOD = open(_sm.MGR, encoding="utf-8").read()
LUPA_PY = _sm.LUPA_PY

GATE_OFF_LINE = "  if exists(GATE_OFF) then return false, false end\n"
IF_LINE_HACK = ('  local cur = read_all(RC_PATH) or ""\n'
                '  if cur:find(IF_LINE, 1, true) then return false, false end\n')
# v0.6.5 在 do_init_install 里把"托给 ensure_gate 推断"换成了"直接写"。还原 = 换回去。
NEW_GATE_BLOCK = ('  if not exists(GATE) and write_file(GATE, "on\\n") then\n'
                  '    log_append("总开关: 已打开 (" .. GATE .. ")", 0x8FF0A4)\n'
                  '  end\n'
                  '  if not exists(GATE) then\n'
                  '    log_append("总开关: 打不开 " .. GATE .. " -> 开机会不跑 /data/rc", 0xFF9A9A)\n'
                  '  end\n')
OLD_GATE_BLOCK = ('  local g2, made = ensure_gate()\n'
                  '  if made then log_append("总开关已建(默认开): " .. GATE, 0x8FF0A4) end\n'
                  '  if not g2 then log_append("总开关当前: 关 (" .. GATE .. " 不在)", 0xFFD27A) end\n')

# (版本, 期望咬住的判据, 说明, [(旧文本, 新文本) ...])
CASES = [
    ("v0.6.4", "R8",
     "拿掉 GATE_OFF 判据 —— 用户关过的总开关会被静默补建（会连挂 H8/R11c，正常）",
     [(GATE_OFF_LINE, "")]),
    ("v0.6.5", "R12",
     "把 [1 安装] 改回「托 ensure_gate 推断」+ 恢复 IF_LINE 反推 —— 打不开总开关",
     [(GATE_OFF_LINE, GATE_OFF_LINE + IF_LINE_HACK),
      (NEW_GATE_BLOCK, OLD_GATE_BLOCK)]),
]

# 子进程跑门的小 runner（写一次，复用）
RUNNER = os.path.join(OUT_DIR, "_run_sim_on.py")
with open(RUNNER, "w", encoding="utf-8", newline="") as fh:
    fh.write(
        "import importlib.util, sys\n"
        "spec = importlib.util.spec_from_file_location('sm', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(m)\n"
        "m.MGR = sys.argv[2]\n"
        "sys.exit(m.main())\n")

bad = 0
for ver, expect, why, subs in CASES:
    src = GOOD
    miss = False
    for old, new in subs:
        if old not in src:
            print("!! [%s] 找不到锚点 —— 源码变了？" % ver)
            miss = True
            break
        src = src.replace(old, new, 1)
    if miss:
        bad = 1
        continue
    tmp = os.path.join(OUT_DIR, "_pre_fix_%s_dotui.lua" % ver.replace(".", ""))
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(src)

    print("=" * 72)
    print("[%s] %s" % (ver, why))
    print("      副本 -> %s" % tmp)
    r = subprocess.run([LUPA_PY, RUNNER, SM, tmp], capture_output=True, text=True)
    tail = [ln.rstrip() for ln in (r.stdout or "").splitlines() if ln.strip()]
    verdict = next((ln for ln in tail if ln.startswith("SIM-MANAGER:")), "(无小结行)")
    fails = [ln.strip() for ln in tail if ln.strip().startswith("- ")]
    print("      门: %s" % verdict)
    for f in fails:
        print("        %s" % f)
    if r.returncode == 0:
        print("      ✗ 门居然 PASS —— 判据没咬住这个 bug（假绿）")
        bad = 1
    elif any(expect in f for f in fails):
        print("      ✓ 咬住了 %s（共挂 %d 条）—— 判据有效" % (expect, len(fails)))
    else:
        print("      ✗ 挂了 %d 条，但没有 %s" % (len(fails), expect))
        bad = 1

print("=" * 72)
if bad:
    print("REGRESSION-PROOF: FAIL —— 有判据是假绿的")
else:
    print("REGRESSION-PROOF: OK —— %d 条反证全部咬住（未修复版必 FAIL）" % len(CASES))
sys.exit(bad)
