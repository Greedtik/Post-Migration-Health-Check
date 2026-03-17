#!/bin/bash

# ==========================================
# Post-Migration Health Check & Audit (Enterprise Edition)
# ==========================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_ERRORS=0
SUMMARY_MSG=""
LOG_FILE="/var/log/migration_audit_$(date +%F_%H-%M).log"

print_and_log() {
    echo -e "$1"
    echo -e "$1" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use: sudo ./health_check.sh)${NC}"
  exit
fi

echo "Post-Migration Audit Log - $(date)" > "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

print_and_log "${CYAN}====================================================${NC}"
print_and_log "${CYAN}  Post-Migration Health Check & Audit (Enterprise)  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

# 1. System, Load & Time
print_and_log "\n${YELLOW}[1] System, Load Average & Time:${NC}"
print_and_log "Uptime & Load: $(uptime)"
print_and_log "Kernel: $(uname -r)"
print_and_log "Timezone: $(date)"

# 2. Disk Space, Mounts & Inodes (อัปเดตเพิ่ม Inodes)
print_and_log "\n${YELLOW}[2] Storage & Inode Status:${NC}"
print_and_log "${CYAN}>> Disk Space Usage:${NC}"
print_and_log "$(df -hT | grep -v 'tmpfs\|cdrom')"
print_and_log "${CYAN}>> Inode Usage (File Limits):${NC}"
print_and_log "$(df -hi | grep -v 'tmpfs\|cdrom')"

# 3. Memory Usage
print_and_log "\n${YELLOW}[3] Memory Usage:${NC}"
print_and_log "$(free -m | awk 'NR==1{print "             " $0} NR==2{printf "RAM Usage:   %-10s %-10s %-10s (%.2f%% used)\n", $2, $3, $4, $3*100/$2 }')"

# 4. Network Check
print_and_log "\n${YELLOW}[4] Network & Connectivity:${NC}"
print_and_log "Default Gateway: $(ip route | grep default | awk '{print $3}' || echo 'NOT FOUND')"
if ping -c 1 8.8.8.8 &> /dev/null; then
    print_and_log "- Internet Access: ${GREEN}[OK]${NC}"
else
    print_and_log "- Internet Access: ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="- Network: Cannot reach internet\n"
fi

# 5. Package Manager & System Health (ใหม่! เช็คความสมบูรณ์ของ OS)
print_and_log "\n${YELLOW}[5] APT Package Manager Health:${NC}"
BROKEN_PKGS=$(dpkg -l | grep "^rc" | wc -l)
if [ "$BROKEN_PKGS" -gt 0 ]; then
    print_and_log "${YELLOW}[WARNING] Found $BROKEN_PKGS leftover config files from removed packages.${NC}"
    print_and_log "  -> Clean them with: ${CYAN}apt-get purge ~c${NC}"
else
    print_and_log "${GREEN}[OK] Package manager state is clean.${NC}"
fi

# 6. Service Health Check
print_and_log "\n${YELLOW}[6] Service Health Check:${NC}"
SERVICES=("ssh" "nginx" "apache2" "mysql" "mariadb" "docker")
for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service" 2>/dev/null; then
        if systemctl is-active --quiet "$service"; then
            print_and_log "- $service: ${GREEN}[RUNNING]${NC}"
        else
            print_and_log "- $service: ${RED}[STOPPED/FAILED]${NC}"
            ((TOTAL_ERRORS++)); SUMMARY_MSG+="- Service: $service is down\n"
        fi
    fi
done

# 7. Active Ports Check
print_and_log "\n${YELLOW}[7] Active Listening Ports & Services:${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | while read -r address process; do
    port=$(echo "$address" | awk -F':' '{print $NF}')
    service=$(echo "$process" | awk -F'"' '{print $2}')
    [ -z "$service" ] && service="Unknown/System"
    print_and_log "- Port ${CYAN}${port}${NC}: [OPEN] by ${GREEN}${service}${NC}"
done | sort -u -t':' -k1,1n

# 8. Firewall Rules
print_and_log "\n${YELLOW}[8] Detailed Firewall Rules (iptables):${NC}"
RULE_COUNT=$(iptables -S | grep "^-A" | wc -l)
if [ "$RULE_COUNT" -gt 0 ]; then
    print_and_log "${CYAN}Found $RULE_COUNT custom iptables rules:${NC}"
    iptables-save | grep -v '^#' | grep -v '^:' | while read -r rule; do
        print_and_log "  -> $rule"
    done
else
    print_and_log "${GREEN}No custom iptables rules found. (System is using default policies)${NC}"
fi

# 9. Security Audit: Users & Privileges (ใหม่! เช็คคนมีสิทธิ์เข้าเครื่อง)
print_and_log "\n${YELLOW}[9] Security Audit (Users & Access):${NC}"
print_and_log "${CYAN}>> Users with interactive shell access:${NC}"
# กรองเอาเฉพาะ user ที่ล็อกอินได้ (มี bash/sh)
awk -F: '($3>=1000 || $1=="root") && $7 !~ /(nologin|false)$/ {print " - " $1}' /etc/passwd | while read -r line; do print_and_log "$line"; done

print_and_log "${CYAN}>> Users in 'sudo' group:${NC}"
SUDO_USERS=$(grep -Po '^sudo.+:\K.*$' /etc/group)
print_and_log " - ${SUDO_USERS:-None}"

# 10. Background Tasks (ใหม่! แอบดูสคริปต์ตั้งเวลา)
print_and_log "\n${YELLOW}[10] Scheduled Tasks (Root Crontab):${NC}"
CRON_COUNT=$(crontab -l -u root 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l)
if [ "$CRON_COUNT" -gt 0 ]; then
    print_and_log "${CYAN}Found $CRON_COUNT active root cron jobs:${NC}"
    crontab -l -u root 2>/dev/null | grep -v "^#" | grep -v "^$" | while read -r cron; do
        print_and_log "  -> $cron"
    done
else
    print_and_log "${GREEN}No custom root cron jobs found.${NC}"
fi

# ==========================================
# 11. EXECUTIVE SUMMARY
# ==========================================
print_and_log "\n${CYAN}====================================================${NC}"
print_and_log "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ]; then
    print_and_log "${GREEN}[PASS] All critical systems are healthy!${NC}"
    print_and_log "The server has successfully migrated and is secure."
else
    print_and_log "${RED}[FAIL] Health check found $TOTAL_ERRORS critical issue(s).${NC}"
    print_and_log "Please review the following errors:"
    print_and_log -n "$SUMMARY_MSG"
fi
print_and_log "\n${CYAN}>> Report saved to: ${LOG_FILE}${NC}"
print_and_log "${CYAN}====================================================${NC}\n"
