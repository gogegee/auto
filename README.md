# 一键配置脚本

VLESS + Reality 节点 + 系统加固的菜单式脚本，适用于 Debian 12/13（Ubuntu 22.04+ 基本可用），需 root。

## 使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/dog/setup.sh)
```

菜单：

也可以跳过菜单直接执行：

```bash
bash setup-vps.sh all | system | node | update | tz | bbr | firewall | ssh | security | cert | nginx | xray | site | info
```

## 开始前

- 域名已解析到 VPS（Cloudflare 必须灰云）。
- 服务商面板防火墙放行 TCP 80、443 和新的 SSH 端口。
- 准备好 SSH 公钥（`.pub` 文件整行）。
- 涉及 SSH 的步骤完成后，**先用新端口另开窗口测试登录，再关旧窗口**。

## 可选环境变量

`DOMAIN` `EMAIL` `SSH_PORT` `PUBKEY` `BLOCK_CN=0/1` `TIMEZONE` `ASSUME_YES=1`
`REGEN=1` 重新生成 UUID/密钥，`FORCE_SITE=1` 重置伪装网页，`SITE_URL=` 使用自己的网页。

## 重跑

脚本可以重复运行：已完成的步骤会跳过，已有的 UUID/密钥会沿用，客户端无需改动。日志在 `/var/log/vps-setup.log`。


# 安装更新，需要时自动重启
```bash
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash
```

# 只装安全更新,不自动重启
```bash
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash -s -- --security-only --no-reboot
```

# 只检查有什么更新,不做任何修改
```bash
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash -s -- --check
```
