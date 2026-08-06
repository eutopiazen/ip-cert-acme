# IP Certificate ACME

一个面向 Debian/Ubuntu 的交互式 Bash 工具，使用
[acme.sh](https://github.com/acmesh-official/acme.sh) 为公网 IPv4 申请
Let’s Encrypt 短期 IP 证书，并配置自动续期。

> Let’s Encrypt 的 IP 证书有效期约 6 天。稳定的自动续期不是可选项：公网
> TCP 80、cron、固定证书路径和服务重载命令必须同时正常。

## 功能

- 自动识别或手动输入公网 IPv4
- 安装 `acme.sh`、`socat`、`cron`、OpenSSL 等依赖
- 使用独立临时目录完成 staging 测试，不污染正式证书配置
- 使用 Let’s Encrypt `shortlived` profile 正式签发 IP 证书
- 默认第 4 天进入续期判断，给约 6 天的证书保留容错时间
- 将证书部署到固定路径，而不是让服务读取 acme.sh 内部目录
- 内置多目标部署分发器，一次续期可同步到多个使用者
- 自动发现 1Panel 面板证书，不绑定 1Panel 版本号或固定安装目录
- 可选择 1Panel 网站、x-ui、Nginx、Caddy、Apache2 或自定义目标
- 复制前校验证书与私钥，保留目标备份并使用同目录临时文件原子替换
- 单个复制目标重载失败时自动恢复旧证书并再次尝试恢复服务
- 查看 cron、ARI/下次续期时间、SAN、有效期和固定文件路径
- 支持正常续期检查、显式确认后的强制续期及 acme.sh 更新

## 支持范围

- Debian 12
- Ubuntu 22.04/24.04
- root 权限
- 单个公网 IPv4
- HTTP-01 standalone 验证

其他发行版暂未测试，脚本会拒绝自动修改。

## 前置条件

1. 公网 IP 归你当前服务器使用或正确转发到该服务器。
2. 云平台安全组允许入站 TCP 80。
3. 系统防火墙允许入站 TCP 80。
4. 本机 TCP 80 在签发和每次续期时保持空闲。
5. 确定哪个服务使用证书，以及它的重载/重启命令。

如果 Nginx、Caddy、Apache 或其他程序长期占用 TCP 80，请不要直接使用本工具的
standalone 自动续期方案；应先设计 webroot、反向代理或可靠的 pre/post hook。

## 推荐运行方式

先下载并查看脚本：

```bash
curl -fsSLO https://raw.githubusercontent.com/eutopiazen/ip-cert-acme/main/ip-cert-acme.sh
less ip-cert-acme.sh
chmod +x ip-cert-acme.sh
./ip-cert-acme.sh
```

确认信任仓库内容后，也可以一行运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eutopiazen/ip-cert-acme/main/ip-cert-acme.sh)
```

不要使用 `curl ... | bash`，因为管道会占用标准输入，交互菜单无法正常读取。

## 首次使用

选择：

```text
1) 一键安装、测试、正式签发并配置自动续期
```

脚本将依次：

1. 验证 root 与操作系统。
2. 安装公共依赖并启动 cron。
3. 从 `https://get.acme.sh` 安装或更新 acme.sh。
4. 获取并确认公网 IP。
5. 检查本机 TCP 80。
6. 建议先向 Let’s Encrypt staging 环境测试签发。
7. 向生产环境申请正式证书。
8. 询问固定证书目录，并交互配置一个或多个部署目标。
9. 安装部署分发器并把它注册为 acme.sh 的续期成功钩子。
10. 验证证书 SAN、有效期、cron、部署目标和下次续期信息。

默认固定路径：

```text
/etc/ssl/ip-cert/fullchain.pem
/etc/ssl/ip-cert/privkey.pem
```

私钥权限为 `600`，证书链权限为 `644`，目录权限为 `700`。

部署配置与程序位置：

```text
/usr/local/sbin/ip-cert-acme
/etc/ip-cert-acme/targets.conf
/var/lib/ip-cert-acme/backups/
```

`targets.conf` 由脚本使用 shell 安全转义生成，权限为 `root:root 0600`。续期钩子
只读取该配置；如果文件所有者或写权限不安全，部署会拒绝执行。

## 1Panel 面板与网站

配置部署目标时选择 `1) 自动添加 1Panel 面板`。脚本通过以下能力进行识别，
不会判断或写死 1Panel 版本号：

- 系统中存在 `1pctl`
- 常见安装根目录下存在配对的 `secret/server.crt` 和 `secret/server.key`
- 自动发现失败或发现多组时，由用户确认实际目录

续期成功后，分发器会把统一证书复制到 1Panel 实际证书路径，验证文件、执行
`1pctl restart`；如果重启失败，会恢复该目标的旧证书。

选择 `2) 选择 1Panel 网站` 时，脚本只列出实际存在的站点证书目录并逐个确认，
不会默认把 IP 证书部署到所有网站。选中网站后会检测 OpenResty/Nginx 容器，
先运行 `nginx -t`，通过后再执行平滑重载。

域名网站应使用包含相应域名 SAN 的域名证书。只有确实通过目标公网 IP 访问的
网站才应选择这个 IP 证书。

## 从 1.0 升级

已经成功签发的用户不需要重新申请证书：

1. 下载新版脚本并运行。
2. 选择菜单 `8) 配置/重配多目标部署与自动重载`。
3. 添加 1Panel 面板及其他确实需要的目标。
4. 保存后，脚本会重新执行 `acme.sh --install-cert`，绑定新的部署钩子并立即
   测试一次部署。

## 服务配置示例

### 3x-ui

面板证书：

```text
/etc/ssl/ip-cert/fullchain.pem
/etc/ssl/ip-cert/privkey.pem
```

部署目标选择：

```text
添加 x-ui
```

### Nginx

```nginx
ssl_certificate     /etc/ssl/ip-cert/fullchain.pem;
ssl_certificate_key /etc/ssl/ip-cert/privkey.pem;
```

部署目标：

```text
添加 Nginx
```

## 验证自动续期

在脚本菜单中选择 `4`，至少确认：

- `acme.sh --cron` 存在于 root 的 crontab
- cron 服务状态为 `active`
- `Le_NextRenewTimeStr` 存在
- `Le_RealFullChainPath` 和 `Le_RealKeyPath` 指向固定路径
- SAN 包含目标 IP
- 证书与私钥文件非空
- `/usr/local/sbin/ip-cert-acme` 存在且可执行
- 部署目标列表与实际使用者一致

菜单 `5` 只执行正常 cron 检查；未到续期窗口会安全跳过。菜单 `6` 会强制创建
新订单并消耗 CA 速率限额，因此要求输入 `RENEW` 二次确认。

当前版本不处理 IPv6、同一证书包含多个 IP、多节点共享证书或 TCP 80 长期被
Web 服务占用的场景；这些情况需要按实际架构改用其他监听或验证方案。

## 重要说明

- `acme.sh` 是证书客户端，不是证书颁发机构；实际 CA 是 Let’s Encrypt。
- `socat` 只负责 standalone 验证期间的 TCP 监听，不负责证书管理。
- 不要直接引用 `~/.acme.sh/` 内部证书文件；其内部目录结构可能变化。
- 脚本不会自动修改云安全组、UFW、nftables 或 iptables。
- 脚本不会保存邮箱、API Token、密码或其他凭据到仓库。
- 强制续期并不是日常操作；正常情况下由每日 cron 和 CA 的 ARI 窗口调度。

## 查看日志与手动诊断

```bash
crontab -l | grep acme.sh
/root/.acme.sh/acme.sh --list
/root/.acme.sh/acme.sh --info -d 203.0.113.10 --ecc
/root/.acme.sh/acme.sh --cron --home /root/.acme.sh --debug 2
openssl x509 -in /etc/ssl/ip-cert/fullchain.pem -noout -dates -ext subjectAltName
/usr/local/sbin/ip-cert-acme --deploy
```

请将示例 IP `203.0.113.10` 替换为你的公网 IP。

## 安全边界

该脚本以 root 运行并会：安装 apt 软件包、安装/更新 acme.sh、写入
`/etc/ssl/ip-cert`、`/etc/ip-cert-acme.conf`、`/etc/ip-cert-acme/targets.conf`
和 `/usr/local/sbin/ip-cert-acme`，修改 root crontab，并在证书更新后以 root
执行用户确认的部署及重载命令。目标旧证书备份保存在
`/var/lib/ip-cert-acme/backups/`。运行前请审阅源码。

## License

[MIT](LICENSE)
