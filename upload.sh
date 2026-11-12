#!/usr/bin/env bash
# 在你自己的电脑上运行，把脚本和配置表传到 VPS。
# 用法：./upload.sh root@1.2.3.4
#       ./upload.sh ecs-user@1.2.3.4
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "用法：./upload.sh 用户名@VPS公网IP"
  echo "示例：./upload.sh root@47.100.1.2"
  exit 1
fi

if [[ ! -f "$HERE/install.sh" ]]; then
  echo "找不到 install.sh，请先进入 derp-bootstrap 目录再运行。"
  exit 1
fi

if [[ ! -f "$HERE/derp.env" ]]; then
  echo "找不到 derp.env。请先执行："
  echo "  cp derp.env.example derp.env"
  echo "  chmod 600 derp.env"
  echo "然后用编辑器填好域名和 TS_AUTHKEY。"
  exit 1
fi

# 粗略检查是否还是示例值
if grep -Eq 'tskey-auth-xxxxxxxx|derp-sg\.example\.com' "$HERE/derp.env"; then
  echo "derp.env 里好像还是示例内容，请先填上你的真实域名和 Tailscale auth key。"
  exit 1
fi
if ! grep -Eq '^TS_AUTHKEY=tskey-auth-' "$HERE/derp.env"; then
  echo "derp.env 里的 TS_AUTHKEY 看起来不对，应以 tskey-auth- 开头。"
  exit 1
fi

chmod 600 "$HERE/derp.env"
echo "正在上传到 ${TARGET}:~/derp-bootstrap/ ..."
ssh "$TARGET" "mkdir -p ~/derp-bootstrap && chmod 700 ~/derp-bootstrap"
scp "$HERE/install.sh" "$HERE/derp.env" "${TARGET}:~/derp-bootstrap/"
ssh "$TARGET" "chmod 755 ~/derp-bootstrap/install.sh && chmod 600 ~/derp-bootstrap/derp.env"
echo
echo "上传完成。接下来在 VPS 上执行："
echo "  ssh $TARGET"
echo "  cd ~/derp-bootstrap"
echo "  sudo bash install.sh"
