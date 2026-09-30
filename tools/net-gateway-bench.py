#!/usr/bin/env python3
"""熔霜 · UDP 网关对比探针

用来回答一个问题：**在客户端与房间之间插一个用户态转发器，代价是多少。**
三个实现（tools/net-gateway.py / .c / .go）共用同一套命令行契约，因此这一个探针
就能驱动它们三个，并且能与"不经网关直连"的基线对照。

## 拓扑

        客户端(本探针) ──▶ 被测对象 ──▶ 回声房间
                                       （把收到的原样送回）
基线（--label direct）里没有"被测对象"这一层，客户端直接对回声房间说话。

## 为什么两端都是本进程起的、而且都绑环回

要测的是**转发器的开销**，不是物理网络的抖动。环回上没有任何链路噪声，
因此测出来的差值就只是转发本身花的钱。两台真机之间的 RTT 会被链路抖动淹没到看不出来
（实测抖动 17～100 ms，而这里要分辨的是几十微秒）。

## 报告什么

- RTT 的 p50 / p90 / p99 / p99.9 / max：**均值没有意义，尾延迟才有**。
  转发器在延迟关键路径上，一次调度抖动就是玩家能感觉到的一次卡顿。
- 与直连基线的差值：绝对 RTT 里有一大半是探针自己与回声房间的开销，两者都有，
  相减之后剩下的才是"插入网关"的净代价。
- 被测进程的 CPU（每千包多少毫秒）：在只有 2 核的部署机上，这比延迟更能说明能开几局。
- 丢包：环回上不该丢包，丢了说明缓冲区不够或实现有 bug。

## 用法

    # 基线：不经网关
    python3 net-gateway-bench.py --label direct
    # 网关（先编译：gcc -O2 -o build/net-gateway tools/net-gateway.c）
    python3 net-gateway-bench.py --label gateway --gateway build/net-gateway
    # 吞吐那一档
    python3 net-gateway-bench.py --label gateway --gateway build/net-gateway --phase blast

每次运行输出一行 `[bench] ...`，便于多次运行后直接比对。
"""

import argparse
import os
import select
import shlex
import socket
import struct
import subprocess
import sys
import time

# 每包 64 字节。ENet 的同步包实测在 30～60 字节，取 64 是个略偏保守的近似。
PKT_SIZE = 64
SOCK_BUF = 1 << 20


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0.0
    index = int(round((len(sorted_values) - 1) * fraction))
    return sorted_values[index]


# ---------------------------------------------------------------- 回声房间

def run_echo(pin: int) -> int:
    """把收到的数据报原样送回，越简单越好：这个进程不能成为测量里的变量。

    用阻塞 recvfrom 的死循环，不用 select：省掉一次系统调用，
    也避免把唤醒延迟算进被测对象的账上。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCK_BUF)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCK_BUF)
    sock.bind(("127.0.0.1", 0))
    if pin >= 0:
        try:
            os.sched_setaffinity(0, {pin})
        except OSError:
            pass
    print("[echo] listening %d" % sock.getsockname()[1], flush=True)
    buf = bytearray(65536)
    view = memoryview(buf)
    while True:
        size, addr = sock.recvfrom_into(view)
        sock.sendto(view[:size], addr)


# ---------------------------------------------------------------- 子进程管理

def spawn(argv, pin: int) -> subprocess.Popen:
    if pin >= 0 and has_taskset():
        argv = ["taskset", "-c", str(pin)] + argv
    return subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def has_taskset() -> bool:
    for path in os.environ.get("PATH", "").split(os.pathsep):
        if os.path.isfile(os.path.join(path, "taskset")):
            return True
    return False


def read_port_line(proc: subprocess.Popen, prefix: str, timeout: float = 10.0) -> int:
    """从子进程的标准输出里取它实际监听的端口。用阻塞读 + 超时。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        line = line.strip()
        if line.startswith(prefix):
            return int(line.rsplit(" ", 1)[1])
    raise RuntimeError("没有从子进程读到监听端口（期望以 %r 开头的行）" % prefix)


def cpu_ms(pid: int) -> float:
    """进程累计 CPU 毫秒。Linux 的 utime/stime 以时钟滴答计，一般是 100 Hz。"""
    try:
        with open("/proc/%d/stat" % pid, "r") as handle:
            fields = handle.read().rsplit(") ", 1)[1].split()
        ticks = int(fields[11]) + int(fields[12])
    except (OSError, IndexError, ValueError):
        return -1.0
    return ticks * 1000.0 / os.sysconf("SC_CLK_TCK")


# ---------------------------------------------------------------- 测量

def measure(peer, samples: int, rate: float, warmup: int, timeout: float):
    """按固定速率发 samples 个包，边发边收，返回 (每个包的往返微秒, 发出数, 收到数, 发送阶段秒数)。

    循环的骨架是「等到下一次发送时刻」而不是「发完再自适应」：等待期间用 select 盯住套接字，
    一有回复立刻处理。这样接收延迟不会被发送节奏拖延，而等待本身也不烧 CPU。
    早先的版本用非阻塞 recv 自旋采样，两个毛病都是实打实的：非阻塞 recv 没有数据时
    要抛一次异常（Python 里异常对象的创建不便宜），在 Windows 上把发送速率拖到了 923 pps；
    而自旋又把探针自己变成最忙的进程，反而给被测对象添了干扰。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCK_BUF)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCK_BUF)
    sock.connect(peer)
    sock.setblocking(True)

    send_buf = bytearray(PKT_SIZE)
    recv_buf = bytearray(65536)
    recv_view = memoryview(recv_buf)
    rtts = []
    sent = 0
    received = 0
    deadline = time.monotonic() + timeout
    # 等单个回复的上限。它只决定"丢包时白等多久"，不参与计时。
    # 取 50 ms：远大于任何合理往返，又不至于让丢包把整轮拖长。
    reply_timeout = 0.05

    def process_one() -> None:
        """读一个回复。**只统计正式样本**：预热期的回复也必须收掉，
        但它的往返时间没有意义。早先漏了这一步，于是接收数比发送数还多，
        丢包率算出来是负的。"""
        nonlocal received
        size = sock.recv_into(recv_view)
        if size >= 16:
            seq, sent_ns = struct.unpack_from("<QQ", recv_view, 0)
            if seq >= warmup:
                rtts.append((time.perf_counter_ns() - sent_ns) / 1000.0)
                received += 1

    def drain() -> None:
        while select.select((sock,), (), (), 0)[0]:
            process_one()

    interval_ns = int(1e9 / rate)
    total = warmup + samples
    next_send = time.perf_counter_ns()
    send_start = time.perf_counter()
    send_end = send_start
    for seq in range(total):
        # 第一步：节流，等到本包的发送时刻。
        #
        # **这一步必须在上一个回复已经收掉之后做**，否则等待会把已经到达的回复压在
        # 内核缓冲里，测出来的往返时间就把整段等待算了进去。这不是理论上的担心：
        # 早先这里先等待、后收包，1000 pps 下 p50 从 20 µs 变成 707 µs，
        # 三个网关的差异被完全淹没（都"一样快"），差点据此得出错误结论。
        while True:
            remain = next_send - time.perf_counter_ns()
            if remain <= 0:
                break
            if remain > 600_000:
                # 远处用 sleep。此刻没有待收的回复，所以不会污染测量。
                # 预留 0.3 ms 是给 sleep 的返回误差留的：sleep 总会多睡一点，
                # 预留太大（早先写的 1.5 ms）会把 1 ms 的间隔整个吃掉。
                time.sleep((remain - 300_000) / 1e9)
            else:
                # 近处用 select：它的超时精度是微秒级，而 sleep 只有毫秒级。
                select.select((sock,), (), (), remain / 1e9)
        struct.pack_into("<QQ", send_buf, 0, seq, time.perf_counter_ns())
        try:
            sock.send(send_buf)
        except OSError:
            pass
        if seq >= warmup:
            sent += 1
        next_send += interval_ns
        # 第二步：立刻等这一个的回复。**计数器记的就是这一段**——
        # 从"即将发出"到"读到回声"，也就是要比较的那个往返时间。
        if select.select((sock,), (), (), reply_timeout)[0]:
            drain()
        send_end = time.perf_counter()
        if time.monotonic() > deadline:
            break

    # 收尾：把还在路上的回复读干净。给一个固定上限而不是按样本数推算：
    # 早先那次写成"发送时长的一半"，于是 secs 里多了几秒的空等，
    # 把算出来的 pps 稀释成了目标值的一半多。
    settle = time.monotonic() + 1.0
    while received < sent and time.monotonic() < settle:
        if select.select((sock,), (), (), 0.01)[0]:
            drain()
    sock.close()
    rtts.sort()
    return rtts, sent, received, send_end - send_start


def blast(peer, seconds: float, timeout: float):
    """不计速率地灌，看转发器在丢包之前能吃下多少包。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, SOCK_BUF)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCK_BUF)
    sock.connect(peer)
    sock.setblocking(True)

    send_buf = bytearray(PKT_SIZE)
    recv_buf = bytearray(65536)
    recv_view = memoryview(recv_buf)
    sent = 0
    received = 0
    rtts = []

    def drain(limit: int) -> int:
        nonlocal received
        got = 0
        while got < limit and select.select((sock,), (), (), 0)[0]:
            size = sock.recv_into(recv_view)
            if size >= 16:
                _, sent_ns = struct.unpack_from("<QQ", recv_view, 0)
                rtts.append((time.perf_counter_ns() - sent_ns) / 1000.0)
                received += 1
            got += 1
        return got

    start = time.perf_counter()
    end = start + seconds
    while time.perf_counter() < end:
        # 先收后发：不这样做的话发送端会把内核缓冲灌满，
        # 而那时测出来的是缓冲深度，不是转发器的处理能力。
        drain(256)
        for _ in range(64):
            struct.pack_into("<QQ", send_buf, 0, sent, time.perf_counter_ns())
            try:
                sock.send(send_buf)
                sent += 1
            except OSError:
                break

    deadline = time.monotonic() + timeout
    while received < sent and time.monotonic() < deadline:
        if drain(512) == 0:
            break
    sock.close()
    rtts.sort()
    return rtts, sent, received, time.perf_counter() - start


# ---------------------------------------------------------------- 主流程

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--echo", action="store_true", help="内部用：以回声房间模式运行")
    parser.add_argument("--pin", type=int, default=-1, help="回声模式专用：绑到哪个核")
    parser.add_argument("--label", default="direct")
    parser.add_argument("--gateway", default="", help="被测网关的启动命令；留空表示测直连基线")
    parser.add_argument("--samples", type=int, default=15000)
    parser.add_argument("--rate", type=float, default=1000.0)
    parser.add_argument("--warmup", type=int, default=500)
    parser.add_argument("--phase", choices=("latency", "blast"), default="latency")
    parser.add_argument("--blast-seconds", type=float, default=3.0)
    parser.add_argument("--pin-bench", type=int, default=0, help="探针与回声房间绑到哪个核（-1 表示不绑）")
    parser.add_argument("--pin-gateway", type=int, default=1, help="被测网关绑到哪个核（-1 表示不绑）")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    if args.echo:
        return run_echo(args.pin)

    echo = spawn([sys.executable, os.path.abspath(__file__), "--echo", "--pin", str(args.pin_bench)], -1)
    gateway = None
    try:
        echo_port = read_port_line(echo, "[echo]")
        peer_port = echo_port
        if args.gateway:
            argv = shlex.split(args.gateway)
            argv += ["--listen", "0", "--rooms", "127.0.0.1:%d" % echo_port, "--stats", "3600"]
            gateway = spawn(argv, args.pin_gateway)
            peer_port = read_port_line(gateway, "[gateway]")

        if args.pin_bench >= 0:
            try:
                os.sched_setaffinity(0, {args.pin_bench})
            except OSError:
                pass

        peer = ("127.0.0.1", peer_port)
        gateway_pid = gateway.pid if gateway else -1
        cpu_before = cpu_ms(gateway_pid) if gateway else -1.0

        if args.phase == "blast":
            rtts, sent, received, elapsed = blast(peer, args.blast_seconds, args.timeout)
        else:
            rtts, sent, received, elapsed = measure(
                peer, args.samples, args.rate, args.warmup, args.timeout
            )

        cpu_after = cpu_ms(gateway_pid) if gateway else -1.0

        loss = 0.0 if sent == 0 else (sent - received) * 100.0 / sent
        fields = [
            "label=%s" % args.label,
            "phase=%s" % args.phase,
            "sent=%d" % sent,
            "recv=%d" % received,
            "loss=%.3f%%" % loss,
            "secs=%.2f" % elapsed,
            "pps=%.0f" % (sent / max(elapsed, 1e-9)),
        ]
        if rtts:
            fields += [
                "p50_us=%.1f" % percentile(rtts, 0.50),
                "p90_us=%.1f" % percentile(rtts, 0.90),
                "p99_us=%.1f" % percentile(rtts, 0.99),
                "p999_us=%.1f" % percentile(rtts, 0.999),
                "max_us=%.1f" % rtts[-1],
            ]
        if cpu_before >= 0:
            busy = cpu_after - cpu_before
            fields.append("gw_cpu_ms=%.0f" % busy)
            if received:
                fields.append("gw_cpu_ms_per_1k=%.2f" % (busy * 1000.0 / received))
        print("[bench] " + "  ".join(fields), flush=True)
        return 0
    finally:
        for proc in (gateway, echo):
            if proc is not None:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    sys.exit(main())
