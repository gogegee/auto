# 安装更新，需要时自动重启
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash

# 只装安全更新,不自动重启
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash -s -- --security-only --no-reboot

# 只检查有什么更新,不做任何修改
curl -fsSL https://raw.githubusercontent.com/gogegee/auto/refs/heads/main/auto-update.sh | sudo bash -s -- --check
