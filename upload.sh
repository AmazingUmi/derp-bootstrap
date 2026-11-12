#!/usr/bin/env bash
# ==============================================================================
# derp-bootstrap 本地上传工具
# 在本地电脑运行，将 install.sh 与配置文件 derp.env 安全上传至远程 VPS。
#
# 用法：
#   ./upload.sh root@1.2.3.4
#   ./upload.sh --run root@1.2.3.4
#   ./upload.sh -p 2222 -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SSH_PORT=""
SSH_KEY=""
RUN_INSTALL=0
TARGET=""

usage() {
  cat <<'EOF'
用法：./upload.sh [选项] <用户名@服务器IP或主机名>

选项：
  -p, --port <端口>       指定 SSH 端口（默认 22）
  -i, --identity <路径>   指定 SSH 私钥文件路径
  --run                   上传完成后立即在远程服务器上执行安装脚本
  -h, --help              显示本帮助信息

示例：
  ./upload.sh root@47.100.1.2
  ./upload.sh --run root@47.100.1.2
  ./upload.sh -p 2222 ecs-user@47.100.1.2
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      [[ $# -ge 2 ]] || { echo "错误：$1 需要指定端口号" >&2; exit 1; }
      SSH_PORT="$2"
      shift 2
      ;;
    -i|--identity)
      [[ $# -ge 2 ]] || { echo "错误：$1 需要指定私钥路径" >&2; exit 1; }
      SSH_KEY="$2"
      shift 2
      ;;
    --run)
      RUN_INSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "未知选项：$1（使用 --help 查看帮助）" >&2
      exit 1
      ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "错误：多余的参数 $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$HERE/install.sh" ]]; then
  echo "错误：未找到 $HERE/install.sh，请在项目根目录下运行此脚本。" >&2
  exit 1
fi

if [[ ! -f "$HERE/derp.env" ]]; then
  echo "错误：未找到配置文件 derp.env。请先执行：" >&2
  echo "  cp derp.env.example derp.env && chmod 600 derp.env" >&2
  echo "然后编辑 derp.env 填入你的域名和 Tailscale Auth Key。" >&2
  exit 1
fi

# 检查是否仍为未修改的模板示例值
if grep -Eq '^[[:space:]]*DERP_HOSTNAME=["'\'']?derp-sg\.example\.com["'\'']?[[:space:]]*$' "$HERE/derp.env"; then
  echo "错误：derp.env 中的 DERP_HOSTNAME 仍是示例域名（derp-sg.example.com），请先修改为你的真实域名。" >&2
  exit 1
fi

if grep -Eq '^[[:space:]]*TS_AUTHKEY=["'\'']?tskey-auth-xxxxxxxx["'\'']?[[:space:]]*$' "$HERE/derp.env"; then
  echo "错误：derp.env 中的 TS_AUTHKEY 仍是示例值（tskey-auth-xxxxxxxx），请填入真实的 Tailscale Auth Key。" >&2
  exit 1
fi

# 提取 TS_AUTHKEY 值（允许为空，用于已加入 Tailscale 的节点更新配置）
authkey_val="$(grep -E '^[[:space:]]*TS_AUTHKEY=' "$HERE/derp.env" | tail -n1 | cut -d= -f2- | tr -d '[:space:]"'\''' || true)"
if [[ -n "$authkey_val" && "$authkey_val" != tskey-auth-* ]]; then
  echo "错误：derp.env 中的 TS_AUTHKEY 格式不正确，应以 tskey-auth- 开头（或留空以复用远端已登录状态）。" >&2
  exit 1
fi
if [[ -z "$authkey_val" ]]; then
  echo "提示：derp.env 中的 TS_AUTHKEY 为空，仅适用于目标服务器已登录 Tailscale 的场景。"
fi

SSH_OPTS=()
SCP_OPTS=()
if [[ -n "$SSH_PORT" ]]; then
  SSH_OPTS+=(-p "$SSH_PORT")
  SCP_OPTS+=(-P "$SSH_PORT")
fi
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
  SCP_OPTS+=(-i "$SSH_KEY")
fi

chmod 600 "$HERE/derp.env"
echo "[derp-bootstrap] 正在上传文件到 ${TARGET}:~/derp-bootstrap/ ..."
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/derp-bootstrap && chmod 700 ~/derp-bootstrap"
scp "${SCP_OPTS[@]}" "$HERE/install.sh" "$HERE/derp.env" "${TARGET}:~/derp-bootstrap/"
ssh "${SSH_OPTS[@]}" "$TARGET" "chmod 755 ~/derp-bootstrap/install.sh && chmod 600 ~/derp-bootstrap/derp.env"

if [[ "$RUN_INSTALL" -eq 1 ]]; then
  echo "[derp-bootstrap] 上传完成，正在远程执行安装脚本..."
  ssh -t "${SSH_OPTS[@]}" "$TARGET" "cd ~/derp-bootstrap && sudo bash install.sh"
else
  echo
  echo "[derp-bootstrap] 上传完成！接下来请登录服务器执行安装："
  if [[ -n "$SSH_PORT" ]]; then
    echo "  ssh -p ${SSH_PORT} ${TARGET}"
  else
    echo "  ssh ${TARGET}"
  fi
  echo "  cd ~/derp-bootstrap && sudo bash install.sh"
  echo
  echo "（或者在本地直接运行：./upload.sh --run ${TARGET}）"
fi
