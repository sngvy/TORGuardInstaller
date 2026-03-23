#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

# Проверка на запуск от root
if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Пожалуйста, запустите скрипт от имени root (sudo).${NC}"
    exit 1
fi

echo -e "${B_CYAN}Установка защиты от TOR узлов (RAW Table + ipset)...${NC}"

# 1. Зависимости (добавлен jq)
echo -e "${B_YELLOW}Установка компонентов (ipset, curl, jq, iptables-persistent)...${NC}"
apt-get update -qq && apt-get install -y ipset curl jq iptables-persistent -qq

# 2. Создание скрипта обновления
S="/usr/local/bin/update-tor-list.sh"
cat << 'EOF' > "$S"
#!/bin/bash
N="tor_ips"
# Официальный API Tor Project (Onionoo)
U="https://onionoo.torproject.org/summary?running=true"

# Создаем основной сет, если его нет (hash:ip для одиночных адресов)
ipset create -! "$N" hash:ip maxelem 100000

T1=$(mktemp)
T2=$(mktemp)

# Загружаем список через jq (берем первый адрес из массива 'a')
if curl -sSL "$U" | jq -r '.relays[].a[0]' > "$T1"; then
    echo "create ${N}_new hash:ip maxelem 100000 -!" > "$T2"
    sed "s/^/add ${N}_new /" "$T1" >> "$T2"
    
    ipset restore < "$T2"
    ipset swap "$N" "${N}_new"
    ipset destroy "${N}_new"
    
    E=$(ipset list "$N" | grep 'Number of entries' | cut -d: -f2 | xargs)
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] Blocked Tor IPs: $E"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to download or parse Tor list"
fi
rm -f "$T1" "$T2"
EOF

chmod +x "$S"

# 3. Первый запуск синхронизации
echo -e "${B_YELLOW}Синхронизация со списками Onionoo API...${NC}"
"$S"

# 4. Настройка Firewall (Таблица RAW)
echo -e "${B_YELLOW}Настройка правил iptables в режиме RAW PREROUTING...${NC}"

# Чистим старые правила для этого сета
iptables -t raw -D PREROUTING -m set --match-set tor_ips src -j DROP 2>/dev/null

# Устанавливаем блокировку в таблицу RAW (пакеты дропаются до conntrack)
iptables -t raw -I PREROUTING -m set --match-set tor_ips src -j DROP

# Сохраняем правила
if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save > /dev/null 2>&1
fi

# 5. Настройка Cron (обновление каждые 4 часа, так как Tor консенсус меняется часто)
echo -e "${B_YELLOW}Добавление задачи в планировщик cron...${NC}"
C_JOB="0 */4 * * * $S >> /var/log/tor_block_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

echo -e "---"
echo -e "${B_GREEN}Установка успешно завершена!${NC}"
echo -e "${BOLD}Тип блокировки:${NC} ${B_CYAN}RAW Table (Нулевая нагрузка на CPU)${NC}"
echo -e "${BOLD}Лог обновлений:${NC} ${B_YELLOW}/var/log/tor_block_update.log${NC}"
echo -e "${BOLD}Статус в iptables:${NC}"
iptables -t raw -L PREROUTING -v -n | grep tor_ips