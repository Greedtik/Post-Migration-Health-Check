#!/bin/bash

# กำหนดสีเพื่อให้อ่านง่าย
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
SERVICES=("ssh" "nginx" "apache2" "mysql" "docker")
for service in "${SERVICES[@]}"; do
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

# 6. Check Specific Listening Ports (อัปเดตใหม่)
echo -e "\n${YELLOW}[6] Critical Ports Check:${NC}"
# กัปตันสามารถแก้ไขเลข Port ที่ต้องการเช็คได้ที่บรรทัดนี้ครับ
PORTS_TO_CHECK=(22 80 443 3306)

for port in "${PORTS_TO_CHECK[@]}"; do
    # ใช้ ss ตรวจสอบว่ามี Port นี้อยู่ในสถานะ LISTEN หรือไม่
    if ss -tulpn | grep -q ":${port} "; then
        echo -e "- Port $port: ${GREEN}[LISTENING]${NC}"
    else
        # แจ้งเตือนสีแดง แต่เราจะไม่นับเป็น Error ร้ายแรงใน Summary เผื่อว่าเครื่องนี้ไม่ได้ใช้พอร์ตนั้นครับ
        echo -e "- Port $port: ${RED}[CLOSED]${NC} (No service listening)"
    fi
done

# ==========================================
# 7. EXECUTIVE SUMMARY
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
