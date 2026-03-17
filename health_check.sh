#!/bin/bash

# ==============================================================================
# Universal Health Check, Audit & Diagnostic Script
# ==============================================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m' # สีใหม่สำหรับคำแนะนำ
NC='\033[0m'

TOTAL_ERRORS=0
TOTAL_WARNINGS=0
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

# OS Detection
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME; OS_ID=$ID; OS_LIKE=$ID_LIKE
else
    OS_NAME=$(uname -s); OS_ID="unknown"
fi

if [[ "$OS_ID" == *"ubuntu"* ]] || [[ "$OS_ID" == *"debian"* ]] || [[ "$OS_LIKE" == *"debian"* ]]; then
    OS_FAMILY="debian"; ADMIN_GROUP="sudo"; PKG_MGR="apt-get"
elif [[ "$OS_ID" == *"centos"* ]] || [[ "$OS_ID" == *"rhel"* ]] || [[ "$OS_ID" == *"rocky"* ]] || [[ "$OS_ID" == *"almalinux"* ]] || [[ "$OS_LIKE" == *"rhel"* ]]; then
    OS_FAMILY="rhel"; ADMIN_GROUP="wheel"
    command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf" || PKG_MGR="yum"
else
    OS_FAMILY="unknown"; ADMIN_GROUP="sudo"
fi

print_and_log "${CYAN}====================================================${NC}"
print_and_log "${CYAN}   Universal Health Check & Diagnostic ($OS_NAME)   ${NC}"
print_and_log "${CYAN}====================================================${NC}"

# 1. System, Load & Time
print_and_log "\n${YELLOW}[1] System, Load Average & Time:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: Load Average ไม่ควรสูงเกินจำนวน CPU Core ที่มี หากสูงผิดปกติ ให้ใช้คำสั่ง 'htop' หรือ 'top' เพื่อดูว่า Process ไหนกิน CPU${NC}"
print_and_log "OS Version: $OS_NAME"
print_and_log "Uptime & Load: $(uptime)"
print_and_log "Kernel: $(uname -r)"
print_and_log "Timezone: $(date)"

# 2. Disk Space & Inodes
print_and_log "\n${YELLOW}[2] Storage & Inode Status:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: หาก Use% เกิน 80% ควรเตรียมขยายพื้นที่. หาก Inode เต็ม (แม้ Disk จะว่าง) ระบบจะสร้างไฟล์ใหม่ไม่ได้ (มักเกิดจากไฟล์ Session หรือ Log ขยะเยอะ) ให้ใช้คำสั่ง 'ncdu /' หรือ 'du -sh /*' หาโฟลเดอร์ต้นเหตุ${NC}"
print_and_log "${CYAN}>> Disk Space Usage:${NC}"
print_and_log "$(df -hT | grep -v 'tmpfs\|cdrom\|squashfs')"
print_and_log "${CYAN}>> Inode Usage (File Limits):${NC}"
print_and_log "$(df -hi | grep -v 'tmpfs\|cdrom\|squashfs')"

# 3. Memory Usage
print_and_log "\n${YELLOW}[3] Memory Usage:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: Linux มักจะเอา RAM ที่ว่างไปทำ Cache (เป็นเรื่องปกติ) ให้ดูช่อง FREE หรือ Available เป็นหลัก หาก RAM เหลือน้อยและระบบช้า ให้พิจารณาเพิ่ม RAM บน Proxmox${NC}"
print_and_log "$(free -m | awk '
    BEGIN { printf "  %-12s %-12s %-12s %-15s\n", "TOTAL(MB)", "USED(MB)", "FREE(MB)", "USAGE(%)" }
    NR==2 { printf "  %-12s %-12s %-12s %.2f%%\n", $2, $3, $4, $3*100/$2 }
')"

# 4. Network Check
print_and_log "\n${YELLOW}[4] Network & Connectivity:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: หาก Ping ไม่ผ่าน (FAILED) ให้เช็ค 1. ไฟล์คอนฟิก IP (/etc/network/interfaces หรือ netplan) 2. เช็คว่าบน Proxmox ติ๊กเลือก Bridge Network ถูกต้องหรือไม่${NC}"
print_and_log "Default Gateway: $(ip route | grep default | awk '{print $3}' || echo 'NOT FOUND')"
if ping -c 1 8.8.8.8 &> /dev/null; then
    print_and_log "- Internet Access: ${GREEN}[OK]${NC}"
else
    print_and_log "- Internet Access: ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Network:${NC} Cannot reach internet\n"
fi

# 5. OS Patch & Update
print_and_log "\n${YELLOW}[5] OS Patch & Update Status ($PKG_MGR):${NC}"
print_and_log "${MAGENTA}💡 ADVICE: ควรหมั่นอัปเดต Patch เพื่อปิดช่องโหว่ความปลอดภัย (คำเตือน: ก่อนรันคำสั่ง Upgrade บน Production ควรทำ Snapshot บน Proxmox ไว้ก่อนเสมอ!)${NC}"
print_and_log "Checking for available updates... (Please wait)"

if [ "$OS_FAMILY" == "debian" ]; then
    timeout 15 apt-get update -qq 2>/dev/null
    UPGRADES=$(apt-get -s upgrade 2>/dev/null | grep -Po '^\d+(?= upgraded)' || echo "0")
    if [ "$UPGRADES" -eq 0 ]; then
        print_and_log "${GREEN}[OK] OS is up-to-date.${NC}"
    else
        print_and_log "${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"
        print_and_log "  -> To install, run: ${CYAN}apt-get upgrade${NC}"
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Update:${NC} $UPGRADES pending OS patches\n"
    fi
elif [ "$OS_FAMILY" == "rhel" ]; then
    UPGRADES=$($PKG_MGR check-update -q 2>/dev/null | awk 'NF' | wc -l)
    if [ "$UPGRADES" -eq 0 ]; then
        print_and_log "${GREEN}[OK] OS is up-to-date.${NC}"
    else
        print_and_log "${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"
        print_and_log "  -> To install, run: ${CYAN}$PKG_MGR upgrade${NC}"
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Update:${NC} $UPGRADES pending OS patches\n"
    fi
else
    print_and_log "${YELLOW}[SKIP] Unsupported OS for automatic update check.${NC}"
fi

# 6. Service Health Check
print_and_log "\n${YELLOW}[6] Service Health Check:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: หาก Service สำคัญสถานะเป็น FAILED ให้ดู Log ความผิดพลาดด้วยคำสั่ง 'journalctl -xeu <ชื่อ service>' หรือไปดูในโฟลเดอร์ /var/log/${NC}"
SERVICES=("ssh" "sshd" "nginx" "apache2" "httpd" "mysql" "mariadb" "docker")

for service in "${SERVICES[@]}"; do
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "^${service}.service" 2>/dev/null || systemctl list-units --all | grep -q "^${service}.service" 2>/dev/null; then
            if systemctl is-active --quiet "$service"; then
                print_and_log "- $service: ${GREEN}[RUNNING]${NC}"
            else
                print_and_log "- $service: ${RED}[STOPPED/FAILED]${NC}"
                ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Service:${NC} $service is down\n"
            fi
        fi
    else
        if [ -x "/etc/init.d/$service" ] || [ -f "/etc/init/$service.conf" ]; then
            if service "$service" status 2>/dev/null | grep -qiE "running|is active|start/running"; then
                print_and_log "- $service: ${GREEN}[RUNNING]${NC}"
            else
                print_and_log "- $service: ${RED}[STOPPED/FAILED]${NC}"
                ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Service:${NC} $service is down\n"
            fi
        fi
    fi
done

# 7. Active Ports Check
print_and_log "\n${YELLOW}[7] Active Listening Ports & Services:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: ตรวจสอบว่ามี Port แปลกปลอมเปิดอยู่หรือไม่ หากพบ Service ที่ไม่รู้จักเปิดรอรับการเชื่อมต่อ อาจเป็นความเสี่ยงด้านความปลอดภัย${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | while read -r address process; do
    port=$(echo "$address" | awk -F':' '{print $NF}')
    service=$(echo "$process" | awk -F'"' '{print $2}')
    [ -z "$service" ] && service="Unknown/System"
    print_and_log "- Port ${CYAN}${port}${NC}: [OPEN] by ${GREEN}${service}${NC}"
done | sort -u -t':' -k1,1n

# 8. Firewall Status
print_and_log "\n${YELLOW}[8] Firewall Status:${NC}"
print_and_log "${MAGENTA}💡 ADVICE: ระวังอย่า Block Port 22 (SSH) เด็ดขาด ไม่เช่นนั้นจะรีโมทเข้าเครื่องไม่ได้ (หากพลาดโดนบล็อก ต้องไปแก้ผ่านหน้าจอ Console ของ Proxmox เท่านั้น)${NC}"
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    print_and_log "${GREEN}[ACTIVE] firewalld is running.${NC}"
    print_and_log "  -> Active Zones: $(firewall-cmd --get-active-zones | tr '\n' ' ')"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    print_and_log "${GREEN}[ACTIVE] UFW is running.${NC}"
else
    RULE_COUNT=$(iptables -S 2>/dev/null | grep "^-A" | wc -l)
    if [ "$RULE_COUNT" -gt 0 ]; then
        print_and_log "${CYAN}Found $RULE_COUNT custom iptables rules:${NC}"
    else
        print_and_log "${GREEN}No custom firewall rules found (Default Policies active).${NC}"
    fi
fi

# 9. Security Audit: Users & Privileges
print_and_log "\n${YELLOW}[9] Security Audit (Users & Access):${NC}"
print_and_log "${MAGENTA}💡 ADVICE: ควรมีเฉพาะ User ที่จำเป็นเท่านั้นที่อยู่ในกลุ่ม Admin ($ADMIN_GROUP) และเพื่อความปลอดภัยสูงสุด แนะนำให้ปิดการ Login ด้วย Password และเปลี่ยนไปใช้ SSH Key แทน${NC}"
print_and_log "${CYAN}>> Interactive Users:${NC}"
awk -F: '($3>=1000 || $1=="root") && $7 !~ /(nologin|false)$/ {print " - " $1}' /etc/passwd | while read -r line; do print_and_log "$line"; done

print_and_log "${CYAN}>> Admins (Group: $ADMIN_GROUP):${NC}"
ADMIN_USERS=$(grep -Po "^${ADMIN_GROUP}.+:\K.*$" /etc/group)
print_and_log " - ${ADMIN_USERS:-None}"

# ==========================================
# 10. EXECUTIVE SUMMARY
# ==========================================
print_and_log "\n${CYAN}====================================================${NC}"
print_and_log "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -eq 0 ]; then
    print_and_log "${GREEN}[PASS] All critical systems are healthy!${NC}"
    print_and_log "The server is fully updated, secure, and running perfectly."
elif [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -gt 0 ]; then
    print_and_log "${YELLOW}[WARNING] Systems are healthy, but needs attention. ($TOTAL_WARNINGS warnings)${NC}"
    print_and_log "Please review the following notices:"
    print_and_log -n "$SUMMARY_MSG"
else
    print_and_log "${RED}[FAIL] Health check found $TOTAL_ERRORS critical issue(s) and $TOTAL_WARNINGS warning(s).${NC}"
    print_and_log "Please review the following errors immediately:"
    print_and_log -n "$SUMMARY_MSG"
fi

print_and_log "\n${CYAN}>> Report saved to: ${LOG_FILE}${NC}"
print_and_log "${CYAN}====================================================${NC}\n"
