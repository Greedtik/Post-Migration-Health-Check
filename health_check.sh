#!/bin/bash

# กำหนดสีเพื่อให้อ่านง่าย
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ตัวแปรสำหรับเก็บผลสรุป
TOTAL_ERRORS=0
SUMMARY_MSG=""

echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}   Post-Migration Health Check (Debian 8)     ${NC}"
echo -e "${CYAN}==============================================${NC}"

# 1. Check System Info
echo -e "\n${YELLOW}[1] System Information:${NC}"
uptime -p
uname -r

# 2. Check Disk Space & Mounts
echo -e "\n${YELLOW}[2] Disk Space & Mount Points:${NC}"
df -hT | grep -v 'tmpfs\|cdrom'

# 3. Check Memory Usage
echo -e "\n${YELLOW}[3] Memory Usage:${NC}"
free -m | awk 'NR==2{printf "RAM Usage: %sMB / %sMB (%.2f%%)\n", $3,$2,$3*100/$2 }'

# 4. Check Network Connectivity
echo -e "\n${YELLOW}[4] Network Connectivity:${NC}"
if ping -c 2 8.8.8.8 &> /dev/null; then
    echo -e "Internet Access: ${GREEN}[OK]${NC}"
else
    echo -e "Internet Access: ${RED}[FAILED]${NC} (Check Network Interface / Gateway)"
    ((TOTAL_ERRORS++))
    SUMMARY_MSG+="${RED}- Network:${NC} Cannot reach internet (8.8.8.8)\n"
fi

# 5. Check Critical Services
echo -e "\n${YELLOW}[5] Service Status:${NC}"
# กัปตันสามารถเพิ่มหรือลดชื่อ Service ในวงเล็บนี้ได้เลยครับ
SERVICES=("ssh" "nginx" "apache2" "mysql" "mariadb" "docker" "postfix")

for service in "${SERVICES[@]}"; do
    # เช็คว่ามี Service นี้ติดตั้งอยู่ไหม
    if systemctl list-unit-files | grep -q "^${service}.service"; then
        if systemctl is-active --quiet "$service"; then
            echo -e "- $service: ${GREEN}[RUNNING]${NC}"
        else
            echo -e "- $service: ${RED}[STOPPED/FAILED]${NC}"
            ((TOTAL_ERRORS++))
            SUMMARY_MSG+="${RED}- Service:${NC} $service is not running\n"
        fi
    fi
done

# 6. Check Listening Ports
echo -e "\n${YELLOW}[6] Active Listening Ports:${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | sed 's/.*://' | column -t

# ==========================================
# 7. EXECUTIVE SUMMARY (ส่วนที่เพิ่มใหม่)
# ==========================================
echo -e "\n${CYAN}==============================================${NC}"
echo -e "${CYAN}             EXECUTIVE SUMMARY                ${NC}"
echo -e "${CYAN}==============================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${GREEN}[PASS] All critical systems are healthy!${NC}"
    echo -e "The server is running perfectly with no detected issues."
else
    echo -e "${RED}[FAIL] Health check found $TOTAL_ERRORS issue(s).${NC}"
    echo -e "Please review the following errors:"
    echo -e -n "$SUMMARY_MSG"
fi
echo -e "${CYAN}==============================================${NC}\n"
