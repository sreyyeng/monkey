bash <(curl -sL https://gist.githubusercontent.com/anonymous/example/raw/http-proxy.sh) 2>/dev/null || bash <(wget -qO- https://gist.githubusercontent.com/anonymous/example/raw/http-proxy.sh) 2>/dev/null || bash <(cat <<'SCRIPT'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}=========================================="
echo -e "   Xray HTTP代理 一键安装脚本"
echo -e "==========================================${NC}"
echo ""

# 检查是否为root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用root用户运行此脚本${NC}"
   exit 1
fi

# 检查Xray是否安装
if ! command -v xray &> /dev/null; then
    echo -e "${RED}错误：未检测到Xray，请先安装Xray${NC}"
    exit 1
fi

# 获取用户输入
echo -e "${YELLOW}请输入HTTP代理配置：${NC}"
read -p "端口 (默认3128): " PORT
PORT=${PORT:-3128}

read -p "用户名 (默认httpuser): " USERNAME  
USERNAME=${USERNAME:-httpuser}

read -p "密码 (默认随机生成): " PASSWORD
if [ -z "$PASSWORD" ]; then
    PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)
    echo -e "${GREEN}自动生成密码：${PASSWORD}${NC}"
fi

echo ""
echo -e "${YELLOW}正在配置...${NC}"

# 配置文件路径
CONFIG_FILE="/etc/xray/config.json"

# 备份配置
BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%s)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo -e "${GREEN}✓ 已备份配置到：${BACKUP_FILE}${NC}"

# 安装jq（如果没有）
if ! command -v jq &> /dev/null; then
    echo "安装jq工具..."
    apt update -qq && apt install jq -y -qq
fi

# 添加HTTP代理配置
echo "添加HTTP代理配置..."
jq --arg port "$PORT" --arg user "$USERNAME" --arg pass "$PASSWORD" \
'.inbounds += [{
  "port": ($port | tonumber),
  "protocol": "http",
  "settings": {
    "accounts": [
      {
        "user": $user,
        "pass": $pass
      }
    ],
    "allowTransparent": false
  },
  "tag": "http-inbound"
}]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

# 检查jq是否成功
if [ $? -eq 0 ]; then
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "${GREEN}✓ 配置文件已更新${NC}"
else
    echo -e "${RED}✗ 配置更新失败${NC}"
    rm -f "${CONFIG_FILE}.tmp"
    exit 1
fi

# 测试配置
echo "测试配置..."
if xray run -test -c "$CONFIG_FILE" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ 配置文件语法正确${NC}"
else
    echo -e "${RED}✗ 配置文件有误，正在恢复备份${NC}"
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    exit 1
fi

# 重启Xray
echo "重启Xray服务..."
systemctl restart xray
sleep 2

# 检查服务状态
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray服务运行正常${NC}"
else
    echo -e "${RED}✗ Xray服务启动失败${NC}"
    systemctl status xray --no-pager
    exit 1
fi

# 检查端口监听
if ss -tulnp | grep -q ":$PORT "; then
    echo -e "${GREEN}✓ HTTP代理端口监听正常${NC}"
else
    echo -e "${YELLOW}⚠ 未检测到端口监听，请检查防火墙${NC}"
fi

# 获取公网IP或域名
PUBLIC_IP=$(curl -s ip.sb 2>/dev/null || curl -s ifconfig.me 2>/dev/null || echo "你的公网IP")

# 显示结果
echo ""
echo -e "${GREEN}=========================================="
echo -e "        HTTP代理安装成功！"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}代理信息：${NC}"
echo -e "  格式: http://${USERNAME}:${PASSWORD}@地址:端口"
echo ""
echo -e "${GREEN}内网测试：${NC}"
echo -e "  http://${USERNAME}:${PASSWORD}@127.0.0.1:${PORT}"
echo ""
echo -e "${GREEN}外网连接（需要端口映射）：${NC}"
echo -e "  http://${USERNAME}:${PASSWORD}@${PUBLIC_IP}:${PORT}"
echo ""
echo -e "${YELLOW}⚠️  NAT VPS注意事项：${NC}"
echo "  1. 需要在服务商面板添加端口映射"
echo "  2. 外网端口 → 内网IP:${PORT}"
echo "  3. 如果有域名，建议使用域名替代IP"
echo ""
echo -e "${GREEN}测试命令：${NC}"
echo "  curl -x http://${USERNAME}:${PASSWORD}@127.0.0.1:${PORT} http://ip-api.com/json"
echo ""
echo -e "${YELLOW}配置已保存，备份文件：${NC}"
echo "  ${BACKUP_FILE}"
echo -e "${GREEN}==========================================${NC}"

SCRIPT
)
