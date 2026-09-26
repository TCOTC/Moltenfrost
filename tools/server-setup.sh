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

set -euo pipefail

GODOT_VERSION="4.7.2"
GODOT_PREFIX="/opt/godot"
GODOT_BIN="${GODOT_PREFIX}/godot"
REPO_DIR="${HOME}/moltenfrost"
SERVICE_NAME="moltenfrost"

GODOT_ZIP=""
BUNDLE=""
PORT="27015"
ADVERTISE=""
ENABLE_SERVICE=0
SKIP_IMPORT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --godot-zip) GODOT_ZIP="$2"; shift 2 ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --advertise) ADVERTISE="$2"; shift 2 ;;
    --enable-service) ENABLE_SERVICE=1; shift ;;
    --skip-import) SKIP_IMPORT=1; shift ;;
    --godot-prefix) GODOT_PREFIX="$2"; GODOT_BIN="${GODOT_PREFIX}/godot"; shift 2 ;;
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
  # 对外地址（--advertise）写死在单元里而不是做成另一个实例参数：
  # 同一台机器上多开时每个端口对外的地址是同一个域名，逐实例传反而容易漏。
  advertise_arg=""
  if [[ -n "$ADVERTISE" ]]; then
    advertise_arg=" --advertise ${ADVERTISE}"
  else
    echo "WARNING: no --advertise given. On a cloud server IP.get_local_addresses() returns"
    echo "         only the VPC private address, so the 'others should join at' log line will"
    echo "         be useless. Re-run with --advertise <domain-or-ip>."
  fi
  sudo tee "/etc/systemd/system/${SERVICE_NAME}@.service" >/dev/null <<EOF
[Unit]
Description=Moltenfrost dedicated server on port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}
ExecStart=${GODOT_BIN} --headless --path ${REPO_DIR} -- --host --port %i${advertise_arg}
# 崩了就重启。服务端是无状态的（对局状态在内存里），重启只会让当前对局中断，
# 因此不需要额外的恢复逻辑，重连即可。
Restart=always
RestartSec=2
# 停止时的行为。默认就是 SIGTERM，这里写出来是为了让意图可见：
# Godot 收到 SIGTERM 后会走正常的退出流程，`main.gd` 的 _exit_tree 因此能跑到、
# 可以由服务端主动向客户端发断开通知（客户端因此不必等超时）。实测 0.4 秒内完成。
KillSignal=SIGTERM
# 上限取 15 秒而不是默认的 90 秒：正常退出只要不到一秒，真卡住了也不该让
# 关机/重启干等一分半。超时之后 systemd 会发 SIGKILL，此时客户端的
# 心跳判定负责发现服务端下线。
TimeoutStopSec=15
# 日志走 journald，用 journalctl -u moltenfrost@27015 -f 看。
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  echo "installed ${SERVICE_NAME}@.service"
  echo "  start:  sudo systemctl start ${SERVICE_NAME}@${PORT}"
  echo "  enable: sudo systemctl enable ${SERVICE_NAME}@${PORT}"
  echo "  logs:   journalctl -u ${SERVICE_NAME}@${PORT} -f"
  echo "  stop:   sudo systemctl stop ${SERVICE_NAME}@${PORT}"
else
  say "6/6 systemd service skipped (--enable-service to install)"
fi

say "done"
echo "repo:   $REPO_DIR"
echo "godot:  $GODOT_BIN"
