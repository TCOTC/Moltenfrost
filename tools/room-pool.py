#!/usr/bin/env python3
"""熔霜 · 房间池管理器

它只做一件事：让服务器上**恰好**有 `非空闲房间数 + --spare` 间房在跑。

    没人玩           → 1 间空房等着（spare 默认 1）
    有人开了一间     → 立刻补上第 2 间备用，别人点「创建」不用等
    又有人开了一间   → 补第 3 间
    人走光           → 多出来的那间被收掉，回到 1 间

## 为什么需要它，而不是"部署时开好 N 间"

房间是**用完就该消失**的东西：玩家打开界面时不该看到一堆没人进的空房，
而"创建公网房间"是玩家的一次点击，服务器必须在那之前把房间准备好，
否则那一次点击要等进程启动（还好几秒）。这两条要求合起来只有一个解：
**永远留一间备用的，其余按需增减**。

## 为什么不需要 root

服务器上的目录与房间本来就以同一个普通用户运行（`server-setup.sh` 里两个单元都是
`User=${USER}`），而游戏端口都在 1024 以上。因此这里直接把 Godot 当**子进程**拉起即可——
不需要 sudoers、不需要一个以 root 跑的组件，也不再需要 `moltenfrost@` 那套模板单元。
（进程隔离这一条没有丢：每间房仍然是一个独立的进程，一间崩了不影响别的。）

## 为什么是"对账"而不是"事件驱动"

每个周期都重新读一遍目录、算一遍"应该有哪几间"，因此这个进程自己崩了重启、
或者房间被外部杀掉，都不会留下错误状态——下一轮就会自己纠正。
事件驱动（谁变了就通知谁）在这里要多维护一份"我以为什么样"的状态，
而那份状态正是会出错的地方。

## 与目录的分工

目录是**唯一的真相来源**：房间在不在、有几个玩家，都由它说。
这里只根据它算出来的数字增减进程，自己不记"上一轮有几间"。
见 tools/room-directory.py 的 `busy()` 与 `GET /rooms?all=1`。

用法（由 server-setup.sh 装成 systemd 单元，不必手工跑）：
    python3 room-pool.py --directory 127.0.0.1:27017 --godot /opt/godot/godot \\
        --repo ~/moltenfrost --advertise moltenfrost-server.mytemos.com
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

# 对账周期（秒）。比目录的 TTL（6 秒）短，这样"房间不见了"最多晚 6 秒被发现，
# 而不是再叠加上一整轮对账。也不要再短：一轮要发一次 HTTP 请求，
# 而这里的变化频率是"玩家进出房间"级别的，秒级足够。
RECONCILE_INTERVAL = 2.0
# 请求目录的超时。目录就在本机，正常是微秒级。
HTTP_TIMEOUT = 3.0
# 请房间自己退出之后等多久（秒）。main.gd 每 0.2 秒看一次哨兵文件，
# 而它收到请求后要走 Net.shutdown_gracefully() 的六轮 poll（约 240 毫秒），
# 因此 8 秒是"绰绰有余"。等到了就不发 SIGTERM（那会让 Godot 立刻退出、
# 不走 _exit_tree，客户端只能等 5 秒心跳超时）。
STOP_GRACE = 8.0


def log(message: str) -> None:
    print("[pool] %s" % message, flush=True)


def stop_file_path_for(port: int) -> str:
    """请房间自己退出的哨兵文件。

    **路径必须与 scripts/main.gd 的 stop_file_path_for() 一致**，两处各写一份是刻意的：
    这里是"请它退出的那一侧"，那边是"收到请求的那一侧"，改一处就要改另一处。
    与 tools/graceful-stop.sh 用的是同一个约定（那个脚本给单房间模式用，
    路径写法与这里相同）。
    """
    return "/tmp/moltenfrost-stop-%d" % port


class Room:
    """一间由本进程拉起的房。"""

    __slots__ = ("port", "proc", "started_at", "_reader")

    def __init__(self, port: int, proc: subprocess.Popen):
        self.port = port
        self.proc = proc
        self.started_at = time.monotonic()
        # 每间房一个线程把它的输出泵出来。不泵的话管道写满之后**房间会卡住**
        # （Godot 的 print 阻塞在 write 上），而现象是"房间起来了但不登记"。
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

    def _pump(self) -> None:
        stream = self.proc.stdout
        if stream is None:
            return
        # 每行带上端口前缀。日志因此汇到池的 journal 里，而 `grep 40001`
        # 就能只看那一间——不需要再为每间房装一个 systemd 单元。
        #
        # **这个循环不能因为一行读不出来就退出。** 线程一死，管道就再也没人读，
        # 缓冲区满了之后房间会阻塞在 write 上，而现象是"房间起来了但什么也不干"。
        # 实测踩到：Windows 上 `text=True` 默认按本地编码（GBK）解码，
        # 而 Godot 输出的是 UTF-8，一行中文日志就把这个线程打死了。
        # 因此这里两层防护：启动时显式指定 utf-8 + errors=replace，循环里再兜一层。
        while True:
            try:
                line = stream.readline()
            except (OSError, ValueError):
                return
            if not line:
                return
            try:
                sys.stdout.write("[room %d] %s" % (self.port, line))
                sys.stdout.flush()
            # **要连 ValueError 一起抓。** 写失败不一定是 IO 错：
            # stdout 的编码装不下这些字符时抛的是 UnicodeEncodeError，它是 ValueError 的子类。
            # 只抓 OSError 的话，一行写不出去就会把这个泵线程打死（见上）。
            except (OSError, ValueError):
                return

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        """请它自己退出；不肯就升级到 SIGTERM、再 SIGKILL。"""
        path = stop_file_path_for(self.port)
        try:
            with open(path, "w") as handle:
                handle.write("stop\n")
        except OSError as err:
            log("无法创建哨兵文件 %s：%s" % (path, err))
        deadline = time.monotonic() + STOP_GRACE
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                break
            time.sleep(0.1)
        else:
            # 没等到它自己退。退化成原来的行为：SIGTERM 会让 Godot 立刻退出，
            # 客户端因此要多等一次心跳超时，但服务总是要停下来的。
            log("房间 %d 没有在 %.0f 秒内自行退出，改发 SIGTERM" % (self.port, STOP_GRACE))
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                log("房间 %d 连 SIGTERM 都没反应，发 SIGKILL" % self.port)
                self.proc.kill()
        try:
            os.unlink(path)
        except OSError:
            pass


class Pool:
    def __init__(self, opts):
        self.opts = opts
        self.base = "http://%s" % opts.directory
        self.rooms: dict[int, Room] = {}
        self.stopping = False
        # 上一轮算出来的非空闲房间数。只用于日志，不参与判断。
        self._busy = 0

    # ---------------------------------------------------------------- 目录

    def fetch(self) -> list | None:
        """问目录现在有哪些房间（**连备用房一起**）。

        失败时返回 None 而不是空列表：这两件事必须分开。"读不到"时若当成
        "一间都没有"，下一轮就会把房间全杀掉再重新拉起——目录重启的那两秒
        会把正在玩的人踢掉。
        """
        url = "%s/rooms?all=1" % self.base
        try:
            with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, OSError, ValueError) as err:
            log("读不到目录（%s）" % err)
            return None
        rooms = payload.get("rooms")
        return rooms if isinstance(rooms, list) else None

    def unregister(self, port: int) -> None:
        """把一间已经死掉的房间从目录里摘掉。

        不摘的话它的登记还要挂到 TTL 到期（最多 6 秒），而那几秒里
        玩家点进那间房只会白等一次连接超时。
        """
        url = "%s/rooms?port=%d" % (self.base, port)
        request = urllib.request.Request(url, method="DELETE")
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT):
                pass
        except (urllib.error.URLError, OSError) as err:
            log("摘不掉 %d 的登记（%s），等 TTL 自己过期" % (port, err))

    # ---------------------------------------------------------------- 进程

    def reap_orphans(self) -> None:
        """清掉上一次遗留的孤儿房间进程。

        为什么需要它：systemd 的默认 KillMode=control-group 会在池停时连子进程
        一起清掉，但那是**通过了 systemd** 的那一条路。池被人 `kill -9`、
        或者整个机器的 cgroup 没管住时，房间会活下来并继续向目录登记——
        而新起的池认不出它们（不是自己的子进程，见 reconcile 里的提示），
        于是每间白占 120 MB、而且永远不跟随人数增减。

        判据是**命令行里同时有本池的工程目录与它在管的目录地址**，因此
        不会误杀别的池或别的用途的 Godot 进程。只有 Linux 上有 pgrep，
        其它平台上这一段直接跳过（开发机就是这么跑的）。
        """
        if not hasattr(os, "getpgid") or os.name != "posix":
            return
        marker = "--directory %s" % self.opts.directory
        try:
            found = subprocess.run(
                ["pgrep", "-f", marker],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            ).stdout.split()
        except (OSError, ValueError):
            return
        victims = [int(pid) for pid in found if pid.isdigit() and int(pid) != os.getpid()]
        if not victims:
            return
        log("清掉 %d 个上一次遗留的房间进程：%s" % (len(victims), victims))
        for pid in victims:
            # 用 SIGTERM 而不是 SIGKILL：它会让 Godot 立刻退出（不走 _exit_tree），
            # 对已经没人的旧房间来说这正好，也不给客户端留下一个"会回来的"幻觉。
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError as err:
                log("清不掉进程 %d（%s）" % (pid, err))

    def free_port(self, taken: set[int]) -> int | None:
        """挑一个可用的端口：从基址往上取最小空闲的。

        从小的往大取、收房间时从大的收起（见 reconcile），房间的端口因此是连续的，
        安全组里那一段也就不会有空洞。
        """
        for offset in range(self.opts.max_rooms):
            port = self.opts.base_port + offset
            if port not in taken:
                return port
        return None

    def start_room(self, port: int) -> bool:
        argv = [
            self.opts.godot, "--headless", "--path", self.opts.repo, "--",
            "--host", "--port", str(port),
            "--directory", self.opts.directory,
            "--max-players", str(self.opts.max_per_room),
            "--lobby",
        ]
        # **`--advertise` 要带上这一间自己的端口**：客户端是直连房间的，
        # 而目录里那一项就指向它。不传的话云服务器上自动探测出来的地址是
        # VPC 私网，登记出去等于把人指向一个到不了的地址。
        if self.opts.advertise:
            argv.append("--advertise")
            argv.append("%s:%d" % (self.opts.advertise, port))
        try:
            proc = subprocess.Popen(
                argv, cwd=self.opts.repo,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                # **必须显式指定编码。** 不给的话 `text=True` 会按本地编码解码，
                # 在 Windows（GBK）上遇到 Godot 的 UTF-8 中文日志就抛 UnicodeDecodeError。
                # errors="replace" 是第二层：网关脚本那些地方宁可看到几个问号，
                # 也不要因为一行日志把整间房的输出泵掉。
                text=True, encoding="utf-8", errors="replace", bufsize=1,
            )
        except OSError as err:
            log("拉不起房间 %d：%s" % (port, err))
            return False
        self.rooms[port] = Room(port, proc)
        log("已拉起房间 %d（非空闲 %d，备用 %d）" % (port, self._busy, self.opts.spare))
        return True

    def reap(self) -> None:
        """收掉已经死掉的子进程，并立刻把它从目录里摘掉。"""
        for port in [p for p, room in self.rooms.items() if not room.alive()]:
            room = self.rooms.pop(port)
            log("房间 %d 自己退了（退出码 %s）" % (port, room.proc.returncode))
            self.unregister(port)

    def stop_all(self) -> None:
        rooms = list(self.rooms.values())
        if not rooms:
            return
        log("正在停 %d 间房…" % len(rooms))
        # 并发地停：一间要等 0.2～8 秒，串起来会让 systemd 的停止超时先到。
        threads = [threading.Thread(target=room.stop) for room in rooms]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.rooms.clear()

    # ---------------------------------------------------------------- 对账

    def reconcile(self) -> None:
        listing = self.fetch()
        self.reap()
        if listing is None:
            # 目录读不到。**什么都不做**：宁可维持现状，也不要因为一次读失败
            # 就把正在玩的房间收掉。
            return

        registered = {}
        for item in listing:
            if isinstance(item, dict) and isinstance(item.get("port"), int):
                registered[item["port"]] = item
        busy = sum(1 for item in registered.values() if item.get("busy"))
        self._busy = busy

        #  **自己拉起的、还活着的进程**也要算进"存在"。少了这一段的话，
        # 刚拉起的房间在它登记上来（约一两秒）之前会被当成不存在，
        # 于是每一轮都重复拉起一间，直到端口段被这种重复占满。
        alive = set(registered)
        for port, room in self.rooms.items():
            if room.alive():
                alive.add(port)

        desired = min(busy + self.opts.spare, self.opts.max_rooms)
        if len(alive) < desired:
            port = self.free_port(alive)
            if port is None:
                log("端口段已满（%d 间），无法再补备用房" % self.opts.max_rooms)
                return
            log("非空闲 %d，应有 %d 间，现在 %d 间 → 补一间" % (busy, desired, len(alive)))
            self.start_room(port)
            return
        if len(alive) > desired:
            # **只收空闲的那几间，而且从端口最大的收起。** 收掉有人玩的房间等于
            # 把人踢下线；而"留着小的、收掉大的"能让剩下的端口保持连续。
            idle_ports = sorted(
                (p for p, item in registered.items() if not item.get("busy")),
                reverse=True,
            )
            if not idle_ports:
                log("非空闲 %d，应有 %d 间，现在 %d 间，但没有空闲的可收" % (busy, desired, len(alive)))
                return
            for port in idle_ports[: len(alive) - desired]:
                room = self.rooms.get(port)
                if room is None:
                    # 不是我们拉起来的（上一个 incarnation 留下的）。
                    # 能做的只是记一行——未来若要接管它，得先能认出它。
                    log("房间 %d 不是本进程拉起的，不主动收它" % port)
                    continue
                log("非空闲 %d，应有 %d 间，现在 %d 间 → 收掉空闲的 %d" % (
                    busy, desired, len(alive), port))
                room.stop()
                self.rooms.pop(port, None)
                self.unregister(port)

    def run(self) -> None:
        log("房间池启动：目录 %s，端口 %d..%d，备用 %d 间，每房 %d 人" % (
            self.opts.directory, self.opts.base_port,
            self.opts.base_port + self.opts.max_rooms - 1,
            self.opts.spare, self.opts.max_per_room))
        if not self.opts.advertise:
            log("**没有给 --advertise**：房间会用自己探测到的地址登记，"
                "云服务器上那是 VPC 私网地址，玩家连不上")
        self.reap_orphans()
        while not self.stopping:
            try:
                self.reconcile()
            except Exception as err:  # noqa: BLE001 - 这一层就是要兜住所有意外
                # 对账里任何一处抛异常都不该让池停摆：下一轮重新读一遍就好了。
                log("这一轮对账出错（%s），下一轮重来" % err)
            for _ in range(int(RECONCILE_INTERVAL * 10)):
                if self.stopping:
                    break
                time.sleep(0.1)
        self.stop_all()
        log("房间池已停止")

    def request_stop(self, _signum, _frame) -> None:
        # 收到 SIGTERM 只置一个标记，真正的收尾交给 run() 里那个循环做。
        # 直接在信号处理里干活容易在 sleep/IO 中间被再次打断。
        self.stopping = True


def main() -> int:
    # **把自己的输出钉成 UTF-8。** 房间的日志是 UTF-8（Godot 的输出），而这个进程的
    # stdout 编码取决于环境：Linux 上一般是 UTF-8，Windows 控制台默认是 GBK，
    # 那时一行中文日志就会把输出泵线程打死（而现象是"房间起来了但日志断了"）。
    # errors="replace" 是第二层：宁可看到几个问号，也不要因为一行日志丢掉整间房的输出。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError, ValueError):
            pass

    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", default="127.0.0.1:27017",
                        help="房间目录的 HOST:PORT")
    parser.add_argument("--godot", default="/opt/godot/godot", help="Godot 二进制")
    parser.add_argument("--repo", default=os.path.expanduser("~/moltenfrost"),
                        help="工程目录")
    parser.add_argument("--base-port", type=int, default=40001, help="房间端口段的起点")
    parser.add_argument("--max-rooms", type=int, default=8, help="最多同时几间房")
    parser.add_argument("--spare", type=int, default=1,
                        help="始终比非空闲房间多留几间备用（默认 1）")
    parser.add_argument("--max-per-room", type=int, default=2, help="每间房几个人")
    parser.add_argument("--advertise", default="",
                        help="房间登记时对外报的地址（云服务器上必须给，见下）")
    args = parser.parse_args()

    pool = Pool(args)
    signal.signal(signal.SIGTERM, pool.request_stop)
    signal.signal(signal.SIGINT, pool.request_stop)
    pool.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
