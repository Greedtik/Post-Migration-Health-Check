#!/bin/bash

# กำหนดสีเพื่อให้อ่านง่าย
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}==============================================${NC}"
echo -e "${YELLOW}   Post-Migration Health Check (Debian 8)     ${NC}"
echo -e "${YELLOW}==============================================${NC}"

# 1. Check System Info
echo -e "\n${GREEN}[1] System Information:${NC}"
uptime -p
uname -r

# 2. Check Disk Space & Mounts
echo -e "\n${GREEN}[2] Disk Space & Mount Points:${NC}"
df -hT | grep -v 'tmpfs\|cdrom'

# 3. Check Memory Usage
echo -e "\n${GREEN}[3] Memory Usage:${NC}"
free -m | awk 'NR==2{printf "RAM Usage: %sMB / %sMB (%.2f%%)\n", $3,$2,$3*100/$2 }'

# 4. Check Network Connectivity
echo -e "\n${GREEN}[4] Network Connectivity:${NC}"
if ping -c 2 8.8.8.8 &> /dev/null; then
    echo -e "Internet Access: ${GREEN}[OK]${NC}"
else
    echo -e "Internet Access: ${RED}[FAILED]${NC} (Check Network Interface / Gateway)"
fi

# 5. Check Critical Services
echo -e "\n${GREEN}[5] Service Status:${NC}"
# กัปตันสามารถเพิ่มหรือลดชื่อ Service ในวงเล็บด้านล่างนี้ได้ตามที่ใช้งานจริงครับ
SERVICES=("ssh" "nginx" "apache2" "mysql" "mariadb" "docker" "postfix")

for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service"; then
        if systemctl is-active --quiet "$service"; then
            echo -e "- $service: ${GREEN}[RUNNING]${NC}"
        else
            echo -e "- $service: ${RED}[STOPPED/FAILED]${NC}"
        fi
    fi
done

# 6. Check Listening Ports
echo -e "\n${GREEN}[6] Active Listening Ports:${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | sed 's/.*://' | column -t

echo -e "\n${YELLOW}==============================================${NC}"
echo -e "${YELLOW}             Check Completed!                 ${NC}"
echo -e "${YELLOW}==============================================${NC}"
