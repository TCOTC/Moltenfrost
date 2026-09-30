#!/usr/bin/env python3
"""熔霜 · 房间目录服务

它只干两件事，没有别的：**登记房间**、**回答"现在有哪些房间"**。
客户端拿到列表后**直接连那间房的地址**，数据不再经过这里。
（这是 docs/公网房间方案.md 的路线 A：房间直连 + 目录。为什么选它见那份文档。）

## 为什么是 HTTP 而不是延续那个 UDP 网关的协议

- 没有协议要设计：请求与响应都是 JSON，`GET` 一条就够
- **`curl` 就能验**，不必先写一个客户端；这个工具的存在感因此降到最低
- 目录是请求-响应式的、允许几百毫秒的延迟，不需要 UDP 的实时性
- 以后想加 TLS 与限流，放到 Cloudflare 后面即可（走 HTTP 才行）

只用标准库（`http.server`），因此服务器上不需要装任何东西。

## 接口

    POST /rooms        登记或刷新一间房
                       body: {"name": "...", "port": N, "players": N, "max": N,
                              "state": "waiting"|"playing", "host": "可省略"}
                       返回 {"ok": true, "host": "<生效的地址>", "port": N}
    POST /rooms/claim  向目录要一间空房（玩家的「创建公网房间」走这条）
                       返回 {"ok": true, "host": ..., "port": N}，或者
                            {"ok": false, "waiting": true}（正忙着补上一间，稍后再试）
    DELETE /rooms?port=N   注销（正常退出时发；不发也行，靠 TTL 清掉）
    GET  /rooms        列表。**只列非空闲的房间**（见下）
                       返回 {"rooms": [{"name","host","port","players","max","state","age"}]}
    GET  /rooms?all=1  连备用房间也列出来。**只对内网来源开放**，是给房间池管理器
                       （tools/room-pool.py，与房间同机）对账用的
    GET  /health       给监控与部署脚本看的存活探针

## 四个刻意的取舍

**0. 空着的房间不出现在列表里，要用就得「认领」。**
服务器上总有一间没人玩的空房备着（见 tools/room-pool.py），而玩家要的是
「打开界面看不到房间 → 自己创建一间 → 别人才能看到」。因此：

- `GET /rooms` 只列**非空闲**的房间（有人，或刚被人认领）
- 「创建公网房间」走 `POST /rooms/claim`：目录**原子地**挑一间空房交给它，
  并为它保留 `--claim-ttl` 秒

那个保留值是必需的：两个人同时点「创建」时，若不保留，两人会拿到同一间房
（房间在 2 秒内还没报上人数），于是第二个人以为自己建了房、实际成了客人。
保留只需撑过那段窗口，房间一报上 `players > 0` 就自动清了它。

**1. 地址以来源 IP 为准，不信请求体里的 host。**
请求体里那个 `host` 只有在来源是内网/环回时才采信（房间与目录同机时就是这个情况，
它自己也不知道对外的地址，只能由部署时用 --advertise 告诉它）。
来自公网的登记一律把 host 改写成来源地址——否则任何人都能登记一条指向别人 IP 的
"房间"，把我们的玩家变成往那台机器打 UDP 的流量。

**2. 靠 TTL 清理，不靠注销。**
房间每 `--ttl/3` 秒刷新一次，超过 `--ttl` 秒没消息就从列表里消失。
进程被强杀、机器掉电时不会有"再见"，只能由这里清理。局域网探测的那套
（定期广播 + 超时移除）已经在真机上验证过，这里沿用同一种做法。

**3. 名字只做长度与控制字符的约束，不做内容审核。**
名字是玩家输入、会展示给陌生人看，因此必须挡住控制字符（它们能让终端与日志错乱）
并限长（否则一条几兆的名字会把列表撑坏）。UTF-8 本身没问题——JSON 与 HTTP 都是字节透明的。

用法：
    python3 room-directory.py --port 27017 [--ttl 6] [--max-rooms 64] [--claim-ttl 15] [--verbose]
    python3 room-directory.py --selftest        # 只验判断逻辑，不启服务
"""

import argparse
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# 房间名的最长字符数。按**字符**而不是字节算：中文一个字三字节，
# 按字节限长会让中文名只能写三分之一。前端（GDScript 的 LineEdit）也限同一个数。
NAME_MAX_CHARS = 24
# 「认领」的保留时长（秒）。两个人同时点「创建」时，第一个人把房间拿走，
# 第二个要拿到**另一间**；而房间要等 2 秒才会报上 players>0，这段窗口只能靠保留填。
# 取 15 秒是「绰绰有余」：正常连接只要一秒，真没连上也不该把房间占太久。
CLAIM_TTL = 15.0
# 控制字符。它们会污染日志与终端，而且列表里显示出来是一堆看不见的方块。
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")


def clean_name(raw) -> str:
    """房间名的清洗。返回的一定是可安全打印、可安全放进 JSON 的字符串。"""
    if not isinstance(raw, str):
        return ""
    # 先去掉控制字符再截断：反过来的话，截断可能刚好把一个多字节字符切开。
    text = CONTROL_CHARS.sub("", raw).strip()
    if len(text) > NAME_MAX_CHARS:
        text = text[:NAME_MAX_CHARS]
    return text


def clamp_int(raw, low: int, high: int, fallback: int) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return fallback
    return max(low, min(high, value))


def is_local_source(addr: str) -> bool:
    """来源是不是本机/内网。判据与 scripts/main.gd 里挑局域网地址的那套一致。

    它只影响一件事：**要不要采信请求体里的 host**。同机部署时房间从环回连过来，
    它报的 host 是部署时用 --advertise 给的（它自己不可能知道对外的地址，
    云服务器网卡上只有 VPC 私网地址）；而公网来源报什么都不可信。

    注意内网地址也归入“可信”：能从这个网段发请求的人已经在你的内网里了，
    那时候要担心的远不止房间列表。
    """
    if addr.startswith("127.") or addr.startswith("10.") or addr == "::1" or addr == "localhost":
        return True
    if addr.startswith("192.168."):
        return True
    if addr.startswith("172."):
        second = addr.split(".")
        if len(second) > 1 and second[1].isdigit():
            return 16 <= int(second[1]) <= 31
    return False


class Room:
    __slots__ = ("name", "host", "port", "players", "max_players", "state", "seen",
                 "reserved_until")

    def __init__(self, name, host, port, players, max_players, state):
        self.name = name
        self.host = host
        self.port = port
        self.players = players
        self.max_players = max_players
        self.state = state
        self.seen = time.monotonic()
        # 被认领之后保留到什么时候。见 CLAIM_TTL。
        self.reserved_until = 0.0

    def key(self):
        return (self.host, self.port)

    def busy(self) -> bool:
        """有人在玩，或者有人正要来。

        **空着的房间是「备用」，不算这里数的东西。** 它不出现在列表里
        （**不想让玩家看到一堆没人进的空房**），别人要进它只能通过认领。
        这也正是 room-pool.py 算「要开几间」的依据：
        `非空闲数 + 备用数`。
        """
        return self.players > 0 or self.reserved_until > time.monotonic()

    def as_dict(self):
        return {
            "name": self.name,
            "host": self.host,
            "port": self.port,
            "players": self.players,
            "max": self.max_players,
            "state": self.state,
            "age": round(time.monotonic() - self.seen, 1),
            # 对账用。界面上不看这个字段（它拿到的是已经滤过的列表）。
            "busy": self.busy(),
        }

    def findable(self) -> bool:
        """能不能被玩家选中：还可以再进人。

        这一条**比人数本身更重要**：本作是双人协作，一个已经开始的房间不该出现在
        列表里让人半路插进去（会顶掉原来那个人）。界面上会显示"进行中"，但目录
        也把判据给出来，免得每个使用方各写一份。

        没做密码与好友机制（明确不做），所以"还在等"就是唯一能挡住陌生人的东西。
        """
        return self.state == "waiting" and self.players < self.max_players


class Directory:
    def __init__(self, ttl: float, max_rooms: int, verbose: bool,
                 claim_ttl: float = CLAIM_TTL):
        self.ttl = ttl
        self.max_rooms = max_rooms
        self.verbose = verbose
        self.claim_ttl = claim_ttl
        self.lock = threading.Lock()
        self.rooms = {}

    def log(self, message: str) -> None:
        if self.verbose:
            print("[dir] %s" % message, flush=True)

    def register(self, body: dict, source_addr: str) -> dict:
        name = clean_name(body.get("name"))
        port = clamp_int(body.get("port"), 1, 65535, 0)
        if port == 0:
            return {"ok": False, "error": "port is required"}
        reported_host = body.get("host")
        if isinstance(reported_host, str) and reported_host.strip() and is_local_source(source_addr):
            # 房间与目录同机（正常部署就是这样）：它报的 host 是部署时用 --advertise 给的，
            # 采信它。它自己不可能知道对外的地址（云服务器上网卡只有 VPC 私网地址）。
            host = reported_host.strip()
        else:
            # 来自公网的登记：**以来源地址为准**，忽略它说的 host。理由见文件头。
            host = source_addr
        players = clamp_int(body.get("players"), 0, 4096, 1)
        max_players = clamp_int(body.get("max"), 1, 4096, 2)
        state = "playing" if body.get("state") == "playing" else "waiting"
        # 名字为空时的兜底。**带上端口**：同一台主机上可能同时开着好几间房（见
        # docs/公网房间方案.md 的路线 A），而它们的地址是同一个域名，若都叫同一个
        # 名字，列表里就是几条一字不差的行，看着像列表重复了同一个条目。
        # 正常部署下房间总会报一个名字，走到这里说明登记方有问题，所以它只是兜底。
        room = Room(name or "房间 %d" % port, host, port, players, max_players, state)
        with self.lock:
            key = room.key()
            if key not in self.rooms and len(self.rooms) >= self.max_rooms:
                return {"ok": False, "error": "too many rooms"}
            # **已有的房间要就地更新，不能整个换掉。** 认领的保留值存在对象上，
            # 而房间每 2 秒就登记一次——换对象等于每 2 秒把保留清一次，
            # 于是「同时点创建会拿到同一间房」重新出现，且只在那一瞬才复现。
            existing = self.rooms.get(key)
            if existing is not None:
                room.reserved_until = existing.reserved_until
                if players > 0:
                    # 人已经进来了，认领的使命完成，不必再占着（否则玩家刚进去又退出来时，
                    # 这间房要继续被"保留"十几秒，而那段时间里谁也拿不到它）。
                    room.reserved_until = 0.0
            self.rooms[key] = room
            count = len(self.rooms)
        self.log("register %s:%d %r players=%d/%d %s (total %d)" % (
            host, port, room.name, players, max_players, state, count))
        return {"ok": True, "host": host, "port": port}

    def unregister(self, port: int) -> dict:
        with self.lock:
            for key in [k for k in self.rooms if k[1] == port]:
                del self.rooms[key]
        self.log("unregister port %d" % port)
        return {"ok": True}

    def claim(self) -> dict:
        """把一间**空着的**房间交出去，并为一小段时间保留它。玩家的「创建公网房间」走这条。

        为什么不能像原来那样"从列表里挑一间 players=0 的"：列表里现在根本没有空房
        （它们被滤掉了，见 busy()）。而对账也需要它是**原子**的——两个人同时点创建时
        必须拿到两间不同的房，而不是同一间。
        """
        now = time.monotonic()
        with self.lock:
            self._expire(now)
            candidates = [r for r in self.rooms.values() if not r.busy()]
            if not candidates:
                # 池管理器正在补上一间（或者一间都没起来）。不是错误，是"请稍等"。
                return {"ok": False, "waiting": True}
            # 取端口最小的那间：可预测，而且收房间时总是从大的收起（见 room-pool.py）。
            room = min(candidates, key=lambda r: r.port)
            room.reserved_until = now + self.claim_ttl
        self.log("claim %s:%d (reserved %.0fs)" % (room.host, room.port, self.claim_ttl))
        return {"ok": True, "host": room.host, "port": room.port, "name": room.name}

    def _expire(self, now: float) -> None:
        """清掉超时没登记的。调用方必须已持有锁。

        放在读路径上而不是单独的定时器线程：读列表是最频繁的操作，
        而"读到已经不存在的房间"恰恰是这里唯一不能出的错。
        """
        for key in [k for k, r in self.rooms.items() if now - r.seen > self.ttl]:
            del self.rooms[key]
            self.log("expired %s:%d" % key)

    def listing(self, include_idle: bool = False) -> dict:
        """列表。默认只给**非空闲**的房间，见 busy()。

        `include_idle=True` 是给房间池管理器对账用的（它要看到备用房才能算出
        "现在有几间在跑"），因此那条路径在 HTTP 层限了来源。
        """
        now = time.monotonic()
        with self.lock:
            self._expire(now)
            rooms = list(self.rooms.values())
        if not include_idle:
            rooms = [r for r in rooms if r.busy()]
        items = [r.as_dict() for r in rooms]
        # 排一下序：先能进的，再按人数多的在前（凑人优先），最后按端口稳定化。
        # 不排序的话顺序取决于字典，列表会每次都跳。
        items.sort(key=lambda r: (not (r["state"] == "waiting" and r["players"] < r["max"]),
                                  -r["players"], r["port"]))
        for item in items:
            item["joinable"] = item["state"] == "waiting" and item["players"] < item["max"]
        return {"rooms": items}


def make_handler(directory: Directory):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MoltenfrostDirectory/1"

        # 默认的实现会把每个请求打到 stderr，而 systemd 下那就是 journal。
        # 只留一行自己控制的、可读的日志。
        def log_message(self, fmt, *args):
            if directory.verbose:
                sys.stderr.write("[http] %s - %s\n" % (self.address_string(), fmt % args))

        def _send(self, code: int, payload: dict) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _read_json(self) -> dict:
            length = clamp_int(self.headers.get("Content-Length"), 0, 1 << 20, 0)
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                body = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return {}
            return body if isinstance(body, dict) else {}

        def do_GET(self):
            route = urlparse(self.path)
            if route.path == "/rooms":
                # `all=1` 会把备用（空着的）房间也列出来。**只对内网来源开放**：
                # 它是给同机的房间池管理器对账用的，而对外暴露备用房等于把
                # "认领"这一步绕过去——两个客户端可能各自直连同一间空房。
                # 判据与"采信 host"那一条共用，见 is_local_source()。
                params = parse_qs(route.query)
                want_all = (params.get("all") or ["0"])[0] not in ("", "0")
                include_idle = want_all and is_local_source(self.client_address[0])
                self._send(200, directory.listing(include_idle))
            elif route.path == "/health":
                self._send(200, {"ok": True})
            else:
                self._send(404, {"ok": False, "error": "unknown path"})

        def do_POST(self):
            route = urlparse(self.path).path
            if route == "/rooms/claim":
                result = directory.claim()
                # `waiting` 不是错误，是"正忙着补一间，稍后再试"，因此给 200：
                # 把正常的等待当成错误会让客户端与日志都去追一个不存在的问题。
                self._send(200, result)
                return
            if route != "/rooms":
                self._send(404, {"ok": False, "error": "unknown path"})
                return
            result = directory.register(self._read_json(), self.client_address[0])
            self._send(200 if result.get("ok") else 400, result)

        def do_DELETE(self):
            route = urlparse(self.path)
            if route.path != "/rooms":
                self._send(404, {"ok": False, "error": "unknown path"})
                return
            params = parse_qs(route.query)
            port = clamp_int((params.get("port") or ["0"])[0], 0, 65535, 0)
            self._send(200, directory.unregister(port))

    return Handler


def run_selftest() -> int:
    """不启服务、只验判断逻辑。**把安全那一条变成可断言的检查**，
    而不是靠 curl 目测——目测那次就验错了对象（拿内网地址当公网地址试）。

    跑：python3 room-directory.py --selftest
    它是纯函数与内存对象，不碰网络与磁盘。
    """
    failures = []
    checks = [0]

    def ok(condition, message):
        checks[0] += 1
        if not condition:
            failures.append(message)

    # --- 名字的清洗 ---
    ok(clean_name("  名字  ") == "名字", "首尾空白应当去掉，得到 %r" % clean_name("  名字  "))
    ok(clean_name("a\x00b\x1bc") == "abc", "控制字符应当去掉，得到 %r" % clean_name("a\x00b\x1bc"))
    ok(len(clean_name("长" * 100)) == NAME_MAX_CHARS, "超长应当截到 %d 个字符" % NAME_MAX_CHARS)
    ok(clean_name(None) == "" and clean_name(123) == "", "非字符串应当当成空")
    ok(clean_name("熔霜") == "熔霜", "中文应当原样保留")

    # --- 数值的限幅 ---
    ok(clamp_int("7", 0, 10, -1) == 7, "数字字符串应当被接受")
    ok(clamp_int("abc", 0, 10, -1) == -1, "非数字应当回退")
    ok(clamp_int(99, 0, 10, -1) == 10, "超上限应当夹住")
    ok(clamp_int(-5, 0, 10, -1) == 0, "超下限应当夹住")

    # --- 来源的判定 ---
    for addr in ("127.0.0.1", "10.1.2.3", "192.168.5.9", "172.16.0.17", "172.31.255.1", "::1"):
        ok(is_local_source(addr), "%s 应当算内网" % addr)
    for addr in ("203.0.113.5", "8.8.8.8", "172.32.0.1", "172.15.0.1", "1.2.3.4"):
        ok(not is_local_source(addr), "%s 应当算公网" % addr)

    # --- 安全：公网来源不得谎报 host（本次自检的主要存在理由）---
    directory = Directory(ttl=6.0, max_rooms=8, verbose=False)
    spoof = {"name": "谎报房", "host": "1.2.3.4", "port": 40005,
             "players": 1, "max": 2, "state": "waiting"}
    result = directory.register(dict(spoof), "203.0.113.5")
    ok(result.get("host") == "203.0.113.5", "公网来源的 host 应当被改写成来源地址，得到 %r" % result.get("host"))
    listed = {r["port"]: r for r in directory.listing()["rooms"]}
    ok(listed[40005]["host"] == "203.0.113.5", "列表里也应当是来源地址")

    # --- 同机（环回）则采信它报的 host ---
    local = directory.register(dict(spoof, port=40006, host="moltenfrost-server.mytemos.com"), "127.0.0.1")
    ok(local.get("host") == "moltenfrost-server.mytemos.com",
       "环回来源应当采信 --advertise 给的地址，得到 %r" % local.get("host"))

    # --- 缺端口与超上限 ---
    ok(not directory.register({"name": "x"}, "127.0.0.1").get("ok"), "缺 port 应当被拒")
    small = Directory(ttl=6.0, max_rooms=1, verbose=False)
    ok(small.register({"port": 1}, "127.0.0.1").get("ok"), "第一间应当登记成功")
    ok(not small.register({"port": 2}, "127.0.0.1").get("ok"), "超过上限应当被拒")
    ok(small.register({"port": 1}, "127.0.0.1").get("ok"), "已存在的房间刷新不应被上限拦住")

    # --- 没有名字的房间要能被区分开 ---
    # 同一台主机上的几间空房只差端口，名字若一样，列表里就是两条一模一样的行。
    # 这里刻意用 players=0（真实的备用房就是这个样子），因此要看 all=1 那份列表。
    nameless = Directory(ttl=6.0, max_rooms=8, verbose=False)
    for bare_port in (40001, 40002):
        nameless.register({"port": bare_port, "players": 0, "host": "mf.example.com"}, "127.0.0.1")
    blank = {r["port"]: r["name"] for r in nameless.listing(include_idle=True)["rooms"]}
    ok(blank[40001] != blank[40002],
       "同一主机上的无名字房间不应当重名，得到 %r / %r" % (blank[40001], blank[40002]))
    ok("40001" in blank[40001], "兜底名字应当带上端口，得到 %r" % blank[40001])

    # --- 空着的房间不列出，但能被认领领走 ---
    # 这三条是「打开界面看到的是空的，创建一间之后别人才看得到」的全部依据。
    pool = Directory(ttl=6.0, max_rooms=8, verbose=False)
    for spare in (40001, 40002, 40003):
        pool.register({"port": spare, "players": 0, "host": "mf.example.com"}, "127.0.0.1")
    ok(pool.listing()["rooms"] == [], "空着的房间不应当出现在默认列表里")
    ok(len(pool.listing(include_idle=True)["rooms"]) == 3, "all=1 应当能看到备用房（对账用）")

    first = pool.claim()
    ok(first.get("ok") and first.get("port") == 40001,
       "认领应当给出端口最小的那间，得到 %r" % first)
    after = {r["port"] for r in pool.listing()["rooms"]}
    ok(after == {40001}, "被认领的房间应当立刻出现在默认列表里，得到 %r" % after)

    # **同时点「创建」的两个人必须拿到两间房。** 房间要等 2 秒才会报上 players>0，
    # 没有保留值的话两次认领会拿到同一间，第二个人以为自己建了房、实际成了客人。
    second = pool.claim()
    ok(second.get("ok") and second.get("port") == 40002,
       "第二次认领应当拿到另一间，得到 %r" % second)

    # 人真进来了就清掉保留：否则刚进去又退出来时，这间房还要被白占十几秒。
    pool.register({"port": 40001, "players": 1, "host": "mf.example.com"}, "127.0.0.1")
    still_listed = {r["port"] for r in pool.listing()["rooms"]}
    ok(still_listed == {40001, 40002}, "有人在玩的房间应当继续列出，得到 %r" % still_listed)
    pool.register({"port": 40001, "players": 0, "host": "mf.example.com"}, "127.0.0.1")
    ok(all(r["port"] != 40001 for r in pool.listing()["rooms"]),
       "人走光且保留已清时，房间应当从列表里消失")

    # 三间都被认领/占用时，认领只能回答“稍等”，而不是错误。
    # 此时 40001 已经空闲（上面把保留清了），因此先把它领回来，再领 40003。
    again = pool.claim()
    ok(again.get("port") == 40001, "玩家走光之后那间房应当能被再次领走，得到 %r" % again)
    pool.claim()
    waiting = pool.claim()
    ok(not waiting.get("ok") and waiting.get("waiting"),
       "没有空房时应当回答 waiting 而不是报错，得到 %r" % waiting)

    # --- 注销与可进性 ---
    ok(directory.unregister(40005).get("ok"), "注销应当成功")
    ok(all(r["port"] != 40005 for r in directory.listing()["rooms"]), "注销之后不应还在列表里")
    full = directory.register({"port": 40007, "players": 2, "max": 2}, "127.0.0.1")
    ok(full.get("ok"), "满员房也应当能登记（列表要显示它，只是不可进）")
    rooms = {r["port"]: r for r in directory.listing()["rooms"]}
    ok(not rooms[40007]["joinable"], "满员房不应当标为可进")
    playing = directory.register({"port": 40008, "players": 1, "max": 2, "state": "playing"}, "127.0.0.1")
    ok(playing.get("ok"), "进行中的房也应当能登记")
    rooms = {r["port"]: r for r in directory.listing()["rooms"]}
    ok(not rooms[40008]["joinable"], "进行中的房不应当标为可进（否则陌生人会顶掉原来的人）")

    if failures:
        print("房间目录自检失败：")
        for line in failures:
            print("  -- %s" % line)
        return 1
    print("房间目录自检通过（%d 项断言）。" % checks[0])
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=27017, help="监听端口（TCP）")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--ttl", type=float, default=6.0,
                        help="多久没刷新就从列表里移除（秒）。房间按它的三分之一刷新")
    parser.add_argument("--max-rooms", type=int, default=64)
    parser.add_argument("--claim-ttl", type=float, default=CLAIM_TTL,
                        help="认领之后保留多少秒（见 CLAIM_TTL）")
    parser.add_argument("--verbose", action="store_true", help="把每次登记/过期都打出来")
    parser.add_argument("--selftest", action="store_true", help="只跑判断逻辑的自检，不启服务")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()

    directory = Directory(args.ttl, args.max_rooms, args.verbose, args.claim_ttl)
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(directory))
    print("[dir] listening %d (ttl %.0fs, max %d rooms, claim ttl %.0fs)" % (
        args.port, args.ttl, args.max_rooms, args.claim_ttl), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
