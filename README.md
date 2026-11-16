# derp-bootstrap

一键在 Linux 服务器上部署与维护私人 [Tailscale DERP](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers) 中转节点，或将普通设备 / 计算节点快速接入 Tailscale 网络并开启 SSH 的自动化脚本。

脚本支持两种部署模式（通过命令行参数切换）：

| 模式 | 命令 | 配置文件 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **DERP 中转模式（默认）** | `sudo bash install.sh` | `derp.env` | 部署私人 DERP + STUN 中转节点（需要域名、公网 IP、Go 与 `derper`） |
| **普通节点模式（`--client`）** | `sudo bash install.sh --client` | `client.env` | 仅将机器（如算力节点、内网服务器、开发机）加入 Tailscale 并开启 SSH（**不装 Go / `derper`，无需域名与公网端口**） |

> 如果你**只想把一台普通机器或计算节点接入 Tailscale 并用 SSH 连上去**，可以直接跳到 [普通设备 / 客户端部署（`--client` 模式，不做 DERP）](#普通设备--客户端部署--client-模式不做-derp)。

当两台 Tailscale 设备因复杂 NAT 无法打洞直连（P2P）时，流量会通过 DERP 服务器进行端到端加密中转。官方公共中转节点在跨网或高峰期往往延迟较高，自建私人 DERP 可以显著降低中转延迟并提升连接稳定性。

---

## 核心特性

- **防白嫖鉴权（`--verify-clients`）**：自动安装并关联本机 `tailscaled`，仅允许你自己 Tailnet 内的设备使用中转服务。
- **版本严格对齐**：自动检测本机安装的 Tailscale 版本并从源码编译同版本 `derper`，避免协议版本不匹配。
- **全自动 HTTPS 证书**：集成 Let's Encrypt 自动签发与续期 TLS 证书，并通过 systemd 守护进程开机自启。
- **国内外网络自适应**：自动检测网络环境，智能切换官方源与国内镜像（阿里云 Go 镜像、`goproxy.cn`），原生支持 `amd64` 与 `arm64` 架构。
- **防代理 Fake-IP 劫持**：自动探测服务器公网 IPv4 / IPv6 并生成含显式 IP 的 `derpMap` JSON，避免客户端开启代理（Clash / Surge 等 Fake-IP 模式）时解析错误导致断连。
- **凭证阅后即焚**：首次入网成功后自动擦除服务器配置文件中的 `TS_AUTHKEY`，降低密钥泄露风险。
- **全生命周期管理**：内置 `--status`（状态与配置查看）、`--update`（一键升级对齐）、`--uninstall`（干净卸载）子命令。

---

## 目录

- [环境与前置要求](#环境与前置要求)
- [第一部分：准备工作](#第一部分准备工作)
  - [1. 准备固定公网 IP 与放行端口](#1-准备固定公网-ip-与放行端口)
  - [2. 配置域名 DNS 解析](#2-配置域名-dns-解析)
  - [3. 准备 Tailscale 标签与 Auth Key](#3-准备-tailscale-标签与-auth-key)
- [第二部分：开始部署](#第二部分开始部署)
  - [方式 A：本地填好配置，一键上传部署（推荐多节点管理）](#方式-a本地填好配置一键上传部署推荐多节点管理)
  - [方式 B：直接在 VPS 上克隆部署](#方式-b直接在-vps-上克隆部署)
- [第三部分：接入 Tailscale 网络与验证](#第三部分接入-tailscale-网络与验证)
  - [1. 将 derpMap 写入 Tailscale ACL](#1-将-derpmap-写入-tailscale-acl)
  - [2. 验证节点连通性](#2-验证节点连通性)
- [配置项参考（derp.env）](#配置项参考derpenv)
- [日常维护（升级、状态、扩容、卸载）](#日常维护升级状态扩容卸载)
- [普通设备 / 客户端部署（--client 模式，不做 DERP）](#普通设备--客户端部署--client-模式不做-derp)
- [常见问题排查（FAQ）](#常见问题排查faq)

---

## 环境与前置要求

1. **操作系统**：支持主流 Linux 发行版（推荐 **Ubuntu 22.04 / 24.04**、**Debian 11 / 12**，也支持 **Alibaba Cloud Linux 3**、**CentOS Stream / Rocky / AlmaLinux 8+**）。
2. **公网 IP**：VPS 需具备独立的**固定公网 IPv4**（如云厂商的弹性公网 IP）。
3. **域名**：一个可添加 `A` 记录的子域名（如 `derp-sg.example.com`）。
   - **切勿开启 CDN 或反向代理**（如 Cloudflare 橙色云朵、阿里云全站加速、负载均衡 SLB），DERP 必须直连服务器真实 IP。
   - **关于备案**：若 VPS 位于**中国内地**地域，使用 `80` / `443` 端口对外提供 HTTPS 服务通常需完成 ICP 备案；中国香港、新加坡、东京、美西等境外地域无需备案。
4. **开放端口**：需在云厂商「安全组 / 防火墙」中放行以下入站规则（授权对象 `0.0.0.0/0`）：

| 协议 | 端口 | 用途 | 备注 |
| :--- | :--- | :--- | :--- |
| **TCP** | `80` | Let's Encrypt 证书申请与续期 | HTTP-01 验证使用，不可关闭 |
| **TCP** | `443` | DERP HTTPS 中转服务 | 可在 `derp.env` 中自定义 `DERP_PORT` |
| **UDP** | `3478` | STUN 打洞辅助服务 | **注意协议是 UDP**，不要误建为 TCP |
| **ICMP** | 全部 | 延迟探测与连通性检查 | 入站与出站均需放行 |

---

## 第一部分：准备工作

以下步骤在云服务商网页控制台与 Tailscale 后台完成。

### 1. 准备固定公网 IP 与放行端口

1. 在你的云服务商控制台（阿里云、腾讯云、AWS、Vultr 等）记下 VPS 的**公网 IPv4 地址**。
   > **提示（以阿里云 ECS 为例）**：如果实例显示为「固定公网 IP」，建议在控制台将其「转换为弹性公网 IP（EIP）」，避免将来实例规格变更时 IP 变化。
2. 进入实例所属的**安全组 / 防火墙**，按上方表格添加入方向规则（放行 `TCP 80`、`TCP 443`、`UDP 3478` 及 `ICMP`）。
   - 请保留原有的 `SSH (TCP 22)` 规则，以免无法远程连接。

### 2. 配置域名 DNS 解析

前往你的域名 DNS 服务商（如 Cloudflare、阿里云云解析 DNS、DNSPod 等），添加一条 `A` 记录：

| 参数 | 填写内容 |
| :--- | :--- |
| **记录类型** | `A` |
| **主机记录（名称）** | 子域名前缀，例如 `derp-sg`（对应完整域名 `derp-sg.example.com`） |
| **记录值（内容）** | 第 1 步记下的 VPS 公网 IPv4 |
| **代理状态 / CDN** | **仅 DNS（关闭代理 / 灰色云朵）** |
| **TTL** | `600`（10 分钟）或自动 |

配置完成后，可在终端验证解析是否已生效：

```bash
dig +short derp-sg.example.com
```

### 3. 准备 Tailscale 标签与 Auth Key

为了让 VPS 免交互自动加入你的 Tailscale 网络，并具备持久化标签身份，建议按以下两步生成 `TS_AUTHKEY`：

#### 3.1 在 ACL 中声明标签（`tagOwners`）

打开 [Tailscale Access Controls](https://login.tailscale.com/admin/acls)，在策略 JSON 的**最外层**添加 `tagOwners`（若已有 `tagOwners` 字段，只需在其中新增 `"tag:derp"` 一行，**切勿清空原有规则**）：

```json
"tagOwners": {
  "tag:derp": ["autogroup:admin"]
}
```

保存策略文件。

> **注意**：如果你的 ACL 修改过默认的全局放通规则，请确保挂载了 `tag:derp` 的节点与网络内其他设备在 ACL 中互相可见，否则 `--verify-clients` 会拒绝未授权设备的连接。

#### 3.2 生成 Auth Key

打开 [Tailscale Keys 页面](https://login.tailscale.com/admin/settings/keys) → 点击 **Generate auth key**，按以下推荐配置勾选：

| 选项 | 推荐设置 | 说明 |
| :--- | :--- | :--- |
| **Reusable（可复用）** | 勾选 | 方便后续重装或部署多台 DERP 节点复用 |
| **Ephemeral（临时节点）** | **不勾选** | 避免服务器短暂重启或离线后被自动移除 |
| **Pre-approved（预批准）** | 勾选（若启用了设备审批） | 新节点无需人工点击批准即可上线 |
| **Tags（标签）** | 勾选并选择 `tag:derp` | 绑定刚才声明的标签（自动禁用客户端密钥过期） |

点击生成后，**立即复制**形如 `tskey-auth-...` 的密钥字符串妥善保存。

---

## 第二部分：开始部署

你可以任选以下两种方式之一完成部署。

### 方式 A：本地填好配置，一键上传部署（推荐多节点管理）

适合在个人电脑（macOS / Linux / WSL）上集中管理配置文件，并通过 SSH 推送到远程服务器。

1. **克隆项目并创建配置文件**：

   ```bash
   git clone https://github.com/AmazingUmi/derp-bootstrap.git
   cd derp-bootstrap
   cp derp.env.example derp.env
   chmod 600 derp.env
   ```

2. **编辑 `derp.env`**：填入你的域名与密钥（完整参数见下方[配置项参考](#配置项参考derpenv)）：

   ```ini
   DERP_HOSTNAME=derp-sg.example.com
   TS_AUTHKEY=tskey-auth-你的真实密钥
   TS_HOSTNAME=derp-sg
   TS_ADVERTISE_TAGS=tag:derp
   DERP_REGION_ID=900
   DERP_REGION_CODE=sg
   DERP_REGION_NAME=Singapore
   ```

3. **上传并执行安装**：

   ```bash
   # 上传并直接在远程服务器上启动安装（请将 root@47.100.1.2 替换为你的服务器用户名和 IP）
   ./upload.sh --run root@47.100.1.2
   ```

   > **提示**：
   > - 如果你的 SSH 使用了非默认端口或指定私钥，可传入 `-p <端口>` 和 `-i <私钥路径>`，例如：`./upload.sh -p 2222 -i ~/.ssh/id_ed25519 --run root@47.100.1.2`。
   > - 如果只想先上传文件、再手动登录服务器执行，去掉 `--run` 即可。

### 方式 B：直接在 VPS 上克隆部署

适合已经通过 SSH 登录到目标 VPS 的用户。

```bash
git clone https://github.com/AmazingUmi/derp-bootstrap.git
cd derp-bootstrap
cp derp.env.example derp.env
chmod 600 derp.env

# 使用 nano 或 vim 编辑配置，填入 DERP_HOSTNAME 和 TS_AUTHKEY
nano derp.env

# 运行一键安装脚本
sudo bash install.sh
```

---

## 第三部分：接入 Tailscale 网络与验证

### 1. 将 `derpMap` 写入 Tailscale ACL

当 `install.sh` 运行成功时，终端末尾会自动输出一段包含本机公网 IPv4 / IPv6 的 `derpMap` JSON 配置：

```json
"derpMap": {
  "Regions": {
    "900": {
      "RegionID": 900,
      "RegionCode": "sg",
      "RegionName": "Singapore",
      "Nodes": [
        {
          "Name": "900a",
          "RegionID": 900,
          "HostName": "derp-sg.example.com",
          "IPv4": "47.100.1.2",
          "IPv6": "none",
          "STUNPort": 3478,
          "DERPPort": 443
        }
      ]
    }
  }
}
```

打开 [Tailscale Access Controls](https://login.tailscale.com/admin/acls)，将这段 `"derpMap"` 合并到策略 JSON 的**最外层**并保存。

- **切勿删掉原有的 ACL 规则**。
- 如果你之前已经配置过 `"derpMap"`，只需将新的区域（如 `"901": { ... }`）合并进现有的 `"Regions"` 对象中，**不要覆盖**已有的 `"900"`。

### 2. 验证节点连通性

等待约 1 分钟策略下发后，在任意已登录 Tailscale 的设备上运行：

```bash
tailscale netcheck
```

若输出列表里出现了你配置的区域名（如 `Singapore`）并显示正常延迟（如 `35ms`），同时访问 `https://你的域名/` 能看到 DERP 默认页面且证书有效，即表示私人 DERP 中转已正式生效！

---

## 配置项参考（`derp.env`）

| 变量名 | 是否必填 | 默认值 | 说明 |
| :--- | :---: | :---: | :--- |
| `DERP_HOSTNAME` | **是** | — | 已解析到本机公网 IP 的完整域名（不含 `https://`） |
| `TS_AUTHKEY` | 首次必填 | — | Tailscale 授权密钥（`tskey-auth-...`）；若机器已登录 Tailscale 可留空 |
| `TS_HOSTNAME` | 否 | 域名前缀 | 在 Tailscale 设备列表中显示的机器名（如 `derp-sg`） |
| `TS_ADVERTISE_TAGS` | 否 | `tag:derp` | 节点宣告的 ACL 标签；若生成的密钥未绑定标签，请设为空 |
| `DERP_REGION_ID` | 否 | `900` | 自定义区域 ID（必须在 `900–999` 之间，每台 DERP 需唯一） |
| `DERP_REGION_CODE` | 否 | `myderp` | 区域简写代号（如 `sg`、`hk`、`tyo`） |
| `DERP_REGION_NAME` | 否 | `My DERP` | 区域全称（如 `Singapore`、`Hong Kong`） |
| `ACME_EMAIL` | 否 | 空 | Let's Encrypt 证书通知邮箱 |
| `DERP_PORT` | 否 | `443` | DERP HTTPS 监听端口 |
| `DERP_HTTP_PORT` | 否 | `80` | Let's Encrypt HTTP-01 验证端口 |
| `DERP_STUN_PORT` | 否 | `3478` | STUN UDP 监听端口 |
| `DERP_VERIFY_CLIENTS` | 否 | `true` | 是否开启客户端身份校验（防止他人白嫖） |
| `PUBLIC_IPV4` | 否 | 自动探测 | 手动指定本机公网 IPv4（仅在自动探测不准确时填写） |

---

## 日常维护（升级、状态、扩容、卸载）

在 VPS 的 `derp-bootstrap` 目录下，可使用以下命令进行日常运维：

- **查看运行状态与重新打印 `derpMap`**：
  ```bash
  sudo bash install.sh --status
  ```
- **升级 Tailscale 并重新编译对齐版本的 `derper`**：
  ```bash
  sudo bash install.sh --update
  ```
  > 无需重新填写已擦除的 `TS_AUTHKEY`，脚本会自动复用当前已登录的 Tailscale 状态。
- **查看 `derper` 实时日志**：
  ```bash
  sudo journalctl -u derper -f
  ```
- **部署第 2、第 3 台 DERP 节点（多地域扩容）**：
  修改 `derp.env` 中的 `DERP_HOSTNAME`、`TS_HOSTNAME`，并将 `DERP_REGION_ID` 改为 `901`（下一台 `902`），然后在新服务器上执行部署，最后将新区域合并进 Tailscale ACL 的 `derpMap.Regions` 中。
- **卸载 `derper` 服务**：
  ```bash
  sudo bash install.sh --uninstall
  ```

---

## 普通设备 / 客户端部署（`--client` 模式，不做 DERP）

如果只需要让一台普通设备（如算力节点、GPU 机器、内网服务器、开发机等）快速加入 Tailscale 网络并支持 SSH 登录，**不作为 DERP 中转节点**，请使用 `--client` 模式与 [`client.env.example`](client.env.example)。

该模式会**跳过**域名检查、公网端口检查、Go 环境安装、`derper` 编译和证书签发，仅完成：安装基础依赖（`curl`、`ca-certificates`）→ 安装并启动 `tailscaled` → 使用 `TS_AUTHKEY` 加入 Tailscale 网络 → 开启 Tailscale SSH 与 MagicDNS → 擦除配置中的 `TS_AUTHKEY`。

### 1. 环境要求（`--client` 模式）

- 支持主流 Linux 发行版（Ubuntu / Debian / Alibaba Cloud Linux / CentOS / Rocky / AlmaLinux）。
- **无需**域名、**无需**固定公网 IP、**无需**放行 `80/443/3478` 端口，设备能正常访问外网即可。

### 2. 准备配置并部署

1. **生成并编辑配置文件**：
   ```bash
   cp client.env.example client.env && chmod 600 client.env
   # 编辑 client.env，至少填入 TS_AUTHKEY
   ```
   > **关于 `TS_HOSTNAME`**：留空时会自动读取本机主机名；若主机名包含下划线 `_`（如 `compute_test`），脚本会自动将其规范化为连字符 `-`（`compute-test`）。如果手动填写，请确保只使用字母、数字和 `-`。

2. **执行部署**（二选一）：
   - **本地一键上传并部署**：
     ```bash
     ./upload.sh --client --run root@<设备IP>
     ```
   - **直接在目标设备上执行**：
     ```bash
     sudo bash install.sh --client
     ```

3. **SSH 连接该节点**：
   入网成功后，终端会输出分配的 Tailscale IP 与节点名。在同一 Tailnet 内的其他设备上可直接通过 Tailscale SSH 登录：
   ```bash
   ssh <用户名>@<节点名>
   # 或使用 Tailscale IP
   ssh <用户名>@<Tailscale-IP>
   ```

### 3. `client.env` 配置项参考

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `TS_AUTHKEY` | *必填* | Tailscale 授权密钥（`tskey-auth-` 开头）；首次入网成功后自动擦除 |
| `TS_HOSTNAME` | 空 | 在 Tailscale 中显示的机器名；留空则自动使用本机主机名（自动规范化非法字符） |
| `TS_ADVERTISE_TAGS` | 空 | 节点宣告的 ACL 标签（如 `tag:compute`），需提前在 Tailscale ACL 的 `tagOwners` 中声明 |
| `TS_SSH` | `true` | 是否开启 Tailscale SSH（允许通过 Tailscale 直接 SSH 登录本机） |
| `TS_ACCEPT_DNS` | `true` | 是否接受 Tailscale MagicDNS（可用设备名直接互访） |
| `TS_ACCEPT_ROUTES` | `false` | 是否接受其他节点宣告的子网路由 |

### 4. `--client` 模式日常维护

```bash
sudo bash install.sh --client --status     # 查看 Tailscale 连接状态与 IP
sudo bash install.sh --client --update     # 升级 Tailscale 并同步 client.env 配置
sudo bash install.sh --client --uninstall  # 退出 Tailscale 网络并停用 tailscaled
```

---

## 常见问题排查（FAQ）

| 现象 / 报错 | 排查方法与解决方案 |
| :--- | :--- |
| **提示域名解析与本机公网 IP 不一致** | 1. 检查 DNS 服务商处的 `A` 记录是否填写正确；<br>2. 确保未开启 Cloudflare 橙色云朵或任何 CDN；<br>3. 在本地运行 `dig +short 你的域名` 确认 DNS 已刷新。 |
| **证书签发失败 / HTTPS 无法访问** | 1. 检查云厂商**安全组**及系统防火墙是否已放行 **TCP 80** 与 **TCP 443**；<br>2. 若为中国内地云主机，检查域名是否已完成 ICP 备案；<br>3. 运行 `sudo journalctl -u derper -n 50` 查看具体 ACME 报错。 |
| **提示端口 80 或 443 被占用** | 本机已运行了 Nginx / Apache / Caddy 等 Web 服务。请停止占用端口的服务，或在 `derp.env` 中修改 `DERP_PORT`（注意 Let's Encrypt HTTP-01 验证仍需占用 80 端口）。 |
| **`tailscale up` 失败并提及 tag 权限** | 1. 检查 Tailscale ACL 中是否已保存 `"tagOwners": {"tag:derp": ["autogroup:admin"]}`；<br>2. Auth Key 必须在保存 ACL **之后**生成，并勾选 `tag:derp`；<br>3. 若不想使用标签，可将 `derp.env` 中的 `TS_ADVERTISE_TAGS=` 留空。 |
| **`tailscale netcheck` 看不到自定义区域** | 检查 Tailscale ACL 中的 `derpMap` 是否已保存、JSON 格式是否正确、`RegionID` 是否在 `900–999` 范围内。 |
| **能看到自定义区域但无延迟（`*`）或连不上** | 1. 检查云安全组是否已放行 **UDP 3478**（注意是 UDP 而非 TCP）及 **ICMP**；<br>2. 确保 `derpMap` 的节点中包含脚本生成的 `"IPv4": "真实IP"` 和 `"IPv6": "none"`（防止本地代理软件的 Fake-IP 将域名解析为 `198.18.x.x`）。 |
| **提示等待 dpkg / apt 软件包锁** | 新开 Ubuntu 实例首次启动时常在后台运行 `unattended-upgrades` 自动更新。脚本会自动等待最多 5 分钟，若超时再重跑一次即可，请勿强行删除锁文件。 |
| **`--verify-clients` 拒绝客户端连接** | 检查 Tailscale ACL 规则是否过于严格，确保 DERP 节点（`tag:derp`）在网络中能「看到」需要连接它的客户端设备。 |

---

## 项目文件结构

| 文件 | 运行位置 | 说明 |
| :--- | :--- | :--- |
| [`derp.env.example`](derp.env.example) | 本地或 VPS | DERP 中转节点配置文件模板，复制为 `derp.env` 后填写 |
| [`client.env.example`](client.env.example) | 本地或目标设备 | 普通设备（`--client` 模式）配置文件模板，复制为 `client.env` 后填写 |
| [`install.sh`](install.sh) | 目标机器（`sudo`） | 核心自动化安装、升级、状态检查与卸载脚本（支持 `--client`） |
| [`upload.sh`](upload.sh) | 本地电脑 | 校验本地配置并通过 SSH/SCP 上传至目标机器（支持 `--client`、`--run`） |
| [`.gitignore`](.gitignore) | Git 仓库 | 默认忽略 `derp.env` 与 `client.env`，防止私钥与授权凭证被意外提交 |
| [`LICENSE`](LICENSE) | Git 仓库 | MIT 开源许可协议 |

---

## 开源许可（License）

本项目基于 [MIT License](LICENSE) 开源。
