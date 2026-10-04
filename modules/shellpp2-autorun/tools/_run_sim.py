#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""shellpp2-autorun 离线门驱动：用 lupa(真 Lua) 跑 tools/_sim_autorun.lua。

  python tools/_run_sim.py        # 期望末行 SIM TOTAL: PASS (n/n)

为什么用真 Lua：本方案全是字符串/位运算/模式匹配/文件读写，
拿 Python 重写一遍只能证明"我写了两遍同一个猜测"。跑真 Lua 才是在验被测代码本身。
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.dirname(HERE)


def main():
    try:
        import lupa
    except ImportError:
        print("需要 lupa（真 Lua）。用带 lupa 的解释器，例：\n"
              "  C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe"
              " tools/_run_sim.py")
        return 2
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.SIM_PACK = PACK.replace("\\", "/")
    g.SIM_MAIN = os.path.join(PACK, "_Lua", "main.lua").replace("\\", "/")
    g.SIM_FAILED = 0
    g.SIM_TOTAL = 0
    with open(os.path.join(HERE, "_sim_autorun.lua"), "r", encoding="utf-8") as fh:
        src = fh.read()
    try:
        lua.execute(src)
    except Exception as exc:  # noqa: BLE001
        print("离线门异常终止: %s" % exc)
        return 1
    failed = int(g.SIM_FAILED)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
