#!/bin/bash
# 网关的真实对局验证：两个 Godot 无头实例穿过网关，确认
#  1) 两个客户端都连上、服务端看到两个不同的 peer（= 网关的逐流 NAT 成立）
#  2) 两端互相看得见（有远端角色、位置在流动）
#  3) 第二个场景里两个客户端被分到不同房间，彼此不可见（= 房间隔离成立）
#
# 这是 docs/公网房间方案.md 2.3 那条"必须逐流一个 socket"的判据。
# 用单 socket 转发的写法会在这里失败：两人都能连上，但服务端把他们认成同一个 peer，
# 于是场上只有一个人、互相看不见。
set -u

GODOT=${GODOT:-/opt/godot/godot}
REPO=${REPO:-$HOME/moltenfrost}
# 网关本体。先编译：gcc -O2 -o build/net-gateway tools/net-gateway.c
GW=${GW:-$HOME/moltenfrost/build/net-gateway}
OUT=${OUT:-$HOME/moltenfrost/build/gateway-check}

start_room() { # $1=端口 $2=日志
	rm -f "$2"
	( cd "$REPO" && exec "$GODOT" --headless --path . -- --host --port "$1" ) >"$2" 2>&1 &
	echo $!
}

start_client() { # $1=公网口 $2=日志
	rm -f "$2"
	( cd "$REPO" && exec "$GODOT" --headless --path . -- --join 127.0.0.1 --port "$1" --net-stats --autopilot ) >"$2" 2>&1 &
	echo $!
}

stop_all() {
	for pid in "$@"; do kill "$pid" 2>/dev/null; done
	sleep 1
	for pid in "$@"; do kill -9 "$pid" 2>/dev/null; done
	sleep 1
}

report() { # $1=日志 $2=标题
	echo "--- $2 ---"
	grep -aE '\[(session|net-stats)\]' "$1" | head -12
	echo
}

# ================================================================ 场景零：对照
# 不经网关直连房间。用来回答"那 7 ms 的 RTT 是不是网关带来的"——
# 没有这一组的话，看到的任何数值都无法归因。
echo "=========== 场景零：对照，客户端直连房间（不经网关） ==========="
rm -rf "$OUT"; mkdir -p "$OUT"
ROOM0=$(start_room 40001 "$OUT/room0.log")
sleep 6
E1=$(start_client 40001 "$OUT/client0.log")
sleep 18
stop_all "$E1" "$ROOM0"
report "$OUT/client0.log" "客户端（不经网关）"

# ================================================================ 场景一：同一房间
echo "=========== 场景一：两个客户端进同一个房间 ==========="
rm -rf "$OUT"; mkdir -p "$OUT"
ROOM=$(start_room 40001 "$OUT/room1.log")
sleep 6
"$GW" --listen 27100 --rooms 127.0.0.1:40001 --stats 3 >"$OUT/gw1.log" 2>&1 &
GW1=$!
sleep 2
C1=$(start_client 27100 "$OUT/client1.log")
sleep 3
C2=$(start_client 27100 "$OUT/client2.log")
sleep 22
stop_all "$C1" "$C2" "$GW1" "$ROOM"

report "$OUT/room1.log" "房间（服务端）"
report "$OUT/gw1.log" "网关"
report "$OUT/client1.log" "客户端 1"
report "$OUT/client2.log" "客户端 2"
echo "服务端看到的 peer 数（期望 2 个不同的 id）:"
grep -ac 'peer .* 已连接' "$OUT/room1.log"
grep -a '已连接' "$OUT/room1.log" | head -4
echo

# ================================================================ 场景二：隔离
# 两个房间、每房限 1 人：两个客户端应当被分到不同房间，互相看不见。
echo "=========== 场景二：两个房间各限 1 人，验证隔离 ==========="
ROOMA=$(start_room 40001 "$OUT/roomA.log")
ROOMB=$(start_room 40002 "$OUT/roomB.log")
sleep 6
"$GW" --listen 27100 --rooms 127.0.0.1:40001,127.0.0.1:40002 --max-per-room 1 \
	--stats 3 >"$OUT/gw2.log" 2>&1 &
GW2=$!
sleep 2
D1=$(start_client 27100 "$OUT/clientA.log")
sleep 3
D2=$(start_client 27100 "$OUT/clientB.log")
sleep 20
stop_all "$D1" "$D2" "$GW2" "$ROOMA" "$ROOMB"

report "$OUT/gw2.log" "网关（应看到两房间各 1 人）"
echo "房间 A 收到的连接数（期望 1）:"; grep -ac '已连接' "$OUT/roomA.log"
echo "房间 B 收到的连接数（期望 1）:"; grep -ac '已连接' "$OUT/roomB.log"
echo "各客户端看到的远端角色（隔离成立时应当没有）:"
for f in clientA clientB; do
	printf '%s: ' "$f"
	if grep -aqE '远端 peer=' "$OUT/$f.log"; then echo "有远端角色 —— 隔离失效"; else echo "无远端角色"; fi
done
