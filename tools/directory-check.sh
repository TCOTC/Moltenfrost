#!/bin/bash
# 路线 A 的端到端验证：**房间目录 + 客户端直连房间**。
#
# 验五件事：
#   1) 目录活着，且向它**认领**得到一间空房（这就是玩家点「创建公网房间」做的事）
#   2) 两个客户端**直连同一间房**，都进大厅、都看到 2 人，先到的那个是房主
#   3) 房主改名 → 目录里那一项跟着变（房间名是 UTF-8，跨 HTTP + JSON 两跳）
#   4) 人齐之后房主开局 → 两端都进关、各生成一个角色
#   5) 人走光后房间回到**备用**状态：从公开列表里消失，但仍然在池里等着（别人看不到）
#
# **为什么不是固定连 40001**：服务器上的空房不在公开列表里（见 tools/room-directory.py
# 的 busy()），而且它在哪一号取决于人数——池会自己增减。因此像玩家一样向目录认领一间，
# 用拿到的端口。`ROOM_PORT` 仍可显式指定，那会跳过认领（调试时偶尔有用）。
#
# 在**服务器本机**跑（也可在能连到目录的任意机器上跑，改前两个参数即可）：
#   ./directory-check.sh [目录地址] [目录端口]
#
# 环境变量：ROOM_PORT 指定要连哪一间（默认向目录认领）。
set -u

HOST=${1:-127.0.0.1}
DIR_PORT=${2:-27017}
ROOM_PORT=${ROOM_PORT:-}
GODOT=${GODOT:-/opt/godot/godot}
REPO=${REPO:-$HOME/moltenfrost}
OUT=${OUT:-/tmp/dircheck}
DRIVE=res://tests/lobby_start_drive.tscn
# 与 127.0.0.1 一起用：房间是在这台机器上监听的。
ROOM_HOST=${ROOM_HOST:-127.0.0.1}
NEW_NAME=${NEW_NAME:-"熔霜·改名验证"}

rm -rf "$OUT"; mkdir -p "$OUT"

# 默认只列**非空闲**的房间——空房是藏着的，要进它只能认领。
listing() { curl -s "http://$HOST:$DIR_PORT/rooms"; }
# 连备用房一起列，用来验"人走光后房间还在池里"。
listing_all() { curl -s "http://$HOST:$DIR_PORT/rooms?all=1"; }
claim() { curl -s -X POST "http://$HOST:$DIR_PORT/rooms/claim"; }

# 从列表里取某一间的某个字段。用 python 而不是 jq：服务器上不一定有 jq，
# 而 python3 是目录服务本身就在用的东西，必然存在。
#
# **房间不在列表里时它输出空**，这是常见的（空房是藏着的，见 busy()），不是错误。
field() { # $1=端口 $2=字段
	python3 -c '
import json,sys
port=int(sys.argv[1]); key=sys.argv[2]
try:
    rooms=json.load(sys.stdin)["rooms"]
except Exception:
    print(""); raise SystemExit
for r in rooms:
    if r["port"] == port:
        print(r.get(key, "")); raise SystemExit
print("")
' "$1" "$2"
}

# 打印某一间现在的 "名字|状态|人数"，不在列表里时两个竖线之间都是空的。
sample() { # $1=端口
	python3 -c '
import json,sys
port=int(sys.argv[1])
try:
    rooms=json.load(sys.stdin)["rooms"]
except Exception:
    rooms=[]
hit=[r for r in rooms if r["port"]==port]
if not hit:
    print("||"); raise SystemExit
r=hit[0]
print("%s|%s|%s" % (r["name"], r["state"], r["players"]))
' "$1"
}

# **整局过程中持续采样目录。** 不能只在最后读一次：驱动器一旦通过就自己 quit()，
# 客户端退出后房间重回空闲、就从公开列表里消失了（那是池在正常工作），
# 而那时再去读就什么都读不到。采到的每一行都留着，事后断言"曾经看到过"。
sampler() { # $1=端口 $2=输出文件
	: >"$2"
	for _ in $(seq 1 120); do
		listing | sample "$1" >>"$2"
		sleep 1
	done
}

join() { # $1=日志  $2..=拼在 `--` 之后的额外用户参数
	local log="$1"; shift
	# 注意场景名必须在 `--` **之前**，而 --rename 这类自定义参数必须在**之后**：
	# 引擎只把 `--` 之后的东西交给 OS.get_cmdline_user_args()，而驱动器是在那里读的。
	# 放错位置的现象是"参数静默无效"——引擎会忽略不认识的参数，不报错。
	( cd "$REPO" && exec "$GODOT" --headless --path . "$DRIVE" -- \
		--join "$ROOM_HOST" --port "$ROOM_PORT" --lobby --public-room "$@" ) >"$log" 2>&1 &
	echo $!
}

kill_all() {
	for pid in "$@"; do kill "$pid" 2>/dev/null; done
	sleep 2
	for pid in "$@"; do kill -9 "$pid" 2>/dev/null; done
}

show() { # $1=日志 $2=标题
	echo "--- $2 ---"
	grep -aE '\[(session|lobby|drive|dir)\]' "$1" | head -12
	local errs
	errs=$(grep -aE 'SCRIPT ERROR|Parse Error|ERROR:' "$1" | head -4)
	[ -n "$errs" ] && { echo "  [报错]"; echo "$errs" | sed 's/^/  /'; }
	echo
}

FAILS=0
note_fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

echo "=========== 1. 目录与认领 ==========="
if ! curl -s "http://$HOST:$DIR_PORT/health" | grep -q true; then
	echo "目录在 $HOST:$DIR_PORT 上没有应答，先确认 moltenfrost-directory 在跑"
	exit 1
fi
echo "OK: 目录存活"

# **玩家打开界面时列表必须是空的**（或只有别人正在玩的房间）。
# 池里那间备用房不该出现在这里——那正是"一开始就看到房间"的根源。
public_now=$(listing)
echo "  公开列表（应当看不到空房）：$public_now"
if echo "$public_now" | grep -q '"players": 0'; then
	note_fail "公开列表里出现了 0 人的房间——空着的备用房不该被列出来"
else
	echo "OK: 公开列表里没有任何空房（玩家打开界面看到的就是这个）"
fi

if [ -z "$ROOM_PORT" ]; then
	# 池要先把备用房拉起来（约 1～2 秒），认领可能先得到 waiting。
	for _ in $(seq 1 30); do
		resp=$(claim)
		ROOM_PORT=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("port", ""))
except Exception: print("")')
		[ -n "$ROOM_PORT" ] && break
		sleep 2
	done
	if [ -z "$ROOM_PORT" ]; then
		note_fail "认领不到房间（60 秒）：$resp\n  看 journalctl -u moltenfrost-pool 与 curl -s http://$HOST:$DIR_PORT/rooms?all=1"
		exit "$FAILS"
	fi
	echo "OK: 向目录认领到房间，端口 $ROOM_PORT（玩家的创建路径）"
else
	echo "（按 ROOM_PORT=$ROOM_PORT 固定用房，跳过认领）"
fi

# 认领之后房间就该**立刻**出现在公开列表里——否则别人看不到。
for _ in $(seq 1 6); do
	[ -n "$(listing | field "$ROOM_PORT" name)" ] && break
	sleep 1
done
echo "目录里与 $ROOM_PORT 有关的那一项："
listing | python3 -c '
import json,sys
port=int(sys.argv[1])
rooms=json.load(sys.stdin)["rooms"]
hit=[r for r in rooms if r["port"]==port]
if not hit:
    print("  （没有这一项！）"); raise SystemExit
r=hit[0]
print("  名=「%s」 地址=%s:%d 人数=%d/%d 状态=%s 可进=%s" % (
    r["name"], r["host"], r["port"], r["players"], r["max"], r["state"], r["joinable"]))
' "$ROOM_PORT"

before_name=$(listing | field "$ROOM_PORT" name)
if [ -n "$before_name" ]; then
	echo "OK: 被认领的房间出现在公开列表里（别人这才看得到）"
else
	note_fail "房间 $ROOM_PORT 认领之后没有出现在列表里（看 journalctl -u moltenfrost-pool）"
fi

echo
echo "=========== 2~4. 两个客户端直连、改名、开局 ==========="
# 从开局那一刻起就在后台持续采目录，直到两个客户端被收掉（见 sampler 的说明）。
sampler "$ROOM_PORT" "$OUT/dir-samples.txt" &
SAMPLER=$!

FIRST=$(join "$OUT/first.log" "--rename=$NEW_NAME")
sleep 4
SECOND=$(join "$OUT/second.log")
sleep 38

kill_all "$FIRST" "$SECOND"
kill "$SAMPLER" 2>/dev/null
wait "$SAMPLER" 2>/dev/null

echo "  局的最后几秒，目录里那一项："
tail -4 "$OUT/dir-samples.txt" | sed 's/^/    /'

# **名字与状态都要看"曾经出现过"**，而不是看某一个时刻：这一项只在局中可见。
played=$(python3 -c '
import sys
want=sys.argv[1]
name_ok=state_ok=False
for line in open(sys.argv[2], encoding="utf-8"):
    parts=line.rstrip("\n").split("|")
    if len(parts) != 3:
        continue
    name, state, _players=parts
    if name == want:
        name_ok=True
    if state == "playing":
        state_ok=True
print("yes" if (name_ok and state_ok) else "no")
print("name=%s state=%s" % (name_ok, state_ok))
' "$NEW_NAME" "$OUT/dir-samples.txt")
lines=$(printf '%s\n' "$played")
verdict=$(printf '%s' "$lines" | head -1)
detail=$(printf '%s' "$lines" | tail -1)
echo "  采样结论：$detail"

show "$OUT/first.log" "客户端 1（先到）"
show "$OUT/second.log" "客户端 2"

if grep -aq '我是房主' "$OUT/first.log"; then
	echo "OK: 先到的那个成了房主"
else
	note_fail "先到的那个没有成为房主（直连房间里 peer 1 是无头进程，不能当房主）"
fi
if grep -aq '名单：2 人' "$OUT/first.log"; then
	echo "OK: 两人进了同一间房（先到的那端看到 2 人）"
else
	note_fail "两人没有进同一间房，或者名单没下发"
fi
if grep -aq '房主改名' "$OUT/first.log"; then
	echo "OK: 房主发了改名"
else
	note_fail "房主没有发改名（--rename 没生效？）"
fi
pass=0
for f in first second; do
	grep -aq '：通过' "$OUT/$f.log" && pass=$((pass + 1)) || note_fail "$f 没有进关（看它自己的日志）"
done
[ "$pass" = "2" ] && echo "OK: 两端都进了关且各有 2 个角色"

echo
echo "=========== 3. 改名与状态是否传到了目录（UTF-8 跨 HTTP + JSON）==========="
if [ "$verdict" = "yes" ]; then
	echo "OK: 局中目录里那一项变成了房主改的名字，且状态是 playing"
else
	note_fail "局中没看到「改名生效 + playing」同时成立（$detail）——看 $OUT/dir-samples.txt 与房主那一端的日志"
fi

echo
echo "=========== 5. 人走光后池收敛回「只剩备用」 ==========="
# 客户端被 kill 之后房间要等心跳超时才察觉（几秒），然后 players=0，
# 再等认领的保留过期（最长 15 秒）才被当成空闲。
# **这里只看汇总，不看某一号端口**：池会挑"端口最大的空闲房间"收掉，
# 而刚走完一局的那一间恰好就是空闲且端口最大——它被收掉是正常的，
# 换一个号继续当备用也是正常的。端口号会漂，安全组要覆盖整段才不受影响。
for _ in $(seq 1 30); do
	busy_now=$(listing_all | python3 -c '
import json,sys
rooms=json.load(sys.stdin)["rooms"]
print(sum(1 for r in rooms if r["busy"]))')
	[ "$busy_now" = "0" ] && break
	sleep 2
done
public_after=$(listing)
busy_now=$(listing_all | python3 -c '
import json,sys
rooms=json.load(sys.stdin)["rooms"]
print(sum(1 for r in rooms if r["busy"]))')
total=$(listing_all | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rooms"]))')
idle=$(listing_all | python3 -c '
import json,sys
rooms=json.load(sys.stdin)["rooms"]
print(sum(1 for r in rooms if not r["busy"]))')
echo "  公开列表：$public_after"
echo "  池里共 $total 间（忙碌 $busy_now 空闲 $idle）"
if [ "$public_after" = '{"rooms": []}' ]; then
	echo "OK: 没人之后公开列表又变空了（回到玩家打开界面看到的样子）"
else
	note_fail "没人之后公开列表里还有房间：$public_after（空房不该被列出来）"
fi
if [ "$busy_now" = "0" ] && [ "$idle" -ge 1 ]; then
	echo "OK: 池收敛到只有备用房间（没有把玩过的房间堆着不放）"
else
	note_fail "池没有收敛：忙碌 $busy_now 空闲 $idle（看 journalctl -u moltenfrost-pool）"
fi

echo
if [ "$FAILS" = "0" ]; then
	echo "路线 A 端到端验证通过。"
else
	echo "路线 A 端到端验证失败 $FAILS 项（上面带 FAIL 的行）。"
fi
echo "日志：$OUT"
exit "$FAILS"
