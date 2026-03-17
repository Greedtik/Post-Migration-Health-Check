#!/bin/bash

# ==========================================
# Post-Migration Health Check & Audit (Pro Edition)
# ==========================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_ERRORS=0
SUMMARY_MSG=""
LOG_FILE="/var/log/migration_audit_$(date +%F_%H-%M).log"

# ฟังก์ชันสำหรับปริ้นท์ลงจอและเซฟลงไฟล์พร้อมกัน
print_and_log() {
    echo -e "$1"
    echo -e "$1" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root (use: sudo ./health_check.sh)${NC}"
  exit
fi

# เริ่มเขียนลงไฟล์ Log
echo "Post-Migration Audit Log - $(date)" > "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

print_and_log "${CYAN}====================================================${NC}"
print_and_log "${CYAN}   Post-Migration Health Check & Audit (Debian 8)   ${NC}"
print_and_log "${CYAN}====================================================${NC}"

# 1. System, Load & Time
print_and_log "\n${YELLOW}[1] System, Load Average & Time:${NC}"
print_and_log "$(uptime)"
print_and_log "Kernel: $(uname -r)"
print_and_log "Timezone: $(date)"

# 2. Disk Space & Mounts
print_and_log "\n${YELLOW}[2] Storage Status:${NC}"
print_and_log "$(df -hT | grep -v 'tmpfs\|cdrom')"

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

# 5. Cloud-Init State Check (อัปเดตใหม่รองรับ Proxmox)
print_and_log "\n${YELLOW}[5] Cloud-Init Status Check:${NC}"
if dpkg -l | grep -qw cloud-init; then
    print_and_log "${GREEN}[OK] 'cloud-init' is installed and ready for Proxmox.${NC}"
    
    # เช็คว่ามีโฟลเดอร์ร่องรอยของ OpenStack/EC2 ค้างอยู่ไหม
    if [ -d /var/lib/cloud/instances/ ]; then
        print_and_log "${YELLOW}  -> [NOTE] Old cloud instance data found.${NC}"
        print_and_log "  -> If boot is slow, run: ${CYAN}sudo cloud-init clean --logs${NC}"
    else
        print_and_log "  -> State is clean."
    fi
else
    print_and_log "${YELLOW}[WARNING] 'cloud-init' is NOT installed.${NC}"
    print_and_log "  -> You will not be able to use Proxmox Cloud-Init features."
fi

# 6. Service Health Check
print_and_log "\n${YELLOW}[6] Service Health Check:${NC}"
SERVICES=("ssh" "nginx" "apache2" "mysql" "mariadb" "docker")
for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service"; then
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

# 8. Firewall Full Rules (ตามที่กัปตันขอ: กาง Rule ออกมาให้หมด)
print_and_log "\n${YELLOW}[8] Detailed Firewall Rules (iptables):${NC}"
RULE_COUNT=$(iptables -S | grep "^-A" | wc -l)
if [ "$RULE_COUNT" -gt 0 ]; then
    print_and_log "${CYAN}Found $RULE_COUNT custom iptables rules:${NC}"
    # ดึง rules ออกมาแสดง แต่ตัดพวก default chain ทิ้งเพื่อไม่ให้รก
    iptables-save | grep -v '^#' | grep -v '^:' | while read -r rule; do
        print_and_log "  -> $rule"
    done
else
    print_and_log "${GREEN}No custom iptables rules found. (System is using default policies)${NC}"
    iptables -S | grep "^-P" | awk '{print "  -> Policy " $2 ": " $3}' | while read -r p; do print_and_log "$p"; done
fi

# 9. SSH Security Posture (ไอเดียใหม่: เช็คความปลอดภัย)
print_and_log "\n${YELLOW}[9] SSH Security Posture:${NC}"
ROOT_SSH=$(sshd -T 2>/dev/null | grep "^permitrootlogin" | awk '{print $2}')
PASS_SSH=$(sshd -T 2>/dev/null | grep "^passwordauthentication" | awk '{print $2}')

print_and_log " - Root Login Allowed: $(if [ "$ROOT_SSH" = "yes" ]; then echo -e "${RED}YES (High Risk)${NC}"; else echo -e "${GREEN}NO${NC}"; fi)"
print_and_log " - Password Auth Allowed: $(if [ "$PASS_SSH" = "yes" ]; then echo -e "${YELLOW}YES (Consider using Keys)${NC}"; else echo -e "${GREEN}NO${NC}"; fi)"

# ==========================================
# 10. EXECUTIVE SUMMARY
# ==========================================
print_and_log "\n${CYAN}====================================================${NC}"
print_and_log "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ]; then
    print_and_log "${GREEN}[PASS] All critical systems are healthy!${NC}"
    print_and_log "The server has successfully migrated."
else
    print_and_log "${RED}[FAIL] Health check found $TOTAL_ERRORS critical issue(s).${NC}"
    print_and_log "Please review the following errors:"
    print_and_log -n "$SUMMARY_MSG"
fi
print_and_log "\n${CYAN}>> Report saved to: ${LOG_FILE}${NC}"
print_and_log "${CYAN}====================================================${NC}\n"
