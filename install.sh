#!/usr/bin/env bash
# ==============================================================================
# derp-bootstrap：一键部署与维护私人 Tailscale DERP 中转节点
#
# 用法：
#   sudo bash install.sh              # 安装或按当前配置更新（默认）
#   sudo bash install.sh --update     # 升级 Tailscale 并重新编译对应版本的 derper
#   sudo bash install.sh --status     # 查看运行状态并打印 derpMap 配置
#   sudo bash install.sh --uninstall  # 卸载 derper 服务与证书
#   bash install.sh --help            # 查看帮助说明
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HERE}/derp.env"
UNIT_PATH="/etc/systemd/system/derper.service"
ENV_SYSTEM="/etc/derp-bootstrap.env"
CERT_DIR="/var/lib/derper/certs"
DERPER_BIN="/usr/local/bin/derper"
export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"

log()  { echo "[derp-bootstrap] $*"; }
warn() { echo "[derp-bootstrap] 提示：$*" >&2; }
fail() { echo "[derp-bootstrap] 错误：$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：sudo bash install.sh [选项]

选项：
  (无参数)      读取同目录下的 derp.env，完成安装或配置更新（可重复执行）
  --update      升级本机 Tailscale 并重新编译对齐版本的 derper
  --status      检查 derper / tailscaled 状态，并重新打印 derpMap JSON
  --uninstall   停止并卸载 derper 服务、systemd 单元及本地证书
  -h, --help    显示本帮助信息
EOF
}

ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   ACTION="install" ;;
    --update)    ACTION="update" ;;
    --status)    ACTION="status" ;;
    --uninstall) ACTION="uninstall" ;;
    -h|--help)   usage; exit 0 ;;
    *)           fail "未知参数：$1（使用 --help 查看用法）" ;;
  esac
  shift
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  fail "请使用 root 权限运行：sudo bash install.sh ${ACTION:+--${ACTION}}"
fi

# ------------------------------------------------------------------------------
# 读取并校验配置
# ------------------------------------------------------------------------------
load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *"="* ]] || fail "${file} 中有无法识别的行：${line}"
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then
      val="${val#\"}"
      val="${val%\"}"
    elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
      val="${val#\'}"
      val="${val%\'}"
    else
      # 去除未加引号时的行尾注释
      val="${val%%[[:space:]]#*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    case "$key" in
      DERP_HOSTNAME|TS_AUTHKEY|TS_HOSTNAME|TS_ADVERTISE_TAGS|DERP_REGION_ID|DERP_REGION_CODE|DERP_REGION_NAME|ACME_EMAIL|DERP_PORT|DERP_HTTP_PORT|DERP_STUN_PORT|DERP_VERIFY_CLIENTS|PUBLIC_IPV4)
        printf -v "$key" '%s' "$val"
        ;;
      *)
        fail "${file} 中包含未知配置项：${key}"
        ;;
    esac
  done < "$file"
}

init_config() {
  if [[ -f "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
  elif [[ "$ACTION" != "install" && -f "$ENV_SYSTEM" ]]; then
    log "未找到 ${ENV_FILE}，使用已安装的 ${ENV_SYSTEM} 配置。"
    load_env_file "$ENV_SYSTEM"
  else
    fail "找不到 ${ENV_FILE}。请先执行 cp derp.env.example derp.env 并填写配置。"
  fi

  DERP_HOSTNAME="${DERP_HOSTNAME:-}"
  TS_AUTHKEY="${TS_AUTHKEY:-}"
  TS_HOSTNAME="${TS_HOSTNAME:-}"
  TS_ADVERTISE_TAGS="${TS_ADVERTISE_TAGS-tag:derp}"
  DERP_REGION_ID="${DERP_REGION_ID:-900}"
  DERP_REGION_CODE="${DERP_REGION_CODE:-myderp}"
  DERP_REGION_NAME="${DERP_REGION_NAME:-My DERP}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  DERP_PORT="${DERP_PORT:-443}"
  DERP_HTTP_PORT="${DERP_HTTP_PORT:-80}"
  DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
  DERP_VERIFY_CLIENTS="${DERP_VERIFY_CLIENTS:-true}"
  PUBLIC_IPV4="${PUBLIC_IPV4:-}"

  [[ -n "$DERP_HOSTNAME" ]] || fail "请在 derp.env 中填写 DERP_HOSTNAME"
  [[ "$DERP_HOSTNAME" != *://* ]] || fail "DERP_HOSTNAME 只填域名，不要带 https://"
  [[ "$DERP_HOSTNAME" != "derp-sg.example.com" ]] || fail "DERP_HOSTNAME 仍是示例域名，请修改为你自己的真实域名"
  [[ "$DERP_REGION_ID" =~ ^9[0-9][0-9]$ ]] || fail "DERP_REGION_ID 必须是 900–999 之间的整数（当前：${DERP_REGION_ID}）"
  [[ "$DERP_PORT" =~ ^[0-9]+$ ]] && (( DERP_PORT >= 1 && DERP_PORT <= 65535 )) || fail "DERP_PORT 必须是 1–65535 之间的端口"
  [[ "$DERP_HTTP_PORT" =~ ^[0-9]+$ ]] && (( DERP_HTTP_PORT >= 1 && DERP_HTTP_PORT <= 65535 )) || fail "DERP_HTTP_PORT 必须是 1–65535 之间的端口"
  [[ "$DERP_STUN_PORT" =~ ^[0-9]+$ ]] && (( DERP_STUN_PORT >= 1 && DERP_STUN_PORT <= 65535 )) || fail "DERP_STUN_PORT 必须是 1–65535 之间的端口"
  [[ "$DERP_VERIFY_CLIENTS" == "true" || "$DERP_VERIFY_CLIENTS" == "false" ]] || fail "DERP_VERIFY_CLIENTS 只能是 true 或 false"

  if [[ -z "$TS_HOSTNAME" ]]; then
    TS_HOSTNAME="${DERP_HOSTNAME%%.*}"
  fi
}

# ------------------------------------------------------------------------------
# 系统环境与网络辅助函数
# ------------------------------------------------------------------------------
wait_apt_lock() {
  command -v apt-get >/dev/null 2>&1 || return 0
  local i lock="/var/lib/dpkg/lock-frontend"
  [[ -e "$lock" ]] || return 0
  for i in $(seq 1 60); do
    if command -v flock >/dev/null 2>&1; then
      if flock --exclusive --nonblock "$lock" --command true 2>/dev/null; then
        return 0
      fi
    elif command -v fuser >/dev/null 2>&1; then
      if ! fuser "$lock" >/dev/null 2>&1; then
        return 0
      fi
    else
      return 0
    fi
    if [[ "$i" -eq 1 ]]; then
      log "等待系统自动更新释放软件包锁（最多约 5 分钟）……"
    fi
    sleep 5
  done
  fail "软件包锁仍被占用（常见于系统后台正在运行 unattended-upgrades）。请稍等几分钟后再执行。"
}

install_pkgs() {
  log "安装系统基础依赖……"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    wait_apt_lock
    apt-get update -y
    apt-get install -y curl ca-certificates dnsutils iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates bind-utils iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates bind-utils iproute
  else
    fail "未识别的包管理器，请使用 Ubuntu、Debian、Alibaba Cloud Linux 或 CentOS/Rocky/AlmaLinux。"
  fi
}

public_ipv4() {
  if [[ -n "${PUBLIC_IPV4:-}" ]]; then
    printf '%s' "$PUBLIC_IPV4"
    return 0
  fi
  local ip=""
  for endpoint in \
    "https://ip.sb" \
    "https://ifconfig.me" \
    "https://api.ipify.org" \
    "http://100.100.100.200/latest/meta-data/eipv4" \
    "http://100.100.100.200/latest/meta-data/public-ipv4"; do
    ip="$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  fail "无法自动探测本机公网 IPv4。请检查 VPS 出网连接，或在 derp.env 中手动指定 PUBLIC_IPV4。"
}

public_ipv6() {
  local ip=""
  for endpoint in "https://ifconfig.co" "https://api6.ipify.org"; do
    ip="$(curl -6 -fsS --max-time 4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" == *:* ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
}

wait_dns() {
  local want="$1" host="$2" got="" i
  log "检查域名 ${host} 是否已解析到 ${want} ……"
  for i in $(seq 1 36); do
    local dns
    for dns in 223.5.5.5 1.1.1.1 8.8.8.8 ""; do
      if [[ -n "$dns" ]]; then
        got="$(dig +short +time=2 +tries=1 A "$host" "@$dns" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)"
      else
        got="$(dig +short +time=2 +tries=1 A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)"
      fi
      if [[ "$got" == "$want" ]]; then
        log "DNS 解析验证通过：${host} → ${got}"
        return 0
      fi
    done
    if [[ "$i" -eq 1 ]]; then
      log "当前解析结果为「${got:-空}」，正在等待 DNS 生效（最多约 3 分钟）……"
    fi
    sleep 5
  done
  fail "域名 ${host} 当前解析为「${got:-空}」，与本机公网 IP（${want}）不一致。请检查 DNS 服务商处的 A 记录（确保未开启 CDN 代理），生效后重新运行本脚本。"
}

check_port_conflicts() {
  command -v ss >/dev/null 2>&1 || return 0
  local port proc
  for port in "$DERP_HTTP_PORT" "$DERP_PORT"; do
    proc="$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -v 'derper' | tail -n +2 || true)"
    if [[ -n "$proc" ]]; then
      fail "TCP 端口 ${port} 已被其他程序占用，derper 无法绑定。请先停止占用该端口的服务（如 nginx/apache/caddy）或修改 derp.env 中的端口配置：\n${proc}"
    fi
  done
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    log "检测到系统防火墙 ufw 已启用，正在放行 ${DERP_HTTP_PORT}/tcp、${DERP_PORT}/tcp、${DERP_STUN_PORT}/udp……"
    ufw allow "${DERP_HTTP_PORT}/tcp" >/dev/null
    ufw allow "${DERP_PORT}/tcp" >/dev/null
    ufw allow "${DERP_STUN_PORT}/udp" >/dev/null
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    log "检测到系统防火墙 firewalld 已启用，正在放行 ${DERP_HTTP_PORT}/tcp、${DERP_PORT}/tcp、${DERP_STUN_PORT}/udp……"
    firewall-cmd --permanent --add-port="${DERP_HTTP_PORT}/tcp" >/dev/null || true
    firewall-cmd --permanent --add-port="${DERP_PORT}/tcp" >/dev/null || true
    firewall-cmd --permanent --add-port="${DERP_STUN_PORT}/udp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
  # 不主动开启未启用的系统防火墙，避免意外阻断 SSH；云主机主要由云安全组控制。
}

# ------------------------------------------------------------------------------
# Tailscale 安装与入网
# ------------------------------------------------------------------------------
is_tailscale_running() {
  command -v tailscale >/dev/null 2>&1 && \
    tailscale status --json 2>/dev/null | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'
}

install_or_update_tailscale() {
  local force_update="${1:-0}"
  if ! command -v tailscale >/dev/null 2>&1 || [[ "$force_update" -eq 1 ]]; then
    log "正在安装/更新 Tailscale……"
    wait_apt_lock
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    log "已安装 Tailscale（$(tailscale version | head -n1)），跳过安装。"
  fi
  systemctl enable --now tailscaled
}

join_tailnet() {
  local need_auth=1
  if is_tailscale_running; then
    need_auth=0
    log "本机已处于 Tailscale 网络中，无需重新使用 Auth Key。"
  fi

  local up_flags=(
    --hostname="$TS_HOSTNAME"
    --accept-dns=false
    --ssh=false
  )
  if [[ -n "$TS_ADVERTISE_TAGS" ]]; then
    up_flags+=(--advertise-tags="$TS_ADVERTISE_TAGS")
  fi

  if [[ "$need_auth" -eq 1 ]]; then
    [[ -n "$TS_AUTHKEY" ]] || fail "本机尚未登录 Tailscale，请在 derp.env 中填写有效的 TS_AUTHKEY（或先手动执行 tailscale up 完成登录）。"
    [[ "$TS_AUTHKEY" == tskey-auth-* ]] || fail "TS_AUTHKEY 格式不正确，应以 tskey-auth- 开头。"
    [[ "$TS_AUTHKEY" != "tskey-auth-xxxxxxxx" ]] || fail "TS_AUTHKEY 仍是示例值，请填入真实的 Tailscale 授权密钥。"

    log "正在使用 Auth Key 将本机加入 Tailscale 网络……"
    if ! tailscale up --auth-key="$TS_AUTHKEY" "${up_flags[@]}"; then
      fail "加入 Tailscale 失败。请检查：1) TS_AUTHKEY 是否未过期；2) 若启用了标签（${TS_ADVERTISE_TAGS:-无}），请确保已在 Tailscale ACL 的 tagOwners 中声明该标签，且密钥是在保存 ACL 之后生成的。"
    fi

    if [[ -f "$ENV_FILE" ]]; then
      umask 077
      local tmp
      tmp="$(mktemp)"
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*TS_AUTHKEY= ]]; then
          echo "TS_AUTHKEY="
        else
          printf '%s\n' "$line"
        fi
      done < "$ENV_FILE" > "$tmp"
      mv "$tmp" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      log "已从服务器上的 derp.env 中擦除 TS_AUTHKEY。"
    fi
  else
    log "同步 Tailscale 节点名称与标签设置……"
    local set_flags=(--hostname="$TS_HOSTNAME" --accept-dns=false)
    if [[ -n "$TS_ADVERTISE_TAGS" ]]; then
      set_flags+=(--advertise-tags="$TS_ADVERTISE_TAGS")
    fi
    tailscale set "${set_flags[@]}" 2>/dev/null || tailscale up "${up_flags[@]}"
  fi

  is_tailscale_running || fail "Tailscale 未处于 Running 状态，请执行 tailscale status 检查。"
}

# ------------------------------------------------------------------------------
# Go 环境与 derper 编译
# ------------------------------------------------------------------------------
go_version_from_url() {
  local ver
  ver="$(curl -4 -fsSL --connect-timeout 8 --max-time 15 "$1" 2>/dev/null | head -n1 | tr -d '[:space:]')" || true
  if [[ "$ver" =~ ^go1\.[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$ver"
    return 0
  fi
  return 1
}

go_version_from_listing() {
  local ver
  ver="$(curl -4 -fsSL --connect-timeout 8 --max-time 15 "$1" 2>/dev/null | grep -oE 'go1\.[0-9]+(\.[0-9]+)?\.linux-amd64\.tar\.gz' | sed 's/\.linux-amd64\.tar\.gz//' | sort -t. -k2,2n -k3,3n | tail -1)" || true
  if [[ "$ver" =~ ^go1\.[0-9]+ ]]; then
    printf '%s' "$ver"
    return 0
  fi
  return 1
}

download_go_tarball() {
  local url="$1" dest="$2"
  log "尝试下载 Go 安装包：${url}"
  rm -f "$dest"
  if curl -4 -fL --connect-timeout 15 --retry 3 --retry-delay 2 --speed-limit 1000 --speed-time 30 -o "$dest" "$url"; then
    if tar -tzf "$dest" >/dev/null 2>&1; then
      return 0
    fi
    warn "下载的文件校验不通过，自动切换下一个源……"
  else
    warn "下载失败或超时，自动切换下一个源……"
  fi
  rm -f "$dest"
  return 1
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    local cur_minor
    cur_minor="$(go version 2>/dev/null | grep -oE 'go1\.[0-9]+' | head -n1 | cut -d. -f2 || echo 0)"
    if [[ "$cur_minor" =~ ^[0-9]+$ ]] && (( cur_minor >= 22 )); then
      log "已安装满足要求的 Go 环境：$(go version)"
      return 0
    fi
    log "当前 Go 版本较旧（$(go version 2>/dev/null || echo 未知)），将升级至新版 Go……"
  fi

  local ver arch tarball dest url
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)             fail "不支持的 CPU 架构：$(uname -m)" ;;
  esac

  ver="$(go_version_from_url 'https://go.dev/VERSION?m=text' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_url 'https://golang.google.cn/VERSION?m=text' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_listing 'https://mirrors.aliyun.com/golang/' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_listing 'https://mirrors.cloud.aliyuncs.com/golang/' || true)"
  [[ -n "$ver" ]] || fail "无法获取最新 Go 版本号，请检查 VPS 网络与 DNS 设置。"

  tarball="${ver}.linux-${arch}.tar.gz"
  dest="/tmp/${tarball}"
  log "正在安装 ${ver}（${arch}）……"
  url=""
  for url in \
      "https://go.dev/dl/${tarball}" \
      "https://golang.google.cn/dl/${tarball}" \
      "https://mirrors.aliyun.com/golang/${tarball}" \
      "https://mirrors.cloud.aliyuncs.com/golang/${tarball}"; do
    download_go_tarball "$url" "$dest" && break
    url=""
  done
  [[ -n "$url" && -f "$dest" ]] || fail "从官方源及国内镜像下载 Go 均失败，请检查网络连接后重试。"

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$dest"
  rm -f "$dest"
  ln -sfn /usr/local/go/bin/go /usr/local/bin/go
  log "Go 安装完成：$(go version)"
}

install_derper() {
  local ts_ver tag
  ts_ver="$(tailscale version | head -n1 | tr -d '[:space:]')"
  [[ -n "$ts_ver" ]] || fail "无法读取本机 tailscale 版本。"
  tag="v${ts_ver}"

  log "正在编译 derper（对齐本机 Tailscale ${ts_ver}）……"
  umask 022
  export GOBIN="/usr/local/bin"
  export GOTOOLCHAIN="auto"

  if [[ -z "${GOPROXY:-}" ]]; then
    if curl -4 -fsS --connect-timeout 3 --max-time 5 "https://proxy.golang.org" >/dev/null 2>&1; then
      export GOPROXY="https://proxy.golang.org,https://goproxy.cn,direct"
    else
      export GOPROXY="https://goproxy.cn,direct"
      export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
    fi
  fi
  log "使用 GOPROXY=${GOPROXY}"

  if ! (cd /tmp && go install "tailscale.com/cmd/derper@${tag}"); then
    warn "按精确版本 ${tag} 编译未成功，尝试使用 @latest 编译……"
    (cd /tmp && go install "tailscale.com/cmd/derper@latest") || \
      fail "编译 derper 失败。请检查网络连接，或手动指定 GOPROXY 后重试。"
  fi
  [[ -x "$DERPER_BIN" ]] || fail "未找到编译产物 ${DERPER_BIN}"
  log "derper 安装成功：${DERPER_BIN}"
}

# ------------------------------------------------------------------------------
# Systemd 服务管理与健康检查
# ------------------------------------------------------------------------------
write_unit() {
  mkdir -p "$CERT_DIR"
  chmod 700 /var/lib/derper
  umask 077
  cat > "$ENV_SYSTEM" <<EOF
DERP_HOSTNAME=${DERP_HOSTNAME}
ACME_EMAIL=${ACME_EMAIL}
DERP_PORT=${DERP_PORT}
DERP_HTTP_PORT=${DERP_HTTP_PORT}
DERP_STUN_PORT=${DERP_STUN_PORT}
DERP_VERIFY_CLIENTS=${DERP_VERIFY_CLIENTS}
DERP_REGION_ID=${DERP_REGION_ID}
DERP_REGION_CODE=${DERP_REGION_CODE}
DERP_REGION_NAME="${DERP_REGION_NAME}"
EOF
  chmod 600 "$ENV_SYSTEM"

  local extra_flags=()
  if [[ "$DERP_VERIFY_CLIENTS" == "true" ]]; then
    extra_flags+=("--verify-clients")
  fi
  if [[ -n "$ACME_EMAIL" ]]; then
    extra_flags+=("--acme-email=\${ACME_EMAIL}")
  fi

  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Tailscale Custom DERP Relay Server (derp-bootstrap)
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=simple
EnvironmentFile=${ENV_SYSTEM}
ExecStart=${DERPER_BIN} --hostname=\${DERP_HOSTNAME} --a=:\${DERP_PORT} --http-port=\${DERP_HTTP_PORT} --stun --stun-port=\${DERP_STUN_PORT} --certmode=letsencrypt --certdir=${CERT_DIR} ${extra_flags[*]}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT_PATH"
  systemctl daemon-reload
  systemctl enable derper.service
  systemctl restart derper.service
}

wait_healthy() {
  local ipv4="$1" i url
  if [[ "$DERP_PORT" == "443" ]]; then
    url="https://${DERP_HOSTNAME}/"
  else
    url="https://${DERP_HOSTNAME}:${DERP_PORT}/"
  fi
  log "等待 derper 启动并完成 Let's Encrypt 证书签发（首次通常需 10–60 秒）……"
  for i in $(seq 1 24); do
    if systemctl is-active --quiet derper.service; then
      if curl -4 -fsS --max-time 15 --resolve "${DERP_HOSTNAME}:${DERP_PORT}:${ipv4}" -o /dev/null "$url" 2>/dev/null; then
        log "HTTPS 与 TLS 证书验证通过：${url}"
        return 0
      fi
    fi
    sleep 4
  done
  echo
  echo "------ derper 最近日志 ------"
  journalctl -u derper.service -n 40 --no-pager || true
  echo "----------------------------"
  fail "derper 服务已启动，但无法通过 ${url} 完成 HTTPS 验证。请检查上方日志：常见原因为云安全组未放行 TCP ${DERP_HTTP_PORT}/${DERP_PORT} 端口，或域名开启了 CDN 代理。"
}

print_derpmap() {
  local ipv4="$1" ipv6="${2:-none}"
  [[ -n "$ipv6" ]] || ipv6="none"
  cat <<EOF

======================== 部署完成 ========================

请打开 Tailscale 权限控制页面：
  https://login.tailscale.com/admin/acls

将以下 "derpMap" 配置合并到策略 JSON 的最外层（保留原有规则，切勿直接清空覆盖整个文件）。
若你已有 "derpMap"，请将下方的 "${DERP_REGION_ID}" 区域对象合并进现有的 "Regions" 中：

"derpMap": {
  "Regions": {
    "${DERP_REGION_ID}": {
      "RegionID": ${DERP_REGION_ID},
      "RegionCode": "${DERP_REGION_CODE}",
      "RegionName": "${DERP_REGION_NAME}",
      "Nodes": [
        {
          "Name": "${DERP_REGION_ID}a",
          "RegionID": ${DERP_REGION_ID},
          "HostName": "${DERP_HOSTNAME}",
          "IPv4": "${ipv4}",
          "IPv6": "${ipv6}",
          "STUNPort": ${DERP_STUN_PORT},
          "DERPPort": ${DERP_PORT}
        }
      ]
    }
  }
}

提示：
1. 节点中已显式写入 "IPv4" 与 "IPv6"，可防止客户端开启代理（Fake-IP）时解析错误。
2. 每个 RegionID（900–999）只能对应一个区域；后续新增其他 DERP 服务器时请使用 901、902……
3. 保存 ACL 策略后，在任意已登录 Tailscale 的设备上运行以下命令验证：
     tailscale netcheck

日常维护命令：
  sudo bash install.sh --status      # 查看运行状态与 derpMap
  sudo bash install.sh --update      # 升级 Tailscale 与 derper
  sudo bash install.sh --uninstall   # 卸载 derper 服务
  sudo journalctl -u derper -f       # 查看实时日志
==========================================================
EOF
}

# ------------------------------------------------------------------------------
# 子命令执行流程
# ------------------------------------------------------------------------------
do_uninstall() {
  log "正在停止并卸载 derper 服务……"
  if systemctl list-unit-files 2>/dev/null | grep -q '^derper\.service'; then
    systemctl stop derper.service 2>/dev/null || true
    systemctl disable derper.service 2>/dev/null || true
  fi
  rm -f "$UNIT_PATH" "$ENV_SYSTEM" "$DERPER_BIN"
  rm -rf /var/lib/derper
  systemctl daemon-reload
  log "derper 服务、证书及配置文件已卸载完成。"
  log "注：Tailscale 客户端与 Go 环境已保留；如需移除可执行：tailscale logout && apt-get remove -y tailscale"
}

do_status() {
  init_config
  local pub4 pub6
  pub4="$(public_ipv4)"
  pub6="$(public_ipv6 || true)"
  echo "------ 服务运行状态 ------"
  echo "Tailscale 状态："
  if is_tailscale_running; then
    echo "  [运行中] $(tailscale version | head -n1)"
  else
    echo "  [未运行或未登录]"
  fi
  echo "derper 服务状态："
  systemctl status derper.service --no-pager -l || true
  print_derpmap "$pub4" "$pub6"
}

do_update() {
  init_config
  install_pkgs
  local pub4 pub6
  pub4="$(public_ipv4)"
  pub6="$(public_ipv6 || true)"
  install_or_update_tailscale 1
  install_go
  install_derper
  write_unit
  wait_healthy "$pub4"
  print_derpmap "$pub4" "$pub6"
}

do_install() {
  init_config
  install_pkgs
  local pub4 pub6
  pub4="$(public_ipv4)"
  pub6="$(public_ipv6 || true)"
  log "本机公网 IPv4：${pub4}"
  [[ -n "$pub6" ]] && log "本机公网 IPv6：${pub6}"
  wait_dns "$pub4" "$DERP_HOSTNAME"
  check_port_conflicts
  configure_firewall
  install_or_update_tailscale 0
  join_tailnet
  install_go
  install_derper
  write_unit
  wait_healthy "$pub4"
  print_derpmap "$pub4" "$pub6"
}

case "$ACTION" in
  install)   do_install ;;
  update)    do_update ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
esac
