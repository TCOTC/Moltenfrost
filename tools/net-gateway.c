/* 熔霜 · 单端口 UDP 网关
 *
 * 把「只开放一个 UDP 端口」与「每个房间一个独立进程」拆开实现：对外只监听一个端口，
 * 内部按**客户端流**把数据报分给各个绑在环回上的房间进程。
 * 为什么是这条路线、以及它解决了什么问题，见 docs/公网房间方案.md 的路线 ②。
 *
 * ## 为什么是 C（2026-09-30 实测选定）
 *
 * 候选还有 Go 与 Python 两份实现，用 tools/net-gateway-bench.py 在同一台服务器
 *（腾讯云 2 核 2G，即部署目标）上对比过，各跑三遍：
 *
 *   实现      p50      p99      CPU 每千包
 *   直连基线  23 µs    45 µs    —（不经网关）
 *   **C**     87 µs    127 µs   44 ms
 *   Go        93 µs    147 µs   56 ms
 *   Python    102 µs   142 µs   63 ms
 *
 * 差别的绝对量很小（比玩家到服务器的真实 RTT 19～21 ms 小三个数量级），
 * 因此决定性的是后两项与部署成本：
 *
 *   - CPU 每包最低，而它决定一台 2 核机器能同时托管几个房间
 *   - **不引入任何新依赖**：服务器的 Ubuntu 自带 gcc，现场 gcc -O2 就是一行命令，
 *     产物 22 KB。Go 那一版要把 Go 工具链常驻在服务器上，Python 那一版每次转发
 *     都要过解释器
 *   - 尾延迟（p99.9）也最好：C 560～720 µs，Go 533～908 µs，Python 585～1050 µs
 *
 * ## 决定它快不快的不是算法，而是每包几次系统调用
 *
 * 转发一个数据报在用户态只需要 recvfrom + sendto，没有解析、没有状态机、没有分配。
 * 因此这一版的重点全在把系统调用按批合并（recvmmsg / sendmmsg）。
 *
 * 批量的代价要注意：如果为了凑满一批而等，就会引入额外延迟。这里用 MSG_DONTWAIT
 * 把当时已经到达的包一次取走，**不做任何等待**，因此批量为 1 时就是一次普通的 recvfrom，
 * 没有引入延迟。游戏的实际速率是每流约 60 包/秒，批量几乎总是 1；
 * 批量只在压力测试那一档才有意义。
 *
 * 不依赖任何第三方库：哈希表与流表都是下面自己写的，因此编译就是一条命令。
 *
 * 编译：gcc -O2 -o build/net-gateway tools/net-gateway.c
 * 验证：tools/net-gateway-game-check.sh（两个真实无头实例穿过网关）
 *
 * 日志：启动时一行 `[gateway] listening <端口>`；每个新客户端分到房时一行
 * `[gateway] flow -> room N`；每 `--stats` 秒一行 `[gateway] flows=… rooms=…`。
 * 分流那一行不是装饰：没有它时"某人被分到了哪间房"只能从房间侧的 peer 日志反推，
 * 而排 1/2 与 2/2 的分流问题时就是这么瞎猜了一整轮。
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* ---------------------------------------------------------------- 常量 */

#define PKT_MAX 65536
#define BUFSIZE (1 << 20)
#define MAX_ROOMS 64
#define MAX_FLOWS 4096
/* 一次系统调用最多搬运多少个数据报。32 是"再大也没收益"的一档：
 * 环回上一个流套接字在突发时也就攒几个包，取太大只会白占内存。 */
#define BATCH 32
/* fd → 流下标的直接映射表。fd 是小整数，用数组比哈希快且更简单。 */
#define FD_MAX 65536
#define MAX_EVENTS 64
/* 事件循环的空转上限。用它驱动空闲回收与统计输出，因此不需要额外的定时器线程。 */
#define TICK_MS 200

/* ---------------------------------------------------------------- 全局状态 */

typedef struct {
	int fd;
	int used;
	struct sockaddr_in client;
	int room;
	double last_seen;
} flow_t;

static struct sockaddr_in g_rooms[MAX_ROOMS];
static int g_room_count[MAX_ROOMS];
static int g_room_total = 0;
static int g_max_per_room = 4;
static double g_idle = 60.0;
static double g_stats_interval = 10.0;
static struct in_addr g_local_bind;
static int g_epfd = -1;
static int g_public_fd = -1;

static flow_t g_flows[MAX_FLOWS];
static int g_fd_flow[FD_MAX];
static int g_free_slots[MAX_FLOWS];
static int g_free_top = 0;

static long g_pkts_in = 0, g_pkts_out = 0, g_drops = 0;

static double now_seconds(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int live_flows(void) {
	int count = 0;
	for (int i = 0; i < MAX_FLOWS; i++)
		if (g_flows[i].used)
			count++;
	return count;
}

/* 各房间人数，形如 "2/1/0"。统计行与分流诊断行共用，免得两处格式不一致。 */
static const char *room_counts_text(void) {
	static char text[256];
	int at = 0;
	text[0] = '\0';
	for (int i = 0; i < g_room_total && at < (int)sizeof(text) - 8; i++)
		at += snprintf(text + at, sizeof(text) - (size_t)at, "%s%d", i ? "/" : "", g_room_count[i]);
	return text;
}

/* ---------------------------------------------------------------- 客户端地址哈希表
 *
 * 键是 (IPv4, 端口) 拼成的 64 位整数。两个字段直接用网络序的原始值——
 * 它们只当键用，不比较大小，因此不必转主机序。
 * 开放地址 + 线性探测；删除留墓碑；装载过半（含墓碑）时整体重建。
 * 实际只有几百个流，这张表永远不会是瓶颈，因此不做过早优化。 */

#define HASH_CAP 8192u
#define KEY_EMPTY 0ull
#define KEY_DELETED (~0ull)

static unsigned long long g_keys[HASH_CAP];
static int g_vals[HASH_CAP];
static unsigned g_hash_used = 0;

static inline unsigned long long key_of(const struct sockaddr_in *addr) {
	return ((unsigned long long)addr->sin_addr.s_addr << 16) | (unsigned)addr->sin_port;
}

static inline unsigned hash_of(unsigned long long key) {
	/* 混一下低位：端口在低 16 位，直接取模会让连续端口挤在一起。 */
	key ^= key >> 33;
	key *= 0xff51afd7ed558ccdull;
	key ^= key >> 33;
	return (unsigned)key;
}

static void hash_rebuild(void) {
	static unsigned long long old_keys[HASH_CAP];
	static int old_vals[HASH_CAP];
	memcpy(old_keys, g_keys, sizeof(g_keys));
	memcpy(old_vals, g_vals, sizeof(g_vals));
	memset(g_keys, 0, sizeof(g_keys));
	g_hash_used = 0;
	for (unsigned i = 0; i < HASH_CAP; i++) {
		if (old_keys[i] == KEY_EMPTY || old_keys[i] == KEY_DELETED)
			continue;
		unsigned slot = hash_of(old_keys[i]) & (HASH_CAP - 1);
		while (g_keys[slot] != KEY_EMPTY)
			slot = (slot + 1) & (HASH_CAP - 1);
		g_keys[slot] = old_keys[i];
		g_vals[slot] = old_vals[i];
		g_hash_used++;
	}
}

static int *hash_find(unsigned long long key) {
	unsigned slot = hash_of(key) & (HASH_CAP - 1);
	for (unsigned probes = 0; probes < HASH_CAP; probes++) {
		if (g_keys[slot] == key)
			return &g_vals[slot];
		if (g_keys[slot] == KEY_EMPTY)
			return NULL;
		slot = (slot + 1) & (HASH_CAP - 1);
	}
	return NULL;
}

static int *hash_insert(unsigned long long key) {
	if (g_hash_used * 2 >= HASH_CAP)
		hash_rebuild();
	unsigned slot = hash_of(key) & (HASH_CAP - 1);
	while (g_keys[slot] != KEY_EMPTY && g_keys[slot] != KEY_DELETED)
		slot = (slot + 1) & (HASH_CAP - 1);
	if (g_keys[slot] == KEY_EMPTY)
		g_hash_used++;
	g_keys[slot] = key;
	g_vals[slot] = -1;
	return &g_vals[slot];
}

static void hash_erase(unsigned long long key) {
	int *val = hash_find(key);
	if (val == NULL)
		return;
	unsigned slot = (unsigned)(val - g_vals);
	g_keys[slot] = KEY_DELETED;
}

/* ---------------------------------------------------------------- 流 */

/* 每个房间最近一次**有包发出去**的时刻（单增秒）。只在返回方向更新。
 * 目前只用于诊断输出（`rooms=1/2`），不参与选房——曾经用它做过被动探活，效果不好，
 * 原因见 pick_room 的说明。 */
static double g_room_last_out[MAX_ROOMS];

/* 选一个房间给新客户端。**挑「人最多且还有空位」的那一间，而不是「人最少」的。**
 *
 * 这一点写成函数是为了不让它变成一句容易改错的表达式，因为“人最少”听着更自然、
 * 实际却是反的：那会把每间房都填到 1 人再去填第二个人，于是一对玩家永远碰不到一起。
 * 实测踩到过——两个客户端分别拿到不同的房主 id，因为 gateway 把他们分到了两间房。
 *
 * 本作是双人协作，所以第二个玩家必须被放进同一个房间；房间满了才开下一间。
 * 平局取下标最小的那间（保持结果可预期，便于排查）。
 *
 * 返回 -1 表示所有房间都满了，调用方丢弃这个流（对应“房间满了稍后再试”）。
 *
 * ## 曾经在这里加过被动探活，已回退（2026-09-30）
 *
 * 试过“一个有人却不往外发包的房间算坏了，选房跳过它”（房间里有玩家时双方每秒交换心跳，
 * 因此不出包 = 卡住）。想法听着成立，实测不成立：**房间刚重启、还没开始应答的几秒会被误判为坏，
 * 而这个误判会粘住**——那个占着名额的旧流要等 60 秒空闲回收才消失，期间计数不归零，
 * 于是健康房间一直被跳过。实测后果：三个客户端变成 1/2 分流（而 2/2 才是对的），
 * 第三人还被塞进了一间当时真的没就绪的房间然后超时。
 *
 * 结论：这个启发式的代价（排除健康房间）大于它想避免的危害（派进卡住的房间）。
 * 卡死的房间现在靠两件事兜：它自己的 `Restart=always`，以及客户端 10 秒的连接超时。
 * 真要做得靠**主动探活**，而那要求房间能应答一个探针协议——超出当前范围。 */
static int pick_room(void) {
	int best = -1;
	int best_count = -1;
	for (int i = 0; i < g_room_total; i++) {
		if (g_room_count[i] >= g_max_per_room)
			continue;
		if (g_room_count[i] > best_count) {
			best = i;
			best_count = g_room_count[i];
		}
	}
	return best;
}

/* ---------------------------------------------------------------- 流 */

/* 返回流下标，失败返回 -1（房间满 / 流表满 / 建套接字失败）。 */
static int flow_open(const struct sockaddr_in *client) {
	int room = pick_room();
	if (room < 0 || g_free_top == 0) {
		/* 这一行在两种情况下都很关键：
		 *   生产里 —— 它就是"房间都满了，这位稍后再试"，而客户端那边只会看到超时；
		 *   测试时 —— 上一轮遗留的连接要等 --idle 秒才回收，过后重跑就会这样被拒，
		 *           而没有这一行时它看起来像"网关坏了"。 */
		static double last_report = 0.0;
		double now = now_seconds();
		if (now - last_report > 5.0) {
			last_report = now;
			printf("[gateway] full: dropped a client (rooms=%s, freed slots=%d)\n",
			       room_counts_text(), g_free_top);
			fflush(stdout);
		}
		return -1;
	}

	int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
	if (fd < 0 || fd >= FD_MAX) {
		if (fd >= 0)
			close(fd);
		return -1;
	}
	int buffer = BUFSIZE;
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
	/* 绑环回：这个套接字只用来跟本机的房间进程说话，不该被外部访问到。 */
	struct sockaddr_in local;
	memset(&local, 0, sizeof(local));
	local.sin_family = AF_INET;
	local.sin_addr = g_local_bind;
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		close(fd);
		return -1;
	}

	int index = g_free_slots[--g_free_top];
	g_flows[index].fd = fd;
	g_flows[index].used = 1;
	g_flows[index].client = *client;
	g_flows[index].room = room;
	g_flows[index].last_seen = now_seconds();
	g_fd_flow[fd] = index;
	g_room_count[room]++;
	*hash_insert(key_of(client)) = index;

	/* 把一个新客户端分到了哪间房写进日志。
	 * 没有这一行时，"某人被分到了哪一间"只能从房间那侧的 peer 日志反推——
	 * 排那个 1/2 与 2/2 分流问题时就是这么瞎猜了一整轮。 */
	printf("[gateway] flow -> room %d (%s:%d)  rooms=%s\n",
	       room, inet_ntoa(g_rooms[room].sin_addr), ntohs(g_rooms[room].sin_port),
	       room_counts_text());
	fflush(stdout);

	/* 每个流只注册一次，因此放在这里，而不是每条包都 epoll_ctl。 */
	struct epoll_event event;
	event.events = EPOLLIN;
	event.data.fd = fd;
	epoll_ctl(g_epfd, EPOLL_CTL_ADD, fd, &event);
	return index;
}

static void flow_close(int index) {
	flow_t *flow = &g_flows[index];
	hash_erase(key_of(&flow->client));
	g_room_count[flow->room]--;
	g_fd_flow[flow->fd] = -1;
	/* 先从 epoll 摘掉再关：关掉之后 fd 号可能被新流复用，
	 * 而 epoll 里留着旧注册的话，新流会在自己注册之前就收到本该属于旧流的事件。 */
	epoll_ctl(g_epfd, EPOLL_CTL_DEL, flow->fd, NULL);
	close(flow->fd);
	flow->used = 0;
	flow->fd = -1;
	g_free_slots[g_free_top++] = index;
}

/* ---------------------------------------------------------------- 批量收发
 *
 * 缓冲区全部放静态区（BSS），不进栈：一批 32 个 64 KiB 的缓冲有 2 MiB，
 * 放栈上会直接爆掉。它们只被主循环使用，没有并发，因此不需要加锁。 */

static struct mmsghdr g_in_msgs[BATCH];
static struct iovec g_in_iov[BATCH];
static struct sockaddr_in g_in_addr[BATCH];
static char g_in_buf[BATCH][PKT_MAX];

static struct mmsghdr g_out_msgs[BATCH];
static struct iovec g_out_iov[BATCH];

static void batch_init(void) {
	for (int i = 0; i < BATCH; i++) {
		g_in_iov[i].iov_base = g_in_buf[i];
		g_in_iov[i].iov_len = PKT_MAX;
		g_in_msgs[i].msg_hdr.msg_iov = &g_in_iov[i];
		g_in_msgs[i].msg_hdr.msg_iovlen = 1;
		g_in_msgs[i].msg_hdr.msg_name = &g_in_addr[i];
		g_out_msgs[i].msg_hdr.msg_iov = &g_out_iov[i];
		g_out_msgs[i].msg_hdr.msg_iovlen = 1;
	}
}

/* 把当时已到达的包一次取走。MSG_DONTWAIT 保证不会为了凑批而等待。 */
static int batch_recv(int fd) {
	for (int i = 0; i < BATCH; i++) {
		g_in_msgs[i].msg_hdr.msg_namelen = sizeof(struct sockaddr_in);
		g_in_msgs[i].msg_hdr.msg_controllen = 0;
		g_in_msgs[i].msg_hdr.msg_flags = 0;
	}
	int got = recvmmsg(fd, g_in_msgs, BATCH, MSG_DONTWAIT, NULL);
	return got < 0 ? 0 : got;
}

/* 一次系统调用把这批包发给同一个目标。`packets` 是 g_in_buf / g_in_msgs 的下标。 */
static void batch_send(int fd, const struct sockaddr_in *dest, const int *packets, int n) {
	for (int i = 0; i < n; i++) {
		g_out_iov[i].iov_base = g_in_buf[packets[i]];
		g_out_iov[i].iov_len = g_in_msgs[packets[i]].msg_len;
		g_out_msgs[i].msg_hdr.msg_name = (void *)dest;
		g_out_msgs[i].msg_hdr.msg_namelen = sizeof(*dest);
	}
	int sent = sendmmsg(fd, g_out_msgs, n, MSG_DONTWAIT);
	if (sent < 0)
		g_drops += n;
	else if (sent < n)
		g_drops += n - sent;
}

/* ---------------------------------------------------------------- 两个方向 */

/* 公网口 → 房间。同一批里的包来自不同客户端是可能的（公网口是所有人共用的），
 * 因此先逐个解析出目标流，再把**连续同目标**的合并成一次 sendmmsg。 */
static int drain_public(int public_fd) {
	int n = batch_recv(public_fd);
	if (n == 0)
		return 0;
	int owner[BATCH];
	for (int i = 0; i < n; i++) {
		const struct sockaddr_in *src = &g_in_addr[i];
		int *slot = hash_find(key_of(src));
		int index = (slot == NULL) ? flow_open(src) : *slot;
		if (index < 0) {
			g_drops++;
			owner[i] = -1;
			continue;
		}
		g_flows[index].last_seen = now_seconds();
		owner[i] = index;
	}
	int i = 0;
	while (i < n) {
		if (owner[i] < 0) {
			i++;
			continue;
		}
		int j = i;
		while (j < n && owner[j] == owner[i])
			j++;
		int run[BATCH];
		for (int k = i; k < j; k++)
			run[k - i] = k;
		batch_send(g_flows[owner[i]].fd, &g_rooms[g_flows[owner[i]].room], run, j - i);
		g_pkts_in += j - i;
		i = j;
	}
	return n;
}

/* 某个流的套接字 → 该流的客户端。一个流套接字只跟一个房间说话，
 * 因此这一批的目标永远是同一个客户端。
 *
 * **回复必须从公网口发出，不能从这个流套接字发出。** 客户端是 connect() 到公网口的，
 * 因此它只收「源地址 = 它连的那个地址:端口」的包；若回复从一个临时端口出去，
 * 客户端会把它当不相关的包丢掉，现象是「连上了、服务端也在回、但客户端什么都没收到」
 *（实测：发送 3000 个包，收到 0 个）。流套接字只负责把包**送进房间**与**从房间收回来**。 */
static int drain_flow(int fd) {
	int index = g_fd_flow[fd];
	if (index < 0)
		return 0;
	int n = batch_recv(fd);
	if (n == 0)
		return 0;
	const struct sockaddr_in *room = &g_rooms[g_flows[index].room];
	int keep[BATCH];
	int kept = 0;
	for (int i = 0; i < n; i++) {
		/* 核对来源。环回上任何进程都能往这个临时端口发包，不核对的话
		 * 一个配错端口的进程就能往客户端塞内容，而现象是"客户端收到了看不懂的包"。 */
		if (g_in_addr[i].sin_addr.s_addr != room->sin_addr.s_addr ||
		    g_in_addr[i].sin_port != room->sin_port) {
			g_drops++;
			continue;
		}
		keep[kept++] = i;
	}
	if (kept != 0) {
		batch_send(g_public_fd, &g_flows[index].client, keep, kept);
		g_pkts_out += kept;
		/* "这个房间还活着"的证据。只在这里更新，理由见 g_room_last_out。 */
		g_room_last_out[g_flows[index].room] = now_seconds();
	}
	return n;
}

/* ---------------------------------------------------------------- 统计与回收 */

static void stats_line(void) {
	printf("[gateway] flows=%d pkts_in=%ld pkts_out=%ld drops=%ld rooms=%s\n",
	       live_flows(), g_pkts_in, g_pkts_out, g_drops, room_counts_text());
	fflush(stdout);
}

static void reap(double *next_stats) {
	double deadline = now_seconds() - g_idle;
	for (int i = 0; i < MAX_FLOWS; i++) {
		if (g_flows[i].used && g_flows[i].last_seen < deadline)
			flow_close(i);
	}
	if (now_seconds() >= *next_stats) {
		*next_stats = now_seconds() + g_stats_interval;
		stats_line();
	}
}

/* ---------------------------------------------------------------- 启动 */

static int parse_rooms(const char *spec) {
	char text[1024];
	snprintf(text, sizeof(text), "%s", spec);
	char *save = NULL;
	for (char *item = strtok_r(text, ",", &save); item; item = strtok_r(NULL, ",", &save)) {
		if (g_room_total >= MAX_ROOMS) {
			fprintf(stderr, "too many rooms (max %d)\n", MAX_ROOMS);
			return -1;
		}
		char *colon = strrchr(item, ':');
		if (colon == NULL) {
			fprintf(stderr, "room must be HOST:PORT, got '%s'\n", item);
			return -1;
		}
		*colon = '\0';
		struct sockaddr_in *addr = &g_rooms[g_room_total];
		memset(addr, 0, sizeof(*addr));
		addr->sin_family = AF_INET;
		addr->sin_port = htons((unsigned short)atoi(colon + 1));
		const char *host = (item[0] == '\0') ? "127.0.0.1" : item;
		if (inet_pton(AF_INET, host, &addr->sin_addr) != 1) {
			fprintf(stderr, "room host must be an IPv4 literal, got '%s'\n", host);
			return -1;
		}
		g_room_total++;
	}
	return g_room_total > 0 ? 0 : -1;
}

int main(int argc, char **argv) {
	int listen_port = 27015;
	const char *rooms = NULL;
	const char *local_bind = "127.0.0.1";

	for (int i = 1; i < argc; i++) {
		int has_next = i + 1 < argc;
		if (!strcmp(argv[i], "--listen") && has_next)
			listen_port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--rooms") && has_next)
			rooms = argv[++i];
		else if (!strcmp(argv[i], "--max-per-room") && has_next)
			g_max_per_room = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--idle") && has_next)
			g_idle = atof(argv[++i]);
		else if (!strcmp(argv[i], "--stats") && has_next)
			g_stats_interval = atof(argv[++i]);
		else if (!strcmp(argv[i], "--local-bind") && has_next)
			local_bind = argv[++i];
		else {
			fprintf(stderr, "unknown or incomplete argument: %s\n", argv[i]);
			return 2;
		}
	}
	if (rooms == NULL) {
		fprintf(stderr, "--rooms is required\n");
		return 2;
	}
	if (parse_rooms(rooms) != 0)
		return 2;
	if (inet_pton(AF_INET, local_bind, &g_local_bind) != 1) {
		fprintf(stderr, "--local-bind must be an IPv4 literal, got '%s'\n", local_bind);
		return 2;
	}

	/* 写端被关掉时（探针提前退出）不要被 SIGPIPE 杀掉，改由返回值处理。 */
	signal(SIGPIPE, SIG_IGN);

	for (int i = 0; i < FD_MAX; i++)
		g_fd_flow[i] = -1;
	for (int i = 0; i < MAX_FLOWS; i++) {
		g_flows[i].fd = -1;
		g_flows[i].used = 0;
		g_free_slots[g_free_top++] = MAX_FLOWS - 1 - i;
	}
	/* 初始化成"刚出过包"。留 0 的话，第一个客户端被分到的那个空闲房间
	 * 会被 room_alive() 当成坏的（0 秒 vs 现在的单增秒），于是谁都不进去。 */
	for (int i = 0; i < MAX_ROOMS; i++)
		g_room_last_out[i] = now_seconds();
	batch_init();

	int public_fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (public_fd < 0) {
		perror("socket");
		return 1;
	}
	int buffer = BUFSIZE;
	setsockopt(public_fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
	setsockopt(public_fd, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
	struct sockaddr_in bind_addr;
	memset(&bind_addr, 0, sizeof(bind_addr));
	bind_addr.sin_family = AF_INET;
	bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
	bind_addr.sin_port = htons((unsigned short)listen_port);
	if (bind(public_fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
		perror("bind");
		return 1;
	}
	socklen_t len = sizeof(bind_addr);
	if (getsockname(public_fd, (struct sockaddr *)&bind_addr, &len) < 0) {
		perror("getsockname");
		return 1;
	}

	g_epfd = epoll_create1(0);
	g_public_fd = public_fd;
	struct epoll_event event;
	event.events = EPOLLIN;
	event.data.fd = public_fd;
	epoll_ctl(g_epfd, EPOLL_CTL_ADD, public_fd, &event);

	printf("[gateway] listening %d\n", ntohs(bind_addr.sin_port));
	fflush(stdout);

	double next_stats = now_seconds() + g_stats_interval;
	struct epoll_event events[MAX_EVENTS];
	while (1) {
		int ready = epoll_wait(g_epfd, events, MAX_EVENTS, TICK_MS);
		for (int i = 0; i < ready; i++) {
			int fd = events[i].data.fd;
			/* 水平触发：一直读到没有为止，否则会被反复唤醒。 */
			while ((fd == public_fd ? drain_public(fd) : drain_flow(fd)) > 0)
				;
		}
		reap(&next_stats);
	}
	return 0;
}
