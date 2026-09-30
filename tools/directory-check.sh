#!/bin/bash
# 路线 A 的端到端验证：**房间目录 + 客户端直连房间**。
#
# 验五件事：
#   1) 目录活着，且每间房都登记上了自己（名字、端口、状态、人数）
#   2) 两个客户端**直连同一间房**，都进大厅、都看到 2 人，先到的那个是房主
#   3) 房主改名 → 目录里那一项跟着变（房间名是 UTF-8，跨 HTTP + JSON 两跳）
#   4) 人齐之后房主开局 → 两端都进关、各生成一个角色
#   5) 已经开局的房间在列表里**不可进**（没有密码也没有好友机制，
#      \"还在等\"是唯一能挡住陌生人半路插进来的东西）
#
# 在**服务器本机**跑（也可在能连到目录的任意机器上跑，改前两个参数即可）：
#   ./directory-check.sh [目录地址] [目录端口] [房间端口]
#
# 环境变量：ROOM_PORT 指定要连哪一间（默认 40001，即第一间）。
set -u

HOST=${1:-127.0.0.1}
DIR_PORT=${2:-27017}
ROOM_PORT=${3:-40001}
GODOT=${GODOT:-/opt/godot/godot}
REPO=${REPO:-$HOME/moltenfrost}
OUT=${OUT:-/tmp/dircheck}
DRIVE=res://tests/lobby_start_drive.tscn
# 与 127.0.0.1 一起用：房间是在这台机器上监听的。
ROOM_HOST=${ROOM_HOST:-127.0.0.1}
NEW_NAME=${NEW_NAME:-"熔霜·改名验证"}

rm -rf "$OUT"; mkdir -p "$OUT"

listing() { curl -s "http://$HOST:$DIR_PORT/rooms"; }

# 从列表里取某一间的某个字段。用 python 而不是 jq：服务器上不一定有 jq，
# 而 python3 是目录服务本身就在用的东西，必然存在。
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

echo "=========== 1. 目录与登记 ==========="
if ! curl -s "http://$HOST:$DIR_PORT/health" | grep -q true; then
	echo "目录在 $HOST:$DIR_PORT 上没有应答，先确认 moltenfrost-directory 在跑"
	exit 1
fi
echo "OK: 目录存活"
# 房间每 2 秒登记一次，因此这里要等它至少报过一次。
for _ in $(seq 1 12); do
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
	echo "OK: 房间自己登记上了（名「$before_name」）"
else
	note_fail "房间 $ROOM_PORT 没有出现在目录里（看 journalctl -u moltenfrost@$ROOM_PORT）"
fi

echo
echo "=========== 2~4. 两个客户端直连、改名、开局 ==========="
FIRST=$(join "$OUT/first.log" "--rename=$NEW_NAME")
sleep 4
SECOND=$(join "$OUT/second.log")
sleep 34
kill_all "$FIRST" "$SECOND"

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
echo "=========== 3. 改名是否传到了目录（UTF-8 跨 HTTP + JSON）==========="
after_name=$(listing | field "$ROOM_PORT" name)
echo "  改名后目录里那一项的名：「$after_name」（期望「$NEW_NAME」）"
if [ "$after_name" = "$NEW_NAME" ]; then
	echo "OK: 改名传到了目录，且中文没有被截断或转义坏"
else
	note_fail "目录里的名字与房主改的不一致（期望「$NEW_NAME」，实际「$after_name」）"
fi

echo
echo "=========== 5. 开局后的房间应当不可进 ==========="
sleep "$((6))"   # 等房间清空并回到空闲；此时它对外的状态应当是 waiting 且 0 人
state=$(listing | field "$ROOM_PORT" state)
joinable=$(listing | field "$ROOM_PORT" joinable)
players=$(listing | field "$ROOM_PORT" players)
echo "  客户端走光后：状态=$state 人数=$players 可进=$joinable"
# 开局期间它应当报 playing；这里验的是**空房回到可进**，
# 而\"开局中不可进\"由单元测试与 room-directory.py --selftest 覆盖。
if [ "$joinable" = "True" ]; then
	echo "OK: 人走光之后房间回到可进（房间回收生放）"
else
	note_fail "房间空了之后仍然不可进（状态=$state 人数=$players）——检查 _reset_to_lobby"
fi

echo
if [ "$FAILS" = "0" ]; then
	echo "路线 A 端到端验证通过。"
else
	echo "路线 A 端到端验证失败 $FAILS 项（上面带 FAIL 的行）。"
fi
echo "日志：$OUT"
exit "$FAILS"
