#!/usr/bin/env bash
# 熔霜 · 服务端环境搭建与更新。**在服务器上执行**，由 tools/deploy-server.mjs 上传后调用。
#
# 为什么需要这个脚本：工程的两台开发机导出各自的桌面产物，而服务器上跑的是同一份工程源码。
# 服务器只需要 Godot 二进制与仓库，不需要导出模板。这一段步骤固定且容易漏步
#（尤其 `--import` 那一步：新克隆的 `.godot/` 是空的，直接启动会因为全局类未注册而失败），
# 因此写成脚本，重建机器或换机器时一条命令恢复。
#
# 幂等：重复执行是安全的。已装好的 Godot 与仓库会跳过或只做更新。
# 输出只用英文：SSH 到 Windows 终端的中文可能因编码而乱码，反而妨碍排查。
#
# 用法（参数都由 deploy-server.mjs 传）：
#   bash server-setup.sh --godot-zip /tmp/godot.zip --bundle /tmp/mf.bundle
#                       [--port 27015] [--enable-service] [--skip-import]
#                       [--directory [--directory-port 27017] [--room-base-port 40001]
#                                    [--rooms-count 2] [--max-per-room 2]]

set -euo pipefail

GODOT_VERSION="4.7.2"
GODOT_PREFIX="/opt/godot"
GODOT_BIN="${GODOT_PREFIX}/godot"
REPO_DIR="${HOME}/moltenfrost"
SERVICE_NAME="moltenfrost"

GODOT_ZIP=""
BUNDLE=""
# 只用于**不带 --directory** 的单房间模式。带 --directory 时玩家连的是房间段
# （ROOM_BASE_PORT 起），27015 上不跑任何东西，这个值只剩兜底与日志措辞的作用。
PORT="27015"
ADVERTISE=""
ENABLE_SERVICE=0
SKIP_IMPORT=0
# 房间目录模式（--directory）：房间对外监听并登记到目录，客户端从列表里选一间直连。
# 取代了之前那个单端口 UDP 网关：要让玩家选房间，就必须让每间房有对外地址与端口，
# 于是那个“把包转给某间房”的转发器就没有存在理由了。见 docs/公网房间方案.md。
DIRECTORY=0
DIRECTORY_PORT="27017"
ROOM_BASE_PORT="40001"
ROOM_COUNT="2"
# 每房间人数上限。**默认 2 不是保守取值，是上限本身**：关卡只配了两个出生点
#（scenes/levels/level_01.tscn 的 spawn_points），而 spawn_point() 在槽位越界时按取模回落，
# 于是第 3 个人会与第 1 个人**重叠生成**。本作又是双人协作，所以 2 就是对的数。
MAX_PER_ROOM="2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --godot-zip) GODOT_ZIP="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --advertise) ADVERTISE="$2"; shift 2 ;;
    --enable-service) ENABLE_SERVICE=1; shift ;;
    --skip-import) SKIP_IMPORT=1; shift ;;
    --godot-prefix) GODOT_PREFIX="$2"; GODOT_BIN="${GODOT_PREFIX}/godot"; shift 2 ;;
    --directory) DIRECTORY=1; shift ;;
    --directory-port) DIRECTORY_PORT="$2"; shift 2 ;;
    --room-base-port) ROOM_BASE_PORT="$2"; shift 2 ;;
    --rooms-count) ROOM_COUNT="$2"; shift 2 ;;
    --max-per-room) MAX_PER_ROOM="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------- 1. 运行时依赖

# Godot 的 Linux 二进制是动态链接的，即使 --headless 也要在加载阶段解析这些符号。
# Ubuntu Server 最小安装不带它们，缺了会在启动时报 "cannot open shared object file"。
# 这里装的是运行时包（libx11-6 等），不是编译用的 -dev 包。
#
# 包名随发行版变动（例如 libasound2 在 24.04 起改名成 libasound2t64），
# 所以下面装完之后会用 ldd 复核，缺什么就报出来，不靠包名列表猜准。
say "1/6 install runtime dependencies"
sudo apt-get update -qq
# libasound2t64 是 24.04 起的名字，旧版叫 libasound2；|| true 让两种都能装下去，
# 真正的判据是后面的 ldd 复核。
# Godot 的 Linux 二进制大部分依赖是直接链接的，但有一小部分是在运行期用 dlopen 加载的。
# **这两类要分开检查**：`ldd` 只能看到前者，后者只能靠实际启动一次、看它有没有
# 报 "cannot open shared object file"。实测 libfontconfig.so.1 就是后者，
# 而且它缺失不会导致启动失败（仅影响字体渲染，无头服务端用不上），
# 所以很容易被当成噪声忽略——但每启动一次就多一行看似报错的输出，会干扰以后的排查。
sudo apt-get install -y --no-install-recommends \
  libx11-6 libxcursor1 libxinerama1 libxi6 libxrandr2 \
  libgl1 libglu1-mesa libasound2t64 libpulse0 libudev1 \
  libwayland-client0 libwayland-cursor0 libwayland-egl1 \
  libfontconfig1 unzip ca-certificates || true

# ---------------------------------------------------------------- 2. Godot 二进制

say "2/6 install Godot ${GODOT_VERSION}"
if [[ -x "$GODOT_BIN" ]] && "$GODOT_BIN" --version 2>/dev/null | grep -q "$GODOT_VERSION"; then
  echo "already installed: $("$GODOT_BIN" --version)"
else
  if [[ -z "$GODOT_ZIP" || ! -f "$GODOT_ZIP" ]]; then
    echo "godot zip not provided or missing: $GODOT_ZIP" >&2
    exit 1
  fi
  sudo mkdir -p "$GODOT_PREFIX"
  # zip 里是一个顶层文件（Godot_v4.7.2-stable_linux.x86_64），解压到临时目录再改名，
  # 这样不必猜压缩包内部的目录结构。
  tmpdir="$(mktemp -d)"
  unzip -q "$GODOT_ZIP" -d "$tmpdir"
  inner="$(find "$tmpdir" -maxdepth 1 -type f -name 'Godot*' | head -1)"
  if [[ -z "$inner" ]]; then
    echo "no Godot binary inside the zip" >&2
    ls -l "$tmpdir" >&2
    exit 1
  fi
  sudo install -m 0755 "$inner" "$GODOT_BIN"
  rm -rf "$tmpdir"
  echo "installed: $("$GODOT_BIN" --version)"
fi

# 复核动态库。分两步，因为两种加载方式要靠不同手段才能发现：
#   ldd          —— 直接链接的库，报得准
#   试跑 --version —— dlopen 加载的库，ldd 看不到（实测 libfontconfig 就是这一类）
say "2b/6 verify shared libraries"
missing="$(ldd "$GODOT_BIN" 2>/dev/null | awk '/not found/ {print $1}' | sort -u || true)"
if [[ -n "$missing" ]]; then
  echo "MISSING shared libraries:" >&2
  echo "$missing" >&2
  echo "install the packages providing them, then re-run this script." >&2
  exit 1
fi
# --version 会真正加载一次二进制，因此 dlopen 的缺失会在这里暴露。
# 用 2>&1 合并输出后搜关键字，命中就说明还有库没装上。
dlopen_missing="$(  "$GODOT_BIN" --version 2>&1 | grep -a 'cannot open shared object file' || true )"
if [[ -n "$dlopen_missing" ]]; then
  echo "MISSING libraries loaded at runtime (ldd cannot see these):" >&2
  echo "$dlopen_missing" >&2
  echo "install the packages providing them, then re-run this script." >&2
  exit 1
fi
echo "all shared libraries resolved (ldd + runtime probe)"

# ---------------------------------------------------------------- 3. 仓库

say "3/6 update repository"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "bundle not provided or missing: $BUNDLE" >&2
  exit 1
fi
if [[ -d "$REPO_DIR/.git" ]]; then
  # 服务器访问不了 GitHub，所以更新也走 bundle：fetch 之后再硬切到 bundle 里的 main。
  # 本地没有未提交的改动（服务器上不应改代码），因此 reset --hard 是安全的。
  cd "$REPO_DIR"
  git fetch --force "$BUNDLE" main
  git reset --hard FETCH_HEAD
  git clean -fd -e .godot
  echo "updated to $(git rev-parse --short HEAD)"
else
  git clone --quiet "$BUNDLE" "$REPO_DIR"
  cd "$REPO_DIR"
  git checkout -q main
  echo "cloned at $(git rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------- 4. 导入资源与类缓存

# **这一步不能省。** 新克隆的仓库里 .godot/ 是空的（它不入库），
# 而全局 class_name 是靠 .godot/global_script_class_cache.cfg 注册的，
# 不重建的话启动会以 "Identifier not declared" 失败——报错看起来像代码写错了。
say "4/6 import assets and rebuild class cache"
if [[ "$SKIP_IMPORT" == "1" ]]; then
  echo "skipped (--skip-import)"
else
  cd "$REPO_DIR"
  "$GODOT_BIN" --headless --path . --import 2>&1 | tail -5
  if ! grep -q 'LanDiscovery' .godot/global_script_class_cache.cfg 2>/dev/null; then
    echo "class cache looks empty after import - see memory/godot-notes.md" >&2
    exit 1
  fi
  echo "class cache rebuilt"
fi

# ---------------------------------------------------------------- 5. 自检

# 起一次服务端再退出，确认没有脚本错误。用 --port 0 让系统分配端口，
# 避免与已经跑着的实例抢 27015。
say "5/6 smoke run"
cd "$REPO_DIR"
log="$(mktemp)"
"$GODOT_BIN" --headless --path . --quit-after 3 -- --host --port 0 >"$log" 2>&1 || true
if grep -qE 'SCRIPT ERROR|Parse Error|Cannot open|not found' "$log"; then
  echo "smoke run reported errors:" >&2
  cat "$log" >&2
  rm -f "$log"
  exit 1
fi
grep -E '^\[(session|feel|lan)\]' "$log" || true
rm -f "$log"
echo "smoke run clean"

# ---------------------------------------------------------------- 6. systemd

if [[ "$ENABLE_SERVICE" == "1" ]]; then
  say "6/6 install systemd service"
  # 用 template unit 而不是写死端口：设计文档 4.5 定的并发上限等于进程数，
  # 以后要多开几场对局，就是多启几个实例、每个占一个端口。
  # %i 是实例名，因此 `systemctl start moltenfrost@27016` 就是第二个房间。
  #
  # 对外地址（--advertise）要带上**每个房间自己的端口**：客户端是直连房间的，
  # 而目录里那一项就指向它。所以下面逐实例拼 --advertise <域名>:<该房的端口>。
  advertise_arg=""
  room_lobby_arg=""
  # 下面两个 heredoc **不要用引号包 EOF，也不要在这里写反引号或 $( )**：
  # 不加引号的 heredoc 会把内容当命令替换展开。这个坑已经真实踩到过——
  # 原来那条注释里写了一个反引号包住的 main.gd，于是写单元文件时它被当成命令执行，
  # 单元里的注释静默变成了残缺的一句（不报错，只是注释少了一段），
  # 后来因为文件里有 set -o pipefail 才以「main.gd: command not found」失败。
  # 要写 `命令名` 这类文字就写成普通文字，或者用 $(...) 的转义形式。
  if [[ -z "$ADVERTISE" ]]; then
    echo "WARNING: no --advertise given. On a cloud server IP.get_local_addresses() returns"
    echo "         only the VPC private address, so the address rooms register is unroutable"
    echo "         and the directory entries will point nowhere. Re-run with --advertise <domain>."
    # 不拼出 `--advertise :40001` 这种畸形参数：那会让房间拿一个空地址去登记，
    # 而目录会老老实实把它当地址存下来。宁可不传，让房间用自己的探测结果。
    advertise_arg=""
  else
    advertise_arg=" --advertise ${ADVERTISE}:%i"
  fi
  if [[ "$DIRECTORY" == "1" ]]; then
    # 停在大厅等人开局：谁先到谁当房主（见 main.gd 的 host_id）。
    room_lobby_arg=" --lobby"
  fi
  sudo tee "/etc/systemd/system/${SERVICE_NAME}@.service" >/dev/null <<EOF
[Unit]
Description=Moltenfrost dedicated room on port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}
ExecStart=${GODOT_BIN} --headless --path ${REPO_DIR} -- --host --port %i${advertise_arg} --directory 127.0.0.1:${DIRECTORY_PORT} --max-players ${MAX_PER_ROOM}${room_lobby_arg}
# 崩了就重启。服务端是无状态的（对局状态在内存里），重启只会让当前对局中断，
# 因此不需要额外的恢复逻辑，重连即可。
Restart=always
RestartSec=2
# 停止时发 SIGTERM（systemd 的默认）。**注意它不会让 Godot 走 _exit_tree**：
# 进程 8～24 毫秒就退出了，而 shutdown_gracefully() 那六轮 poll 本身要 240 毫秒。
# 因此真正让客户端立刻收到通知的是下面那条 ExecStop。
KillSignal=SIGTERM
# **停止前先请它自己退出。** Godot 收到 SIGTERM 是立刻退出、不走 _exit_tree，
# 于是 Net.shutdown_gracefully() 那六轮 poll 从未跑到，断开通知也就发不出来，
# 客户端只能等 5 秒心跳。这个脚本建一个哨兵文件并在脚本内等进程自己退出，
# 等到就不发 SIGTERM，游戏因此能走正常退出、把通知发出去。
# 等不到它只是退化成原来的行为，不会让停止变得不可靠。
# 实测参考：正常退出耗时约 240 毫秒（poll 六轮×40 毫秒）。
ExecStop=${REPO_DIR}/tools/graceful-stop.sh %i 8
# 上限取 25 秒：ExecStop 最多等 8 秒，加上正常退出的 240 毫秒与余量。
# 正常退出只要不到一秒，真卡住了也不该让关机/重启干等一分半——默认是 90 秒。
TimeoutStopSec=25
# 日志走 journald，用 journalctl -u moltenfrost@40001 -f 看。
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  if [[ ! -x "$REPO_DIR/tools/graceful-stop.sh" ]]; then
    chmod +x "$REPO_DIR/tools/graceful-stop.sh"
  fi
  echo "installed ${SERVICE_NAME}@.service"

  # ------------------------------------------------------------ 房间目录
  if [[ "$DIRECTORY" == "1" ]]; then
    # 目录只需要 python3（服务器自带）与这一个脚本，没有编译产物、没有额外依赖。
    # 之前那个 C 写的网关连编译都不需要了——它的转发职责已随路线 A 消失。
    #
    # TTL 6 秒、房间每 2 秒登记一次（三分之一）。进程被强杀时不会发"注销"，
    # 那种情况只能靠 TTL 把它从列表里清掉。
    sudo tee "/etc/systemd/system/${SERVICE_NAME}-directory.service" >/dev/null <<EOF
[Unit]
Description=Moltenfrost room directory on port ${DIRECTORY_PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}
ExecStart=/usr/bin/env python3 ${REPO_DIR}/tools/room-directory.py --port ${DIRECTORY_PORT} --ttl 6
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    echo "installed ${SERVICE_NAME}-directory.service"
  fi

  sudo systemctl daemon-reload

  # **更新代码之后必须重启正在跑的服务。**
  # 不重启的话进程里仍然是部署前那份代码，而磁盘上已经是新的——
  # 这与"bundle 只含已提交内容"是同一类陷阱：改了、传了、看着都对，
  # 但实际跑的不是那份代码。2026-09-26 就是这样白查了一轮：
  # 服务端日志里报的错误来自一个已经删掉的 RPC，而 git 版本显示的是新代码。
  # 只在服务已经在跑时重启；没跑就不要自作主张启动（部署与启动是两件事）。
  #
  # 目录模式下要重启的是**目录 + 每一间房**：那个 27015 上的单房间服务
  # 已经不是玩家的入口了（见下面的切换说明）。
  restart_list=()
  if [[ "$DIRECTORY" == "1" ]]; then
    for ((i = 0; i < ROOM_COUNT; i++)); do
      restart_list+=("${SERVICE_NAME}@$((ROOM_BASE_PORT + i))")
    done
    restart_list+=("${SERVICE_NAME}-directory")
  else
    restart_list+=("${SERVICE_NAME}@${PORT}")
  fi
  for unit in "${restart_list[@]}"; do
    if systemctl is-active --quiet "$unit"; then
      echo "restarting $unit to pick up the new code"
      sudo systemctl restart "$unit"
    else
      echo "$unit is not running"
    fi
  done

  if [[ "$DIRECTORY" == "1" ]]; then
    echo
    echo "DIRECTORY MODE (route A: rooms are reached directly)."
    echo "  directory : TCP ${DIRECTORY_PORT}"
    echo "  rooms     : UDP ${ROOM_BASE_PORT}..$((ROOM_BASE_PORT + ROOM_COUNT - 1)) (public, one per room)"
    echo
    echo "SECURITY GROUP must allow BOTH of these. Since the rooms listen publicly now,"
    echo "the old single-port arrangement (UDP ${PORT}) is no longer what players connect to."
    echo "Add: TCP:${DIRECTORY_PORT} and UDP:${ROOM_BASE_PORT}-$((ROOM_BASE_PORT + ROOM_COUNT - 1))"
    echo "(the UDP range may be extended later when more rooms are added)."
    echo
    echo "Bring the topology up:"
    echo "  sudo systemctl enable --now ${SERVICE_NAME}-directory"
    for ((i = 0; i < ROOM_COUNT; i++)); do
      echo "  sudo systemctl enable --now ${SERVICE_NAME}@$((ROOM_BASE_PORT + i))"
    done
    echo "  logs: journalctl -u ${SERVICE_NAME}-directory -f"
    echo "  check the listing: curl -s http://127.0.0.1:${DIRECTORY_PORT}/rooms"
  else
    echo "  start:  sudo systemctl start ${SERVICE_NAME}@${PORT}"
    echo "  enable: sudo systemctl enable ${SERVICE_NAME}@${PORT}"
    echo "  logs:   journalctl -u ${SERVICE_NAME}@${PORT} -f"
    echo "  stop:   sudo systemctl stop ${SERVICE_NAME}@${PORT}"
  fi
else
  say "6/6 systemd service skipped (--enable-service to install)"
  if systemctl is-active --quiet "${SERVICE_NAME}@${PORT}" 2>/dev/null; then
    echo "WARNING: ${SERVICE_NAME}@${PORT} is running but was NOT restarted,"
    echo "         so it may still be running the previous code."
    echo "         Restart it manually: sudo systemctl restart ${SERVICE_NAME}@${PORT}"
  fi
fi

say "done"
echo "repo:   $REPO_DIR"
echo "godot:  $GODOT_BIN"
