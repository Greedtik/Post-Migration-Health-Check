#!/bin/bash

# ==============================================================================
# Enterprise Post-Migration Health Check & Audit Script (v5.0 - Safe Execution)
# Supported OS: Debian, Ubuntu, CentOS, RHEL, Rocky Linux, AlmaLinux, LXC
# ==============================================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
  echo -e "${RED}Please run this script as root (e.g., sudo bash script.sh)${NC}"
  exit 1
fi

# ==========================================
# SAFE SERVICE CHECK WRAPPER (ป้องกัน command not found)
# ==========================================
check_service_exists() {
    local svc=$1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files | grep -q "^${svc}\.service" 2>/dev/null || systemctl list-units --all | grep -q "^${svc}\.service" 2>/dev/null
        return $?
    elif [ -x "/etc/init.d/$svc" ] || [ -f "/etc/init/$svc.conf" ]; then
        return 0
    else
        return 1
    fi
}

check_service_active() {
    local svc=$1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$svc" 2>/dev/null
        return $?
    elif command -v service >/dev/null 2>&1; then
        service "$svc" status 2>/dev/null | grep -qiE "running|is active|start/running"
        return $?
    elif [ -x "/etc/init.d/$svc" ]; then
        /etc/init.d/"$svc" status 2>/dev/null | grep -qiE "running|is active|start/running"
        return $?
    else
        return 1
    fi
}

echo "Post-Migration Audit Log - $(date)" > "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# ==========================================
# Phase 0: OS Detection
# ==========================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_ID=$ID
    OS_LIKE=$ID_LIKE
else
    OS_NAME=$(uname -s)
    OS_ID="unknown"
fi

if [[ "$OS_ID" == *"ubuntu"* ]] || [[ "$OS_ID" == *"debian"* ]] || [[ "$OS_LIKE" == *"debian"* ]]; then
    OS_FAMILY="debian"
    ADMIN_GROUP="sudo"
    PKG_MGR="apt-get"
    AUTH_LOG="/var/log/auth.log"
elif [[ "$OS_ID" == *"centos"* ]] || [[ "$OS_ID" == *"rhel"* ]] || [[ "$OS_ID" == *"rocky"* ]] || [[ "$OS_ID" == *"almalinux"* ]] || [[ "$OS_LIKE" == *"rhel"* ]]; then
    OS_FAMILY="rhel"
    ADMIN_GROUP="wheel"
    command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf" || PKG_MGR="yum"
    AUTH_LOG="/var/log/secure"
else
    OS_FAMILY="unknown"
    ADMIN_GROUP="sudo"
    AUTH_LOG="/var/log/auth.log"
fi

print_and_log "${CYAN}====================================================${NC}"
print_and_log "${CYAN}   Enterprise Health Check & Audit ($OS_NAME)       ${NC}"
print_and_log "${CYAN}====================================================${NC}"

# 1. System, Load & Time
print_and_log "\n${YELLOW}[1] System, Load Average & Time:${NC}"
print_and_log "OS Version: $OS_NAME"
print_and_log "Uptime & Load: $(uptime)"
print_and_log "Kernel: $(uname -r)"
print_and_log "Timezone: $(date)"

# 2. Disk Space, Mounts & Inodes
print_and_log "\n${YELLOW}[2] Storage & Inode Status:${NC}"
print_and_log "${CYAN}>> Disk Space Usage:${NC}"
print_and_log "$(df -hT | grep -v 'tmpfs\|cdrom\|squashfs')"
print_and_log "${CYAN}>> Inode Usage (File Limits):${NC}"
print_and_log "$(df -hi | grep -v 'tmpfs\|cdrom\|squashfs')"

# 3. fstab Mount Verification
print_and_log "\n${YELLOW}[3] fstab Mount Verification:${NC}"
UNMOUNTED=$(awk '!/^#/ && !/^$/ && $2 != "/" && $2 != "none" && $3 != "swap" {print $2}' /etc/fstab | while read -r mountpoint; do
    if ! mountpoint -q "$mountpoint" 2>/dev/null; then echo "$mountpoint"; fi
done)

if [ -z "$UNMOUNTED" ]; then
    print_and_log " ${GREEN}[OK] All fstab entries are successfully mounted.${NC}"
else
    print_and_log " ${RED}[FAIL] The following mount points in /etc/fstab are NOT mounted:${NC}"
    for mp in $UNMOUNTED; do print_and_log "  - $mp"; done
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Storage:${NC} Missing fstab mount points\n"
fi

# 4. Memory Usage
print_and_log "\n${YELLOW}[4] Memory Usage:${NC}"
print_and_log "$(free -m | awk '
    BEGIN { printf "  %-12s %-12s %-12s %-15s\n", "TOTAL(MB)", "USED(MB)", "FREE(MB)", "USAGE(%)" }
    NR==2 { printf "  %-12s %-12s %-12s %.2f%%\n", $2, $3, $4, $3*100/$2 }
')"

# 5. Network Check
print_and_log "\n${YELLOW}[5] Network & Connectivity:${NC}"
print_and_log "Default Gateway: $(ip route | grep default | awk '{print $3}' || echo 'NOT FOUND')"
if ping -c 1 8.8.8.8 &> /dev/null; then print_and_log "- Internet Routing: ${GREEN}[OK]${NC}"; else print_and_log "- Internet Routing: ${RED}[FAILED]${NC}"; ((TOTAL_ERRORS++)); fi
if ping -c 1 google.com &> /dev/null; then print_and_log "- DNS Resolution: ${GREEN}[OK]${NC}"; else print_and_log "- DNS Resolution: ${RED}[FAILED]${NC}"; ((TOTAL_ERRORS++)); fi

# 6. OS Patch Status
print_and_log "\n${YELLOW}[6] OS Patch & Update Status ($PKG_MGR):${NC}"
print_and_log "Checking for available updates... (Please wait)"
if [ "$OS_FAMILY" == "debian" ]; then
    timeout 15 apt-get update -qq 2>/dev/null
    UPGRADES=$(apt-get -s upgrade 2>/dev/null | grep -Po '^\d+(?= upgraded)' || echo "0")
    if [ "$UPGRADES" -eq 0 ]; then print_and_log " ${GREEN}[OK] OS is up-to-date.${NC}"; else print_and_log " ${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"; fi
elif [ "$OS_FAMILY" == "rhel" ]; then
    UPGRADES=$($PKG_MGR check-update -q 2>/dev/null | awk 'NF' | wc -l)
    if [ "$UPGRADES" -eq 0 ]; then print_and_log " ${GREEN}[OK] OS is up-to-date.${NC}"; else print_and_log " ${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"; fi
fi

# 7. Core OS Services Health (ใช้ Wrapper Function แล้ว)
print_and_log "\n${YELLOW}[7] Core OS Services Health:${NC}"
SERVICES=("sshd" "nginx" "apache2" "httpd" "mysql" "mariadb" "php-fpm")
for service in "${SERVICES[@]}"; do
    if check_service_exists "$service"; then
        if check_service_active "$service"; then
            print_and_log "- $service: ${GREEN}[RUNNING]${NC}"
        else
            print_and_log "- $service: ${RED}[STOPPED/FAILED]${NC}"
            ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Service:${NC} $service is down\n"
        fi
    fi
done

# 8. Active Ports Check
print_and_log "\n${YELLOW}[8] Active Listening Ports & Services:${NC}"
ss -tulpn | grep LISTEN | awk '{print $5, $7}' | while read -r address process; do
    port=$(echo "$address" | awk -F':' '{print $NF}')
    service=$(echo "$process" | awk -F'"' '{print $2}')
    [ -z "$service" ] && service="Unknown/System"
    print_and_log "- Port ${CYAN}${port}${NC}: [OPEN] by ${GREEN}${service}${NC}"
done | sort -u -t':' -k1,1n

# 9. Firewall Status
print_and_log "\n${YELLOW}[9] Firewall Status:${NC}"
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    print_and_log " ${GREEN}[ACTIVE] firewalld is running.${NC}"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    print_and_log " ${GREEN}[ACTIVE] UFW is running.${NC}"
else
    print_and_log " ${GREEN}No active ufw/firewalld found (Default Policies active).${NC}"
fi

# ==========================================
# 10. Deep Application Discovery (Blind Audit)
# ==========================================
print_and_log "\n${YELLOW}[10] Deep Application Discovery (Scanning for hidden/enterprise apps):${NC}"

# 10.1 Enterprise Suites
print_and_log "${CYAN}>> Enterprise Suites & Control Panels:${NC}"
FOUND_ENTERPRISE=0
if [ -d "/opt/zimbra" ] && id "zimbra" &>/dev/null; then
    print_and_log " - ${GREEN}Zimbra Collaboration Suite${NC} detected (/opt/zimbra)"
    FOUND_ENTERPRISE=1
    ZIMBRA_STATUS=$(su - zimbra -c "timeout 10 zmcontrol status" 2>/dev/null)
    if echo "$ZIMBRA_STATUS" | grep -q "Stopped"; then
        print_and_log "   ${RED}-> WARNING: Some Zimbra services are STOPPED!${NC}"
    elif echo "$ZIMBRA_STATUS" | grep -q "Running"; then
        print_and_log "   -> All Zimbra core services are ${GREEN}[RUNNING]${NC}"
    else
        print_and_log "   -> Could not determine exact Zimbra status (check manually)"
    fi
fi
if [ -d "/usr/local/cpanel" ]; then print_and_log " - ${GREEN}cPanel/WHM${NC} detected"; FOUND_ENTERPRISE=1; fi
if [ -d "/usr/local/directadmin" ]; then print_and_log " - ${GREEN}DirectAdmin${NC} detected"; FOUND_ENTERPRISE=1; fi
if [ $FOUND_ENTERPRISE -eq 0 ]; then print_and_log " - No major control panels or enterprise suites detected."; fi

# 10.2 /opt Directory Scanner
print_and_log "${CYAN}>> Third-Party Apps in /opt (Non-Standard Installations):${NC}"
OPT_APPS=$(find /opt -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | grep -vE "^(cni|containerd|zimbra)$")
if [ -n "$OPT_APPS" ]; then echo "$OPT_APPS" | while read -r app; do print_and_log "   - /opt/${GREEN}$app${NC}"; done; else print_and_log " - No additional apps found in /opt."; fi

# 10.3 Background Service Users
print_and_log "${CYAN}>> Active Service Users (Running background processes):${NC}"
ACTIVE_USERS=$(ps -eo user | sort | uniq | grep -vE "^(root|USER|syslog|daemon|messagebus|systemd|dbus|postfix|polkitd|chrony|ntp|ssh|nobody|systemd-.*)$")
if [ -n "$ACTIVE_USERS" ]; then
    echo "$ACTIVE_USERS" | while read -r usr; do
        PROC_COUNT=$(pgrep -u "$usr" | wc -l)
        print_and_log " - User: ${YELLOW}$usr${NC} is running ${CYAN}$PROC_COUNT${NC} processes."
    done
fi

# 10.4 Custom Systemd Services (Safe Check)
print_and_log "${CYAN}>> Custom Systemd Services (Manual/App Installations):${NC}"
if command -v systemctl >/dev/null 2>&1; then
    CUSTOM_SERVICES=$(find /etc/systemd/system -maxdepth 1 -type f -name "*.service" -exec basename {} \; 2>/dev/null | grep -vE "^(multi-user|default|dbus)")
    if [ -n "$CUSTOM_SERVICES" ]; then
        for app in $CUSTOM_SERVICES; do
            if systemctl is-active --quiet "$app" 2>/dev/null; then
                print_and_log " - $app: ${GREEN}[RUNNING]${NC}"
            else
                print_and_log " - $app: ${RED}[STOPPED/FAILED]${NC}"
            fi
        done
    else
        print_and_log " - No manual custom .service files found."
    fi
else
    print_and_log " - ${YELLOW}System is not using systemd. Skipped custom .service scan.${NC}"
fi

# 10.5 Docker Containers (Safe Check)
print_and_log "${CYAN}>> Docker Containers:${NC}"
if command -v docker >/dev/null 2>&1; then
    if check_service_active "docker" || docker info >/dev/null 2>&1; then
        DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
        if [ "$DOCKER_COUNT" -gt 0 ]; then
            print_and_log " - Found $DOCKER_COUNT running container(s):"
            docker ps --format "   - {{.Names}} ({{.Image}})" | while read -r line; do print_and_log "$line"; done
        else
            print_and_log " - Docker is running, but 0 active containers."
        fi
    else
        print_and_log " - Docker is installed but ${RED}[STOPPED]${NC}."
    fi
else
    print_and_log " - Docker not active or not installed."
fi

# ==========================================
# 11. Advanced Security Audit
# ==========================================
print_and_log "\n${YELLOW}[11] Advanced Security Audit:${NC}"

print_and_log "${CYAN}>> Interactive Users:${NC}"
awk -F: '($3>=1000 || $1=="root") && $7 !~ /(nologin|false)$/ {print " - " $1}' /etc/passwd | while read -r line; do print_and_log "$line"; done

print_and_log "${CYAN}>> SSH Key Audit (root):${NC}"
if [ -f /root/.ssh/authorized_keys ]; then
    KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys)
    print_and_log " - Found $KEY_COUNT authorized keys for root."
else
    print_and_log " - ${GREEN}[OK] No authorized_keys found for root.${NC}"
fi

print_and_log "${CYAN}>> Failed Login Attempts (Brute Force Check):${NC}"
if [ -f "$AUTH_LOG" ]; then
    FAILED_COUNT=$(grep -c "Failed password" "$AUTH_LOG" 2>/dev/null || echo "0")
    if [ "$FAILED_COUNT" -gt 50 ]; then
        print_and_log " - ${RED}[WARNING] High number of failed logins detected: $FAILED_COUNT attempts!${NC}"
        ((TOTAL_WARNINGS++))
    else
        print_and_log " - ${GREEN}[OK] Normal login behavior ($FAILED_COUNT failed attempts).${NC}"
    fi
fi

# ==========================================
# EXECUTIVE SUMMARY
# ==========================================
print_and_log "\n${CYAN}====================================================${NC}"
print_and_log "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -eq 0 ]; then
    print_and_log "${GREEN}[PASS] All critical systems and applications are healthy!${NC}"
else
    print_and_log "${YELLOW}[WARNING/FAIL] Health check found $TOTAL_ERRORS critical issue(s) and $TOTAL_WARNINGS warning(s).${NC}"
    print_and_log -n "$SUMMARY_MSG"
fi

print_and_log "\n${CYAN}>> Report saved to: ${LOG_FILE}${NC}"
print_and_log "${CYAN}====================================================${NC}\n"
