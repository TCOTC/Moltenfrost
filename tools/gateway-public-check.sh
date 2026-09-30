#!/bin/bash
# 公网房间（经网关）的验证：两个真实客户端从公网地址进来，确认
#   1) 两人被网关分到**同一个房间**（所以能互相看见）
#   2) 两人都停在大厅，名单里是 2 个人
#   3) **先到的那个成为房主**（公网房间里 peer 1 是无头进程，不能拿它当房主）
#   4) 人齐之后房主请求开局，**两端都进关并各生成一个角色**
#
# 为什么要它：客户端侧的大厅状态在日志里只有 [lobby] 那一行能看出来，
# 而 tools/net-gateway-game-check.sh 走的是"连上即开局"（不带 --lobby），
# 因此它盖不到这条路径。
#
# 在**服务器本机**跑（也可在能连到网关的任意机器上跑，改第一个参数即可）：
#   ./gateway-public-check.sh [地址] [端口]
#   PHASE=2 ./gateway-public-check.sh          # 只跑第二阶段（排查时省时间）
#
# **在服务器本机验证时地址要填 127.0.0.1**，不要填公网域名：
# 从实例内部访问自己的公网地址走的是 hairpin NAT，多数云网络不支持，
# 表现为网关一个包都收不到（pkts_in=0），看着像网关坏了。
set -u

HOST=${1:-127.0.0.1}
PORT=${2:-27015}
GODOT=${GODOT:-/opt/godot/godot}
REPO=${REPO:-$HOME/moltenfrost}
OUT=${OUT:-/tmp/roomcheck}
DURATION=${DURATION:-18}
# 两个阶段之间必须把房间排空：被结束掉的客户端要过一会儿房间才发现它断开，
# 而房间还留着残留 peer 时下一阶段进来的客户端**不是房主**，于是谁也不请求开局
#（实测：名单里 3 人、房主是上一轮那个客户端，第二阶段两端都"没有进关"）。
# 要长于 Net.HEARTBEAT_TIMEOUT（5 秒）。
DRAIN=${DRAIN:-14}
# 只跑某一阶段（all / 1 / 2）。排查时用，省得每次都跑两遍。
PHASE=${PHASE:-all}
# 第二阶段的场景：它做真人在这里会做的事（房主请求开局），并断言两端都进了关。
DRIVE=res://tests/lobby_start_drive.tscn

rm -rf "$OUT"; mkdir -p "$OUT"

join() { # $1=日志  $2..=额外的场景参数
	local log="$1"; shift
	( cd "$REPO" && exec "$GODOT" --headless --path . "$@" -- \
		--join "$HOST" --port "$PORT" --lobby ) >"$log" 2>&1 &
	echo $!
}

show() { # $1=日志 $2=标题
	echo "--- $2 ---"
	# drive 也要列进来：驱动器那几行是这条路径上唯一的进度证据。
	grep -aE '\[(session|lobby|drive)\]' "$1" | head -12
	# 报错单独列出来。不列的话，脚本"一行都没输出"这类现象会被自己的过滤条件藏起来
	#（实测踩到：驱动器没有任何输出，而我一直在看被过滤后的日志）。
	local errs
	errs=$(grep -aE 'SCRIPT ERROR|Parse Error|ERROR:|Failed' "$1" | head -5)
	if [ -n "$errs" ]; then
		echo "  [报错]"
		echo "$errs" | sed 's/^/  /'
	fi
	echo
}

kill_all() {
	for pid in "$@"; do kill "$pid" 2>/dev/null; done
	sleep 2
	for pid in "$@"; do kill -9 "$pid" 2>/dev/null; done
}

# ================================================================ 第一阶段

if [ "$PHASE" != "2" ]; then
	echo "=========== 第一阶段：大厅与房主判定（$HOST:$PORT，${DURATION}s） ==========="
	FIRST=$(join "$OUT/first.log")
	sleep 4
	SECOND=$(join "$OUT/second.log")
	sleep "$DURATION"
	kill_all "$FIRST" "$SECOND"

	show "$OUT/first.log" "客户端 1（先到）"
	show "$OUT/second.log" "客户端 2"

	echo "=== 第一阶段判定 ==="
	host_line=$(grep -a '我是房主' "$OUT/first.log" | tail -1)
	if [ -n "$host_line" ]; then
		echo "OK: 先到的那个成了房主：$host_line"
	else
		echo "FAIL: 先到的那个没有成为房主（公网房间里 peer 1 是无头进程，不能当房主）"
	fi
	if grep -aq '名单：2 人' "$OUT/first.log"; then
		echo "OK: 先到的那一端看到了 2 个人（= 两人被分到了同一间房）"
	else
		echo "FAIL: 先到的那一端没有看到 2 个人 —— 两人可能被分到不同房间（检查网关的选房策略）"
	fi
	sleep "$DRAIN"
fi

# ================================================================ 第二阶段

if [ "$PHASE" != "1" ]; then
	echo
	echo "=========== 第二阶段：人齐 → 房主开局 → 进关（两端各生成一个角色） ==========="
	D1=$(join "$OUT/drive1.log" "$DRIVE")
	sleep 4
	D2=$(join "$OUT/drive2.log" "$DRIVE")
	# 等待上限由驱动器自己管（它写 40 秒 + 2 秒收尾），这里比它多留一点。
	sleep 32
	kill_all "$D1" "$D2"

	show "$OUT/drive1.log" "驱动器 1"
	show "$OUT/drive2.log" "驱动器 2"

	echo "=== 第二阶段判定 ==="
	pass=0
	for f in drive1 drive2; do
		if grep -aq '：通过' "$OUT/$f.log"; then
			echo "OK: $f 进了关且场上有 2 个角色"
			pass=$((pass + 1))
		else
			echo "FAIL: $f 没有进关（看上面它自己的日志）"
		fi
	done
	if grep -aq '请求开局' "$OUT/drive1.log" "$OUT/drive2.log"; then
		echo "OK: 有一端作为房主请求了开局"
	else
		echo "FAIL: 两端都没有请求开局（人齐的判定或房主判定不对）"
	fi
	echo "第二阶段通过 $pass/2 端"
fi

echo
echo "日志：$OUT"
