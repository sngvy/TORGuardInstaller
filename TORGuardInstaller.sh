#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}Конфигурация TORGuard${NC}"
echo -e "Выберите метод интеграции:"
echo -e "1) UFW (через before.rules + RAW Table)"
echo -e "2) iptables (прямая таблица RAW)"
read -p "Ваш выбор [1-2]: " FW_CHOICE

case $FW_CHOICE in
    1) 
        MODE="ufw"
        if ! command -v ufw >/dev/null; then
            echo -e "${B_YELLOW}Установка UFW...${NC}"
            apt-get update -qq && apt-get install -y ufw -qq
        fi
        ;;
    2) 
        MODE="iptables" 
        ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

# Установка зависимостей
apt-get update -qq && apt-get install -y ipset curl jq iptables-persistent -qq

S="/usr/local/bin/update-tor-list.sh"
cat << 'EOF' > "$S"
#!/bin/bash
N="tor_ips"
U="https://onionoo.torproject.org/summary?running=true"
ipset create -! "$N" hash:ip maxelem 100000
T1=$(mktemp)
T2=$(mktemp)
if curl -sSL "$U" | jq -r '.relays[].a[0]' 2>/dev/null > "$T1"; then
    echo "create ${N}_new hash:ip maxelem 100000 -!" > "$T2"
    sed "s/^/add ${N}_new /" "$T1" >> "$T2"
    ipset restore < "$T2"
    ipset swap "$N" "${N}_new"
    ipset destroy "${N}_new"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] Tor list updated"
fi
rm -f "$T1" "$T2"
EOF

chmod +x "$S"
$S

if [ "$MODE" = "ufw" ]; then
    if ! grep -q "tor_ips" /etc/ufw/before.rules; then
        sed -i "1i # TOR-Blocklist\n*raw\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -m set --match-set tor_ips src -j DROP\nCOMMIT\n" /etc/ufw/before.rules
        ufw reload
    fi
else
    iptables -t raw -I PREROUTING -m set --match-set tor_ips src -j DROP 2>/dev/null || iptables -t raw -I PREROUTING -m set --match-set tor_ips src -j DROP
    iptables-save > /etc/iptables/rules.v4
fi

C_JOB="0 */4 * * * $S >> /var/log/tor_block_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

read -p "Создать службу systemd для обновления при старте системы? [y/N]: " SYSTEMD_CHOICE
if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
    cat << EOF > /etc/systemd/system/tor-update.service
[Unit]
Description=Update TOR Guard List on Boot
After=network.target

[Service]
Type=oneshot
ExecStart=$S
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tor-update.service
    echo -e "${B_YELLOW}Служба systemd создана и включена.${NC}"
fi

echo -e "${B_GREEN}TORGuard успешно настроен через $MODE!${NC}"
