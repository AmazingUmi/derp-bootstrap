#!/usr/bin/env bash
# derp-bootstrap：在 VPS 上一键安装私人 Tailscale DERP 中转。
# 用法（在 VPS 上）：sudo bash install.sh
# 需与 derp.env 放在同一目录。
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash install.sh"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${HERE}/derp.env"
UNIT_PATH="/etc/systemd/system/derper.service"
ENV_SYSTEM="/etc/derp-bootstrap.env"
CERT_DIR="/var/lib/derper/certs"
DERPER_BIN="/usr/local/bin/derper"
export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"

log()  { echo "[derp-bootstrap] $*"; }
fail() { echo "[derp-bootstrap] 错误：$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || fail "找不到 ${ENV_FILE}。请先填写 derp.env 并和 install.sh 一起上传。"

# 只读取 KEY=VALUE，忽略注释和空行，避免配置里出现命令替换
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" == *"="* ]] || fail "derp.env 有无法识别的行：${line}"
  key="${line%%=*}"
  val="${line#*=}"
  key="${key%"${key##*[![:space:]]}"}"
  key="${key#"${key%%[![:space:]]*}"}"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  case "$key" in
    DERP_HOSTNAME|TS_AUTHKEY|TS_HOSTNAME|TS_ADVERTISE_TAGS|DERP_REGION_ID|DERP_REGION_CODE|DERP_REGION_NAME|ACME_EMAIL)
      printf -v "$key" '%s' "$val"
      ;;
    *)
      fail "derp.env 里有未知配置项：${key}"
      ;;
  esac
done < "$ENV_FILE"

DERP_HOSTNAME="${DERP_HOSTNAME:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
TS_ADVERTISE_TAGS="${TS_ADVERTISE_TAGS:-tag:derp}"
DERP_REGION_ID="${DERP_REGION_ID:-900}"
DERP_REGION_CODE="${DERP_REGION_CODE:-myderp}"
DERP_REGION_NAME="${DERP_REGION_NAME:-My DERP}"
ACME_EMAIL="${ACME_EMAIL:-}"

[[ -n "$DERP_HOSTNAME" ]] || fail "请在 derp.env 里填写 DERP_HOSTNAME"
[[ "$DERP_HOSTNAME" != *://* ]] || fail "DERP_HOSTNAME 只填域名，不要带 https://"
[[ "$DERP_HOSTNAME" != derp-sg.example.com ]] || fail "DERP_HOSTNAME 还是示例域名，请改成你自己的"
[[ "$DERP_REGION_ID" =~ ^9[0-9][0-9]$ ]] || fail "DERP_REGION_ID 必须是 900–999 之间的整数"

if [[ -z "$TS_HOSTNAME" ]]; then
  TS_HOSTNAME="${DERP_HOSTNAME%%.*}"
fi

need_auth=1
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status --json 2>/dev/null | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
    need_auth=0
    log "本机已经加入 Tailscale，不再使用 auth key。"
  fi
fi
if [[ "$need_auth" -eq 1 ]]; then
  [[ -n "$TS_AUTHKEY" ]] || fail "请在 derp.env 里填写 TS_AUTHKEY"
  [[ "$TS_AUTHKEY" == tskey-auth-* ]] || fail "TS_AUTHKEY 应以 tskey-auth- 开头"
  [[ "$TS_AUTHKEY" != tskey-auth-xxxxxxxx ]] || fail "TS_AUTHKEY 还是示例值，请填入真实密钥"
fi

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
  fail "软件包锁仍被占用（常见于 unattended-upgrades 正在运行）。请等几分钟后再执行：sudo bash install.sh"
}

install_pkgs() {
  log "安装系统依赖……"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    wait_apt_lock
    apt-get update -y
    apt-get install -y curl ca-certificates dnsutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates bind-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates bind-utils
  else
    fail "未识别的系统，请使用 Ubuntu、Debian 或 Alibaba Cloud Linux / CentOS。"
  fi
}

public_ipv4() {
  local ip=""
  # 阿里云元数据（EIP / 固定公网 IP）
  ip="$(curl -4 -fsS --max-time 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 8 https://ip.sb 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  [[ -n "$ip" ]] || fail "无法探测本机公网 IPv4。请检查出网是否正常。"
  printf '%s' "$ip"
}

public_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS --max-time 5 https://ifconfig.co 2>/dev/null || true)"
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  if [[ "$ip" == *:* ]]; then
    printf '%s' "$ip"
  fi
}

wait_dns() {
  local want="$1" host="$2" got="" i
  log "等待域名 ${host} 解析到 ${want} ……"
  for i in $(seq 1 36); do
    local dns
    for dns in 223.5.5.5 223.6.6.6 8.8.8.8 ""; do
      if [[ -n "$dns" ]]; then
        got="$(dig +short +time=2 +tries=1 A "$host" "@$dns" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)"
      else
        got="$(dig +short +time=2 +tries=1 A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)"
      fi
      if [[ "$got" == "$want" ]]; then
        log "DNS 已生效：${host} → ${got}"
        return 0
      fi
    done
    sleep 5
  done
  fail "域名 ${host} 当前解析是「${got:-空}」，期望是 ${want}。请到阿里云「云解析 DNS」检查 A 记录是否已生效，然后再跑一次本脚本。"
}

maybe_ufw() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    log "检测到系统防火墙 ufw 已开启，正在放行 80/tcp、443/tcp、3478/udp。"
    ufw allow 80/tcp  >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 3478/udp >/dev/null
    ufw allow proto icmp >/dev/null 2>&1 || true
  fi
  # 不主动启用 ufw，避免把 SSH 锁死；阿里云主要靠安全组。
}

install_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "安装 Tailscale……"
    wait_apt_lock
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    log "已安装 Tailscale，跳过。"
  fi
  systemctl enable --now tailscaled
}

join_tailnet() {
  local up_flags=(
    --hostname="$TS_HOSTNAME"
    --advertise-tags="$TS_ADVERTISE_TAGS"
    --accept-dns=false
    --ssh=false
  )
  if [[ "$need_auth" -eq 1 ]]; then
    log "正在把本机加入 Tailscale 网络……"
    tailscale up --auth-key="$TS_AUTHKEY" "${up_flags[@]}"
    # 从服务器上的配置表抹掉密钥，本地电脑上的 derp.env 不受影响
    umask 077
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == TS_AUTHKEY=* ]]; then
        echo "TS_AUTHKEY="
      else
        printf '%s\n' "$line"
      fi
    done < "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "已从服务器上的 derp.env 清除 TS_AUTHKEY。"
  else
    log "更新 Tailscale 设备名和标签……"
    tailscale set --hostname="$TS_HOSTNAME" --advertise-tags="$TS_ADVERTISE_TAGS" --accept-dns=false || \
      tailscale up "${up_flags[@]}"
  fi
  tailscale status >/dev/null || fail "加入 Tailscale 失败。请确认 auth key 有效，并且 ACL 里已设置 tagOwners（tag:derp）。"
}

go_version_from_url() {
  local ver
  ver="$(curl -4 -fsSL --connect-timeout 10 --max-time 20 "$1" | head -n1)" || true
  if [[ "$ver" == go1.* ]]; then
    printf '%s' "$ver"
    return 0
  fi
  return 1
}

go_version_from_listing() {
  local ver
  ver="$(curl -4 -fsSL --connect-timeout 10 --max-time 20 "$1" | grep -oE 'go1\.[0-9]+\.[0-9]+\.linux-amd64\.tar\.gz' | sed 's/\.linux-amd64\.tar\.gz//' | sort -t. -k2,2n -k3,3n | tail -1)" || true
  if [[ "$ver" == go1.* ]]; then
    printf '%s' "$ver"
    return 0
  fi
  return 1
}

download_go_tarball() {
  local url="$1" dest="$2"
  log "尝试下载：${url}"
  rm -f "$dest"
  if curl -4 -fL --connect-timeout 15 --retry 3 --retry-delay 2 --speed-limit 1000 --speed-time 30 -o "$dest" "$url"; then
    if tar -tzf "$dest" >/dev/null 2>&1; then
      return 0
    fi
    log "下载的文件不是有效的 Go 安装包，换源再试。"
  else
    log "下载失败或卡住，换源再试。"
  fi
  rm -f "$dest"
  return 1
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    log "已安装 Go：$(go version)"
    return 0
  fi
  local ver arch tarball dest url
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) fail "不支持的 CPU 架构：$(uname -m)" ;;
  esac

  ver="$(go_version_from_url 'https://golang.google.cn/VERSION?m=text' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_url 'https://go.dev/VERSION?m=text' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_listing 'https://mirrors.cloud.aliyuncs.com/golang/' || true)"
  [[ -n "$ver" ]] || ver="$(go_version_from_listing 'https://mirrors.aliyun.com/golang/' || true)"
  [[ -n "$ver" ]] || fail "无法获取 Go 版本号。请检查 VPS 出网和 DNS（建议 阿里云 VPC DNS 加 223.5.5.5）。"

  tarball="${ver}.linux-${arch}.tar.gz"
  dest="/tmp/${tarball}"
  log "安装 ${ver}（${arch}）……"
  url=""
  for url in \
      "https://mirrors.cloud.aliyuncs.com/golang/${tarball}" \
      "https://mirrors.aliyun.com/golang/${tarball}" \
      "https://golang.google.cn/dl/${tarball}" \
      "https://go.dev/dl/${tarball}"; do
    download_go_tarball "$url" "$dest" && break
    url=""
  done
  [[ -n "$url" && -f "$dest" ]] || fail "从国内镜像和 go.dev 下载 Go 都失败了。请检查出网后重试。"

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$dest"
  rm -f "$dest"
  ln -sfn /usr/local/go/bin/go /usr/local/bin/go
  log "$(go version)"
}

install_derper() {
  local ts_ver tag
  ts_ver="$(tailscale version | head -n1 | tr -d '[:space:]')"
  [[ -n "$ts_ver" ]] || fail "无法读取 tailscale 版本。"
  # 与本机 tailscaled 尽量同一版本，满足 --verify-clients 的兼容要求
  tag="v${ts_ver}"
  log "编译 derper（对齐 Tailscale ${ts_ver}）……"
  umask 022
  export GOBIN="/usr/local/bin"
  export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
  export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
  log "使用 GOPROXY=${GOPROXY}"
  if ! go install "tailscale.com/cmd/derper@${tag}"; then
    log "按精确版本编译失败，改用 @latest 再试一次……"
    go install tailscale.com/cmd/derper@latest || fail "编译 derper 失败。请检查出网，或手动设置 GOPROXY（国内可用 https://goproxy.cn,direct）。"
  fi
  [[ -x "$DERPER_BIN" ]] || fail "未找到 ${DERPER_BIN}"
  log "derper 已安装：$("$DERPER_BIN" --version 2>/dev/null || echo "$DERPER_BIN")"
}

write_unit() {
  mkdir -p "$CERT_DIR"
  chmod 700 /var/lib/derper
  umask 077
  cat > "$ENV_SYSTEM" <<EOF
DERP_HOSTNAME=${DERP_HOSTNAME}
ACME_EMAIL=${ACME_EMAIL}
EOF
  chmod 600 "$ENV_SYSTEM"

  local email_flag=""
  if [[ -n "$ACME_EMAIL" ]]; then
    email_flag="--acme-email=\${ACME_EMAIL}"
  fi

  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Tailscale custom DERP server (derp-bootstrap)
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=simple
EnvironmentFile=${ENV_SYSTEM}
ExecStart=${DERPER_BIN} --hostname=\${DERP_HOSTNAME} --a=:443 --http-port=80 --stun --stun-port=3478 --certmode=letsencrypt --certdir=${CERT_DIR} --verify-clients ${email_flag}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable derper.service
  systemctl restart derper.service
}

wait_healthy() {
  local i
  log "等待 derper 启动并申请证书（可能需要一两分钟）……"
  for i in $(seq 1 30); do
    if systemctl is-active --quiet derper.service; then
      if curl -fsS --max-time 5 -o /dev/null "https://${DERP_HOSTNAME}/" 2>/dev/null; then
        log "derper 已在 https://${DERP_HOSTNAME}/ 正常响应。"
        return 0
      fi
    fi
    sleep 4
  done
  echo
  echo "------ derper 最近日志 ------"
  journalctl -u derper.service -n 40 --no-pager || true
  echo "----------------------------"
  fail "服务已安装，但还不能通过 https://${DERP_HOSTNAME}/ 访问。请先看上面的日志：常见原因是安全组没放行 80/443，或证书申请失败。"
}

print_derpmap() {
  local ipv4="$1" ipv6="${2:-none}"
  [[ -n "$ipv6" ]] || ipv6="none"
  cat <<EOF

======== 部署完成 ========

请把下面这段合并到 Tailscale 策略文件（Access controls）的最外层，
保留原有内容，只增加或合并 derpMap。不要删掉其他规则。
若已经有 derpMap，把这个 Region 合并进已有的 Regions，不要覆盖其他 RegionID。

打开：https://login.tailscale.com/admin/acls

"derpMap": {
  "Regions": {
    "${DERP_REGION_ID}": {
      "RegionID": ${DERP_REGION_ID},
      "RegionCode": "${DERP_REGION_CODE}",
      "RegionName": "${DERP_REGION_NAME}",
      "Nodes": [
        {
          "Name": "1",
          "RegionID": ${DERP_REGION_ID},
          "HostName": "${DERP_HOSTNAME}",
          "IPv4": "${ipv4}",
          "IPv6": "${ipv6}",
          "STUNPort": 3478,
          "DERPPort": 443
        }
      ]
    }
  }
}

注意：必须写上 IPv4；没有公网 IPv6 时请保持 "IPv6": "none"。
这样客户端（尤其是本机代理开了 fake-ip 的电脑）不会把域名解析错。
每个 RegionID 只能有一台 DERP。再开一台 VPS 时，请换 901、902……

保存策略后，在任意已登录的设备上检查：

  tailscale netcheck

应能看到 ${DERP_REGION_NAME}（${DERP_REGION_CODE}），并有合理延迟。

常用命令：
  sudo systemctl status derper
  sudo journalctl -u derper -f
  tailscale status

官方说明：https://tailscale.com/docs/reference/derp-servers/custom-derp-servers
EOF
}

install_pkgs
PUB4="$(public_ipv4)"
PUB6="$(public_ipv6 || true)"
log "本机公网 IPv4：${PUB4}"
[[ -n "$PUB6" ]] && log "本机公网 IPv6：${PUB6}"
wait_dns "$PUB4" "$DERP_HOSTNAME"
maybe_ufw
install_tailscale
join_tailnet
install_go
install_derper
write_unit
wait_healthy
print_derpmap "$PUB4" "$PUB6"
