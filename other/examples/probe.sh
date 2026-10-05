# /data/rc.d/zprobe.sh  —— 自启动链探针（最小版）
#
# 目的：把「/data/rc 里有一行」升级成「那一行**真的被执行了**」这条判据。
#       前者看一眼文件就知道，后者只能靠"留个痕迹"。
#
# 用法（三步）：
#   1. 把这个文件放进设备的 /data/rc.d/ ，文件名就叫 zprobe.sh
#   2. 打开一次 10pro.autorun 表盘 -> 按 [3 模块管理] 确认列表里有 zprobe ->
#      按 [2 重建自启动]（**没有自动重建**：打开只是"看见"，落盘要按键）
#        -> /data/rc 里多出 `sh /data/rc.d/zprobe.sh`（★ 不带 &：v0.6 起模块之间串行）
#   3. 重启设备
#
# 判据：
#   /data/10pro.autorun/probe-ran.txt 存在            => 探针脚本被执行过（核心判据）
#   /data/10pro.autorun/probe-rcd.txt 里列着 zprobe.sh => 注册目录当时的样子
#   /data/10pro.autorun/probe-rc.txt  里含 zprobe 那行 => 管理器生成的 /data/rc 原文
#   ★ 落点在 /data/10pro.autorun/ —— 那是管理器**自己的**目录（它是独立项目），
#     别写去 /data/chaos（那家的东西跟我们混在一起就分不清谁写的了）。
#
# ★ 为什么叫 z 开头：生成区按 order 升序、同 order 再按名字排序。
#   默认 order=100（chaos 是 10、shellpp2 是 20），所以这个探针排在最**后**，
#   它 dump 出来的 /data/rc 是"别人都已经起了"之后的状态。
#
# ★ 为什么必须自己 sleep：管理器的 delay 字段目前**只记录不生效**（见 REGISTER.md §3），
#   /data/rc 不会替你 sleep。要错开时机只能自己写在这儿。
#
# ★ v0.6 起模块之间**串行**（生成区不带 &，行间夹 `sleep 1`）：这个 sleep 3 会把
#   排在它后面的模块一起推迟 —— 这是"探针排最后"的另一个理由。脚本必须自己尽快返回。
#
# ★ 只用有证据的 nsh 命令：没有 &&、没有 ||、没有 $()、没有循环、没有 >>。
#   每一行都是独立的 `命令 > 文件`，任何一行挂掉都不会影响上面已经写好的判据。
#
# ★ 这是**往外写**的脚本，不碰 /data/rc，不碰 flash，不 insmod，移除它只需要
#   删掉 /data/rc.d/zprobe.sh 再按一次 [2 重建自启动]。

echo "probe-ran" > /data/10pro.autorun/probe-ran.txt

sleep 3

ls /data/rc.d > /data/10pro.autorun/probe-rcd.txt
cat /data/rc > /data/10pro.autorun/probe-rc.txt
