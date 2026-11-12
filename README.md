# derp-bootstrap

在一台新的 VPS 上，把私人 Tailscale DERP 中转站一次性装好。本指南默认你是新手，按「准备工作」和「一键部署」两步走。示例环境是**阿里云 ECS** + **阿里云云解析 DNS**，系统建议 Ubuntu 22.04 / 24.04，Alibaba Cloud Linux 也可以。

DERP 是 Tailscale 的中转：两台设备没法打洞直连时，流量会经它转发（内容仍然是加密的）。你已经有一套在用的话，这个项目就是为了下次开新机器时少踩坑。

---

## 你会得到什么

准备阶段在网页里完成（密钥、固定 IP、域名、填配置表）。部署阶段从你自己的电脑 SSH 上去，上传两个文件，跑一条命令。脚本会：

- 检查域名已经解析到这台机器
- 安装 Tailscale 并用密钥加入你的网络（开启 `--verify-clients`，只允许你自己的设备使用）
- 安装与本机 Tailscale 版本对齐的 `derper`，申请 Let's Encrypt 证书，并用 systemd 保持运行
- 打印一段要粘贴到 Tailscale 策略里的 `derpMap` JSON

需要开放的端口（[官方要求](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)）：

| 协议 | 端口 | 用途 |
| --- | --- | --- |
| TCP | 80 | Let's Encrypt 申请证书（不能改端口） |
| TCP | 443 | DERP 中转 |
| UDP | 3478 | STUN |
| ICMP | — | 连通性探测，入站和出站都要放行 |

不要把 DERP 放在 CDN、SLB 或会改写源地址的负载均衡后面，也不要开橙色云朵之类的代理。

---

# 第一部分：准备工作

下面这些都在你自己的电脑和网页控制台完成，**还不用 SSH 到 VPS 装软件**。全部准备好后，再做第二部分。

## 1. 固定 VPS 的公网 IP

DERP 和域名都要指向一个不会随便变的公网 IP。推荐使用阿里云**弹性公网 IP（EIP）**。

1. 打开 [ECS 控制台](https://ecs.console.aliyun.com)，进入这台实例，记下「公网 IP」。
2. 判断它是不是 EIP：
   - 已经是弹性公网 IP：直接把这个地址记到记事本，进入下一步。
   - 显示为「固定公网 IP」：在实例的公网 IP 处选择**转换为弹性公网 IP**。转换后地址通常不变，但请当场确认。已有固定公网 IP 的实例，不能再另外绑一个 EIP，需要先转换。[官方说明](https://help.aliyun.com/zh/eip/product-overview/getting-started)
   - 还没有公网 IP：打开 [弹性公网 IP 控制台](https://vpc.console.aliyun.com/eip)，**地域必须和 ECS 相同**，创建后在操作列选择「绑定资源」→ 云服务器 ECS，选中这台实例。

以后不要轻易释放这台 EIP，否则域名和 DERP 都要跟着改。

带宽方面，DERP 不吃 CPU，主要吃流量和带宽。按你预计的中转用量选即可，例如 3–5 Mbps 起步，不够再升。

## 2. 在安全组放行端口

1. 仍在 ECS 控制台，点进这台实例 → **安全组** → **配置规则** → **入方向** → **增加规则**。
2. 增加下面四条（授权对象填 `0.0.0.0/0`，因为你的设备可能从家里、校园网或手机网络连进来）：

| 协议类型 | 端口范围 | 授权对象 | 用途 |
| --- | --- | --- | --- |
| TCP | 80 | 0.0.0.0/0 | 申请证书 |
| TCP | 443 | 0.0.0.0/0 | DERP |
| UDP | 3478 | 0.0.0.0/0 | STUN（不要误建成 TCP） |
| 全部 ICMP | — | 0.0.0.0/0 | 官方要求放行 ICMP |

3. 不要删掉已有的 SSH（TCP 22）规则，否则你会连不上去。22 端口最好只允许你自己的 IP，不要为了省事改成对全世界开放（如果现在已经是 `0.0.0.0/0`，有空再收紧）。
4. 如果你另外开了阿里云「云防火墙」，那里也要放行同样的端口。

出方向一般默认全放，不用改。

## 3. 把域名解析到这个 IP

使用已在阿里云管理的域名，给这台 DERP 一个**专用子域名**，例如 `derp-sg.yourdomain.com`。

1. 打开 [云解析 DNS 控制台](https://dns.console.aliyun.com) → **公网权威解析** → 找到你的域名 → **解析设置** → **添加记录**。
2. 按下面填写（[官方添加 A 记录说明](https://help.aliyun.com/zh/dns/pubz-add-website-parsing)）：

| 参数 | 填什么 |
| --- | --- |
| 记录类型 | A |
| 主机记录 | 例如 `derp-sg`（不要填完整域名） |
| 记录值 | 第 1 步记下的公网 IPv4 |
| 解析请求来源 | 默认 |
| TTL | 10 分钟即可，刚开始也可以更短，方便改错 |

3. **不要**给这条记录开通 CDN 加速，也**不要**用 CNAME 指到 CDN 或负载均衡。
4. 在你自己的电脑上验证（把域名换成你的）：

```bash
dig +short derp-sg.yourdomain.com
```

返回的 IP 必须和第 1 步完全一致。如果是空的或还是旧地址，再等几分钟。

如果这台 ECS 在**中国内地**，用 80/443 对外提供 HTTPS 通常需要完成 ICP 备案。机器在新加坡、东京等海外地域则一般不需要。

## 4. 准备 Tailscale 标签和 auth key

密钥是让 VPS **免登录网页、自动加入**你的 Tailscale 网络用的。带标签的密钥，必须先在 ACL 里声明谁能拥有这个标签，再建密钥。

### 4.1 先改访问控制（ACL）

打开 [Access controls](https://login.tailscale.com/admin/acls)。在策略 JSON **最外层**加上（如果已经有 `tagOwners`，就在里面加一行，不要把原内容删掉）：

```json
"tagOwners": {
  "tag:derp": ["autogroup:admin"]
}
```

如果你的 ACL 还是默认的「所有设备互相放通」（`src` 为 `*`、`dst` 为 `*:*`），到这里就可以保存了。

如果平时 ACL 比较严，还要保证：挂了 `--verify-clients` 的这台 DERP 机器，在 Tailscale 里能「看到」其他设备，否则别人连你的中转会被拒绝。不确定的话，可以先维持较宽松的规则，或参考 [自定义 DERP 说明](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)。

### 4.2 再生成密钥

打开 [Keys](https://login.tailscale.com/admin/settings/keys) → **Generate auth key**，按下面选：

| 选项 | 怎么选 | 原因 |
| --- | --- | --- |
| Reusable（可重复使用） | 勾选 | 以后多台 VPS 可以共用同一把（务必保管好） |
| Ephemeral（临时设备） | **不要勾** | 勾了以后机器离线或重启可能被从网络里清掉 |
| Pre-approved | 若你开了「设备审批」，请勾选 | 否则新机器要手动批准才能上线 |
| Tags | 勾选，填 `tag:derp` | 和上面的 tagOwners 对应 |
| 过期时间 | 按你的习惯设，例如 90 天 | 过期后要再生成一把，并更新 derp.env |

生成后**立刻复制**，密钥只显示一次，格式类似 `tskey-auth-...`。把它先贴到一个仅你可见的地方（下一步会写入 `derp.env`）。不要发到聊天或截图给别人。

## 5. 填写配置表

在你自己的电脑上打开本项目目录：

```bash
cp derp.env.example derp.env
chmod 600 derp.env
```

用任意编辑器打开 `derp.env`，至少改这几项：

```bash
DERP_HOSTNAME=derp-sg.yourdomain.com
TS_AUTHKEY=tskey-auth-把你复制的密钥贴这里
TS_HOSTNAME=derp-sg
TS_ADVERTISE_TAGS=tag:derp
DERP_REGION_ID=900
DERP_REGION_CODE=sg
DERP_REGION_NAME=Singapore
```

说明：

- `DERP_HOSTNAME` 必须是第 3 步已经解析好的**完整域名**，不要带 `https://`。
- `DERP_REGION_ID` 必须在 **900–999**（这是 Tailscale 留给用户的号段）。**每台 DERP 用不同的 ID**：第一台 900，第二台 901，以此类推（官方规定一个 Region 只能有一台 DERP）。把新节点合并进已有的 `derpMap` 时，不要覆盖或删掉已经在用的 Region（例如原来的 900）。
- `DERP_REGION_CODE` / `DERP_REGION_NAME` 是给你自己看的短名和全名，例如 `sg` / `Singapore`。
- `ACME_EMAIL` 可留空。

到这里，准备工作结束。下面可以开始一键部署。

---

# 第二部分：一键部署

在你**自己的电脑**上操作上传，再 SSH 到服务器执行安装。下面假设 VPS 用户是 `root`，公网 IP 是 `47.100.1.2`，请换成你的。如果阿里云给的是 `ecs-user`，把命令里的 `root` 改成 `ecs-user`。

## 1. SSH 先确认能登录

```bash
ssh root@47.100.1.2
```

能进去并看到命令提示符即可，先输入 `exit` 退回自己的电脑——上传要在本地做。

如果你用密钥文件登录，平时怎么连，后面 `upload.sh` 也会沿用同样的 SSH 配置（例如 `~/.ssh/config`）。

## 2. 上传脚本和配置表

仍在**自己电脑**的 `derp-bootstrap` 目录里：

```bash
chmod +x upload.sh install.sh
./upload.sh root@47.100.1.2
```

它会把 `install.sh` 和 `derp.env` 传到服务器的 `~/derp-bootstrap/`，并设好权限。如果提示还是示例内容，说明 `derp.env` 没改完，先回到第一部分第 5 步。

等价的手动命令是：

```bash
ssh root@47.100.1.2 "mkdir -p ~/derp-bootstrap && chmod 700 ~/derp-bootstrap"
scp install.sh derp.env root@47.100.1.2:~/derp-bootstrap/
```

## 3. 一键安装

```bash
ssh root@47.100.1.2
cd ~/derp-bootstrap
sudo bash install.sh
```

脚本会先核对域名是否已经指向本机 IP（最多等大约 3 分钟；会同时查询 `223.5.5.5` 和 `8.8.8.8`）。若这里报错，回到阿里云检查 A 记录和安全组，修好后再运行同一条命令，可以重复执行。国内机器安装 Go、编译 derper 时，脚本会优先用阿里云镜像和 `goproxy.cn`，一般不必手动换源。若遇到 Ubuntu 自动更新占用软件包锁，脚本会等待最多约 5 分钟。

成功时，终端最后会打印一段 `derpMap` JSON，并提示证书已申请好。服务器上的 `derp.env` 里的 `TS_AUTHKEY` 会被清空，避免密钥留在 VPS 磁盘上；你电脑上的那份还在，请继续保管好。

## 4. 把节点写进 Tailscale 策略

打开 [Access controls](https://login.tailscale.com/admin/acls)。**不要清空原文件**，只在最外层 JSON 里增加（或合并）脚本打印的 `derpMap`。若你已经有 `derpMap`，把新的 Region（例如 `"901": { ... }`）放进已有的 `Regions` 里，**不要覆盖**已经在用的 `"900"`。脚本打印的节点会带上探测到的 `IPv4`，没有公网 IPv6 时是 `"IPv6": "none"`，请一并保留——这样本机代理开了 fake-ip 时也不会把域名解析错。

保存后，等一两分钟。再开一台机器时，换一个 RegionID（901、902……），再合并进去。

## 5. 验证

在任意一台已经登录 Tailscale 的设备上（你的 Mac 即可）：

```bash
tailscale netcheck
```

输出里应出现你在配置表里写的区域名（例如 Singapore），并且有一个合理的延迟。也可以看：

```bash
sudo systemctl status derper
sudo journalctl -u derper -f
```

浏览器打开 `https://你的域名/`，应能打开 derper 的默认页面（证书是有效的 Let's Encrypt）。

---

## 出了问题怎么查

| 现象 | 先检查什么 |
| --- | --- |
| 脚本提示域名解析不对 | 阿里云 A 记录的记录值、TTL 是否已生效；`dig +short 你的域名` |
| 证书申请失败、https 打不开 | 安全组是否放行了 **TCP 80 和 443**；域名是否指错；是否开了 CDN |
| `netcheck` 看不到自定义区域 | 策略里的 `derpMap` 是否已保存、JSON 逗号是否写对、RegionID 是否 900–999；第二台是否误覆盖了第一台的 Region |
| 能看到区域但没有延迟 / 连不上 | `derpMap` 节点是否写了真实 `IPv4`，没有 IPv6 时是否为 `"IPv6": "none"`（本机代理的 fake-ip 会把域名解析成 `198.18.x.x`）；安全组是否放行了 **UDP 3478** 和 ICMP；不要走 CDN 或 SLB |
| 本机 `curl` 域名失败，但服务器上是通的 | 本机代理 TUN / fake-ip 把域名解析错了，用 `--resolve 域名:443:真实IP` 验证，并在 `derpMap` 里写上 IPv4 |
| `tailscale up` 失败，提到 tag | ACL 里是否已有 `tagOwners`（`tag:derp` 或你实际用的标签，例如 `tag:relay`），密钥是否勾了同样的 tag，是否在保存 ACL **之后**新建的；过期的或改 ACL 之前创建的 key 要换新 |
| 提示无法获取 dpkg / apt 锁 | 系统 `unattended-upgrades` 正在更新，脚本会自动等；若超时，稍后再跑一次，不要手动删锁文件 |
| 安装 Go 或编译 derper 很慢 / 失败 | 国内访问 `go.dev` 和 `proxy.golang.org` 常会超时，脚本已改走国内镜像；若仍失败，检查 VPS 的 DNS（阿里云 VPC DNS 加 `223.5.5.5`）和出网 |
| 加入网络后 `--verify-clients` 拒绝连接 | DERP 这台设备在 ACL 里能否看到其他节点 |

更新 derper（以后升级 Tailscale 时建议一并做）：把本项目重新上传（不必重新填已清空的服务器端密钥，只要机器仍在网内），再执行一次 `sudo bash install.sh`。脚本发现已经加入 Tailscale 就会跳过 auth key，并按当前 `tailscale` 版本重新编译 derper。

---

## 文件说明

| 文件 | 在哪用 | 作用 |
| --- | --- | --- |
| `derp.env.example` | 自己电脑 | 配置表模板 |
| `derp.env` | 先在自己电脑填写，再上传 | 域名、密钥等；已加入 `.gitignore` |
| `upload.sh` | 自己电脑 | 把脚本和配置传到 VPS |
| `install.sh` | VPS 上 `sudo bash` | 一键安装并打印 derpMap |
