# 只装安全更新,不自动重启
curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/auto-update.sh | sudo bash -s -- --security-only --no-reboot

# 只检查有什么更新,不做任何修改
curl -fsSL ... | sudo bash -s -- --check

# 更新结果推送到手机(装 ntfy App,订阅同名主题)
curl -fsSL ... | sudo NTFY_TOPIC=你的随机主题名 bash
