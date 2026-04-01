#!/bin/bash

# ==============================================================================
# Enterprise Post-Migration Health Check & Audit Script (v4.0 - Deep Blind Audit)
# Supported OS: Debian, Ubuntu, CentOS, RHEL, Rocky Linux, AlmaLinux
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
    if ! mountpoint -q "$mountpoint" 2>/dev/null; then
        echo "$mountpoint"
    fi
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
if ping -c 1 8.8.8.8 &> /dev/null; then
    print_and_log "- Internet Routing (8.8.8.8): ${GREEN}[OK]${NC}"
else
    print_and_log "- Internet Routing (8.8.8.8): ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Network:${NC} Cannot reach 8.8.8.8\n"
fi
if ping -c 1 google.com &> /dev/null; then
    print_and_log "- DNS Resolution (google.com): ${GREEN}[OK]${NC}"
else
    print_and_log "- DNS Resolution (google.com): ${RED}[FAILED]${NC}"
    ((TOTAL_ERRORS++)); SUMMARY_MSG+="${RED}- Network:${NC} DNS resolution failed\n"
fi

# 6. OS Patch & Update Status
print_and_log "\n${YELLOW}[6] OS Patch & Update Status ($PKG_MGR):${NC}"
print_and_log "Checking for available updates... (Please wait)"
if [ "$OS_FAMILY" == "debian" ]; then
    timeout 15 apt-get update -qq 2>/dev/null
    UPGRADES=$(apt-get -s upgrade 2>/dev/null | grep -Po '^\d+(?= upgraded)' || echo "0")
    if [ "$UPGRADES" -eq 0 ]; then
        print_and_log " ${GREEN}[OK] OS is up-to-date.${NC}"
    else
        print_and_log " ${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Update:${NC} $UPGRADES pending OS patches\n"
    fi
elif [ "$OS_FAMILY" == "rhel" ]; then
    UPGRADES=$($PKG_MGR check-update -q 2>/dev/null | awk 'NF' | wc -l)
    if [ "$UPGRADES" -eq 0 ]; then
        print_and_log " ${GREEN}[OK] OS is up-to-date.${NC}"
    else
        print_and_log " ${YELLOW}[WARNING] Found $UPGRADES package(s) waiting to be updated.${NC}"
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Update:${NC} $UPGRADES pending OS patches\n"
    fi
fi

# 7. Core OS Services Health
print_and_log "\n${YELLOW}[7] Core OS Services Health:${NC}"
SERVICES=("sshd" "nginx" "apache2" "httpd" "mysql" "mariadb" "php-fpm")
for service in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${service}.service" 2>/dev/null; then
        if systemctl is-active --quiet "$service"; then
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
    print_and_log "  -> Active Zones: $(firewall-cmd --get-active-zones | tr '\n' ' ')"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    print_and_log " ${GREEN}[ACTIVE] UFW is running.${NC}"
else
    RULE_COUNT=$(iptables -S 2>/dev/null | grep "^-A" | wc -l)
    if [ "$RULE_COUNT" -gt 0 ]; then
        print_and_log " ${CYAN}Found $RULE_COUNT custom iptables rules:${NC}"
    else
        print_and_log " ${GREEN}No custom firewall rules found (Default Policies active).${NC}"
    fi
fi

# ==========================================
# 10. Deep Application Discovery (Blind Audit)
# ==========================================
print_and_log "\n${YELLOW}[10] Deep Application Discovery (Scanning for hidden/enterprise apps):${NC}"

# 10.1 Enterprise Suites & Mail Servers
print_and_log "${CYAN}>> Enterprise Suites & Control Panels:${NC}"
FOUND_ENTERPRISE=0
if [ -d "/opt/zimbra" ] && id "zimbra" &>/dev/null; then
    print_and_log " - ${GREEN}Zimbra Collaboration Suite${NC} detected (/opt/zimbra)"
    FOUND_ENTERPRISE=1
    ZIMBRA_STATUS=$(su - zimbra -c "timeout 10 zmcontrol status" 2>/dev/null)
    if echo "$ZIMBRA_STATUS" | grep -q "Stopped"; then
        print_and_log "   ${RED}-> WARNING: Some Zimbra services are STOPPED!${NC}"
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- App Discovery:${NC} Zimbra has stopped services\n"
    elif echo "$ZIMBRA_STATUS" | grep -q "Running"; then
        print_and_log "   -> All Zimbra core services are ${GREEN}[RUNNING]${NC}"
    else
        print_and_log "   -> Could not determine exact Zimbra status (check manually using 'su - zimbra -c \"zmcontrol status\"')"
    fi
fi
if [ -d "/usr/local/cpanel" ]; then print_and_log " - ${GREEN}cPanel/WHM${NC} detected"; FOUND_ENTERPRISE=1; fi
if [ -d "/usr/local/directadmin" ]; then print_and_log " - ${GREEN}DirectAdmin${NC} detected"; FOUND_ENTERPRISE=1; fi
if command -v gitlab-ctl >/dev/null 2>&1 || [ -d "/opt/gitlab" ]; then print_and_log " - ${GREEN}GitLab Enterprise/CE${NC} detected"; FOUND_ENTERPRISE=1; fi
if [ $FOUND_ENTERPRISE -eq 0 ]; then print_and_log " - No major control panels or enterprise suites detected."; fi

# 10.2 /opt Directory Scanner
print_and_log "${CYAN}>> Third-Party Apps in /opt (Non-Standard Installations):${NC}"
OPT_APPS=$(find /opt -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | grep -vE "^(cni|containerd|zimbra)$")
if [ -n "$OPT_APPS" ]; then
    print_and_log " - Found potential custom applications installed in /opt:"
    echo "$OPT_APPS" | while read -r app; do print_and_log "   - /opt/${GREEN}$app${NC}"; done
else
    print_and_log " - No additional apps found in /opt."
fi

# 10.3 Background Service Users
print_and_log "${CYAN}>> Active Service Users (Running background processes):${NC}"
ACTIVE_USERS=$(ps -eo user | sort | uniq | grep -vE "^(root|USER|syslog|daemon|messagebus|systemd|dbus|postfix|polkitd|chrony|ntp|ssh|nobody|systemd-network|systemd-resolve|avahi)$")
if [ -n "$ACTIVE_USERS" ]; then
    echo "$ACTIVE_USERS" | while read -r usr; do
        PROC_COUNT=$(pgrep -u "$usr" | wc -l)
        print_and_log " - User: ${YELLOW}$usr${NC} is running ${CYAN}$PROC_COUNT${NC} processes. (Possible hidden app)"
    done
else
    print_and_log " - No suspicious service users running background tasks."
fi

# 10.4 Custom Systemd Services
print_and_log "${CYAN}>> Custom Systemd Services (Manual/App Installations):${NC}"
CUSTOM_SERVICES=$(find /etc/systemd/system -maxdepth 1 -type f -name "*.service" -exec basename {} \; 2>/dev/null | grep -vE "^(multi-user|default|dbus)")
if [ -n "$CUSTOM_SERVICES" ]; then
    for app in $CUSTOM_SERVICES; do
        if systemctl is-active --quiet "$app"; then
            print_and_log " - $app: ${GREEN}[RUNNING]${NC}"
        else
            print_and_log " - $app: ${RED}[STOPPED/FAILED]${NC}"
            ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- App Discovery:${NC} Custom service '$app' is not running\n"
        fi
    done
else
    print_and_log " - No manual custom .service files found."
fi

# 10.5 Docker Containers
print_and_log "${CYAN}>> Docker Containers:${NC}"
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$DOCKER_COUNT" -gt 0 ]; then
        print_and_log " - Found $DOCKER_COUNT running container(s):"
        docker ps --format "   - {{.Names}} ({{.Image}})" | while read -r line; do print_and_log "$line"; done
    else
        print_and_log " - Docker is running, but 0 active containers."
    fi
else
    print_and_log " - Docker not active or not installed."
fi

# ==========================================
# 11. Advanced Security Audit
# ==========================================
print_and_log "\n${YELLOW}[11] Advanced Security Audit:${NC}"

# 11.1 Interactive Users & Admins
print_and_log "${CYAN}>> Interactive Users:${NC}"
awk -F: '($3>=1000 || $1=="root") && $7 !~ /(nologin|false)$/ {print " - " $1}' /etc/passwd | while read -r line; do print_and_log "$line"; done

# 11.2 SSH Key Audit
print_and_log "${CYAN}>> SSH Key Audit (root):${NC}"
if [ -f /root/.ssh/authorized_keys ]; then
    KEY_COUNT=$(wc -l < /root/.ssh/authorized_keys)
    print_and_log " - Found $KEY_COUNT authorized keys for root."
    awk '{print "   * Key identifier: " $3}' /root/.ssh/authorized_keys | while read -r line; do print_and_log "$line"; done
else
    print_and_log " - ${GREEN}[OK] No authorized_keys found for root.${NC}"
fi

# 11.3 Failed Login Attempts
print_and_log "${CYAN}>> Failed Login Attempts (Brute Force Check):${NC}"
if [ -f "$AUTH_LOG" ]; then
    FAILED_COUNT=$(grep -c "Failed password" "$AUTH_LOG" 2>/dev/null || echo "0")
    if [ "$FAILED_COUNT" -gt 50 ]; then
        print_and_log " - ${RED}[WARNING] High number of failed logins detected: $FAILED_COUNT attempts!${NC}"
        print_and_log "   -> Top targeted accounts:"
        grep "Failed password" "$AUTH_LOG" | awk '{if (match($0,"invalid user")) print $11; else print $9}' | sort | uniq -c | sort -nr | head -n 3 | while read -r line; do print_and_log "      $line"; done
        ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Security:${NC} $FAILED_COUNT failed SSH logins detected\n"
    else
        print_and_log " - ${GREEN}[OK] Normal login behavior ($FAILED_COUNT failed attempts).${NC}"
    fi
else
    print_and_log " - ${YELLOW}[SKIP] Log file $AUTH_LOG not found.${NC}"
fi

# 11.4 Lightweight Rootkit / Suspicious File Scanner
print_and_log "${CYAN}>> Suspicious Activity / Rootkit Scan:${NC}"
SUSPICIOUS_TMP=$(find /tmp /var/tmp /dev/shm -maxdepth 1 -type f -exec ls -ld {} + 2>/dev/null | grep -E "\.(sh|elf|bin|py|pl|php)$" || true)

if [ -n "$SUSPICIOUS_TMP" ]; then
    print_and_log " - ${RED}[WARNING] Found suspicious executable scripts/files in temporary directories:${NC}"
    print_and_log "$SUSPICIOUS_TMP"
    ((TOTAL_WARNINGS++)); SUMMARY_MSG+="${YELLOW}- Security:${NC} Suspicious files found in /tmp\n"
else
    print_and_log " - ${GREEN}[OK] No suspicious executable files found in /tmp, /var/tmp, or /dev/shm.${NC}"
fi

if command -v rkhunter >/dev/null 2>&1; then
    print_and_log "   -> Notice: rkhunter is installed. (Run 'rkhunter --check' manually for deep scan)"
elif command -v chkrootkit >/dev/null 2>&1; then
    print_and_log "   -> Notice: chkrootkit is installed. (Run 'chkrootkit' manually for deep scan)"
fi

# ==========================================
# EXECUTIVE SUMMARY
# ==========================================
print_and_log "\n${CYAN}====================================================${NC}"
print_and_log "${CYAN}                 EXECUTIVE SUMMARY                  ${NC}"
print_and_log "${CYAN}====================================================${NC}"

if [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -eq 0 ]; then
    print_and_log "${GREEN}[PASS] All critical systems and applications are healthy!${NC}"
    print_and_log "The server is fully updated, secure, and running perfectly."
elif [ $TOTAL_ERRORS -eq 0 ] && [ $TOTAL_WARNINGS -gt 0 ]; then
    print_and_log "${YELLOW}[WARNING] Systems are functioning, but needs attention. ($TOTAL_WARNINGS warnings)${NC}"
    print_and_log "Please review the following notices:"
    print_and_log -n "$SUMMARY_MSG"
else
    print_and_log "${RED}[FAIL] Health check found $TOTAL_ERRORS critical issue(s) and $TOTAL_WARNINGS warning(s).${NC}"
    print_and_log "Please review the following errors immediately:"
    print_and_log -n "$SUMMARY_MSG"
fi

print_and_log "\n${CYAN}>> Report saved to: ${LOG_FILE}${NC}"
print_and_log "${CYAN}====================================================${NC}\n"
