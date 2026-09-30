#!/bin/bash
# 请一个房间**自己正常退出**，好让它把断开通知真正发给客户端。
#
# ## 为什么不能直接发 SIGTERM
#
# Godot 收到 SIGTERM 是立刻退出，**不走 `_exit_tree`**（2026-09-30 实测：
# 进程 8～24 毫秒就没了，而 `Net.shutdown_gracefully()` 里那六轮 poll 本身要 240 毫秒——
# 时间对不上就说明它根本没跑到）。后果是 `systemctl stop` 时断开通知从未发出，
# 客户端只能等 5 秒心跳，看到的是"与主机失去联系"而不是"与主机断开"。
#
# ## 做法
#
# 建一个哨兵文件，游戏每个 0.2 秒看一次，看到就自己 `quit()`。**等待放在这个脚本里**
# 而不是靠 systemd 的 TimeoutStopSec：systemd 在 `ExecStop` 返回之后就会发 SIGTERM，
# 那时游戏还没反应过来。脚本自己等，就不会有那个窗口。
#
# 等不到就什么都不做地退出（返回 0）：接着落到 systemd 默认的 SIGTERM，
# 与没有这个脚本时一样——**它只会让停止变得更好，不会让停止变得更不可靠**。
#
# 用法（由 systemd 的 ExecStop 调用，实例名是端口）：
#   graceful-stop.sh 40001 [等待秒数]
#
# 手动验证：
#   在服务器上停一间房，然后看客户端日志：
#     [session] 与主机断开：与主机断开        ← 通知送到了（目标）
#     [session] 与主机断开：与主机失去联系…   ← 还是心跳兜底（哨兵没生效）
set -u

PORT="${1:-}"
TIMEOUT="${2:-8}"
UNIT="moltenfrost@${PORT}"

if [ -z "$PORT" ]; then
	echo "用法：graceful-stop.sh <端口> [等待秒数]" >&2
	exit 2
fi

# **这个拼法必须与 scripts/main.gd 的 stop_file_path_for() 一致。**
# 两边各写一份是刻意的（一个在 GDScript、一个在 shell，没法共用常量）；
# 改一处就要改另一处，否则停止会静默退化回"客户端多等 5 秒"。
SENTINEL="/tmp/moltenfrost-stop-${PORT}"

rm -f "$SENTINEL"
touch "$SENTINEL"

# 等进程消失。用 MainPID 而不是 pgrep：单元里可能还有别的辅助进程，
# 而"主进程退出"才是 systemd 认定的停止。
waited=0
while [ "$waited" -lt "${TIMEOUT}0" ]; do
	pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)
	if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -d "/proc/$pid" ]; then
		echo "graceful-stop: $UNIT 已自行退出（等待 $((waited / 10)) 秒）"
		rm -f "$SENTINEL"
		exit 0
	fi
	sleep 0.1
	waited=$((waited + 1))
done

# 超时：把哨兵留下（下次停止会重新建），交给 systemd 的 SIGTERM。
# 这不是错误路径，而是一种退化——因此只提醒，不让 systemd 认为停止失败。
echo "graceful-stop: $UNIT 在 ${TIMEOUT} 秒内没有响应哨兵，交给 SIGTERM" >&2
exit 0
