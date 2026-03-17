#!/bin/bash

# ==========================================
# Post-Migration Health Check Script (Ultimate)
# ==========================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

TOTAL_ERRORS=0
SUMMARY_MSG=""

# เช็คสิทธิ์ Root ก่อนรัน (สำคัญมากสำหรับการดู iptables และ logs)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use: sudo ./health_check.sh)${NC}"
  exit
fi

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   Post-Migration Health Check & Audit (Debian 8)   ${NC}"
echo -e "${CYAN}====================================================${NC}"

# 1. System, Load & Time
echo -e "\n${YELLOW}[1] System, Load Average & Time:${NC}"
uptime
echo -n "Kernel: "; uname -r
echo -n "Timezone: "; date
echo -e "${CYAN}>> Hardware Details:${NC}"
lscpu | grep "^CPU(s):" | sed 's/  */ /g'

# 2. Disk Space, Mounts & Swap
echo -e "\n${YELLOW}[2] Storage & Swap Status:${NC}"
echo -e "${CYAN}>> Filesystem Usage:${NC}"
df -hT | grep -v 'tmpfs\|cdrom'
echo -e "${CYAN}>> Swap Status:${NC}"
swapon --show || echo "No Swap active"

# 3. Memory Usage (Detailed)
echo -e "\n${YELLOW}[3] Memory Usage:${NC}"
free -m | awk 'NR==1{print "             " $0} NR==2{printf "RAM Usage:   %-10s %-10s %-10s (%.2f%% used)\n", $2, $3, $4, $3*100/$2 }'

# 4. Network & DNS Resolution
echo -e "\n${YELLOW}[4] Network & Connectivity:${NC}"
echo -e "${CYAN}>> Default Gateway:${NC}"
ip route | grep default || echo "${RED}No default gateway found!${NC}"

echo -e "${CYAN}>> Internet & DNS Check:${NC}"
if ping -c 1 8.8.8.8 &> /dev/null; then
    echo -e "- External IP Ping (8.8.8.8): ${GREEN}[OK]${NC}"
else
    echo -e "- External IP Ping (8.8.8.8): ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Network:${NC} Cannot reach internet\n"
fi

if ping -c 1 google.com &> /dev/null; then
    echo -e "- DNS Resolution (google.com): ${GREEN}[OK]${NC}"
else
    echo -e "- DNS Resolution (google.com): ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- DNS:${NC} Cannot resolve domain names\n"
fi

# 5. Service Health (Targeted & Global)
echo -e "\n${YELLOW}[5] Service Health Check:${NC}"
echo -e "${CYAN}>> Target Services:${NC}"
SERVICES=("ssh" "nginx" "apache2" "mysql" "mariadb" "docker" "postfix")
for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service"; then
        if systemctl is-active --quiet "$service"; then
            echo -e "- $service: ${GREEN}[RUNNING]${NC}"
        else
            echo -e "- $service: ${RED}[STOPPED/FAILED]${NC}"
            ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Service:${NC} $service is down\n"
        fi
    fi
done

echo -e "${CYAN}>> Global Failed Services (systemd):${NC}"
FAILED_SVC=$(systemctl --failed --plain --no-legend | wc -l)
if [ "$FAILED_SVC" -gt 0 ]; then
    echo -e "${RED}Found $FAILED_SVC failed systemd service(s):${NC}"
    systemctl --failed --plain --no-legend | awk '{print "   - " $1}'
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- System:${NC} $FAILED_SVC background service(s) failed to start\n"
else
    echo -e "${GREEN}No failed background services.${NC}"
fi

# 6. Active Ports (Dynamic)
echo -e "\n${YELLOW}[6] Active Listening Ports & Services:${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | while read -r address process; do
    port=$(echo "$address" | awk -F':' '{print $NF}')
    service=$(echo "$process" | awk -F'"' '{print $2}')
    [ -z "$service" ] && service="Unknown/System"
    echo -e "- Port ${CYAN}${port}${NC}: [OPEN] by ${GREEN}${service}${NC}"
done | sort -u -t':' -k1,1n

# 7. Firewall & Security (New!)
echo -e "\n${YELLOW}[7] Firewall Configuration (iptables/ufw):${NC}"
echo -e "${CYAN}>> UFW Status:${NC}"
if command -v ufw >/dev/null 2>&1; then
    ufw status | head -n 4
else
    echo "UFW is not installed or not found."
fi

echo -e "${CYAN}>> iptables Default Policies:${NC}"
# แสดงเฉพาะนโยบายหลัก (ACCEPT/DROP) จะได้ไม่รกหน้าจอเกินไป
iptables -S | grep "^-P" | awk '{print " - Chain " $2 ": " $3}'
RULE_COUNT=$(iptables -S | grep "^-A" | wc -l)
echo -e " - Total custom rules applied: ${CYAN}$RULE_COUNT rules${NC}"

# 8. Kernel & Hardware Errors (New!)
echo -e "\n${YELLOW}[8] Recent Kernel/Hardware Errors (dmesg):${NC}"
# เช็ค Log ของระบบว่ามีบ่นเรื่อง Hardware/Driver ตอนบูทบน Proxmox ไหม
dmesg | grep -i "error\|critical\|failed" | tail -n 5 | sed 's/^/ - /' || echo -e "${GREEN}No critical hardware errors found in recent logs.${NC}"

# ==========================================
# 9. EXECUTIVE SUMMARY
# ==========================================
echo -e "\n${CYAN}====================================================${NC}"
echo -e "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
echo -e "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${GREEN}[PASS] All critical systems are healthy!${NC}"
    echo -e "The server has successfully migrated and is running perfectly."
else
    echo -e "${RED}[FAIL] Health check found $TOTAL_ERRORS critical issue(s).${NC}"
    echo -e "Please review the following errors:"
    echo -e -n "$SUMMARY_MSG"
fi
echo -e "${CYAN}====================================================${NC}\n"
