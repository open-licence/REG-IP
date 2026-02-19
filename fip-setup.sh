#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода разделителя
print_line() {
    echo "=================================================="
}

# Заголовок
clear
print_line
echo -e "${BLUE}    НАСТРОЙКА ПЛАВАЮЩИХ IP-АДРЕСОВ${NC}"
print_line
echo ""

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Скрипт должен запускаться от root${NC}" 
   exit 1
fi

# Показать текущие интерфейсы
echo -e "${YELLOW}Текущие сетевые интерфейсы:${NC}"
ip -br a | grep -v lo | column -t
print_line
echo ""

# Функция для получения шлюза по IP
get_gateway() {
    local ip=$1
    # Извлекаем первые три октета (например, из 192.168.0.85 -> 192.168.0)
    local network=$(echo $ip | cut -d. -f1-3)
    echo "${network}.1"
}

# Функция для проверки доступности таблицы
check_table() {
    local table=$1
    if ip rule list | awk '{print $NF}' | grep -q "^$table$"; then
        return 1
    else
        return 0
    fi
}

# Функция для проверки пинга
test_ip() {
    local ip=$1
    echo -e "${YELLOW}Проверка связи с IP $ip...${NC}"
    if ping -I $ip -c 2 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓ IP $ip успешно пингуется${NC}"
        return 0
    else
        echo -e "${RED}✗ IP $ip НЕ пингуется${NC}"
        return 1
    fi
}

# Основное меню
while true; do
    echo -e "${BLUE}Выберите действие:${NC}"
    echo "1) Настроить новый плавающий IP"
    echo "2) Показать текущие правила"
    echo "3) Удалить правило для IP"
    echo "4) Проверить работу IP"
    echo "5) Сохранить настройки в systemd"
    echo "6) Выход"
    echo ""
    read -p "Ваш выбор (1-6): " choice
    echo ""

    case $choice in
        1)
            echo -e "${YELLOW}Настройка нового плавающего IP${NC}"
            
            # Показываем доступные интерфейсы
            echo "Доступные интерфейсы:"
            interfaces=($(ip -br a | grep -v lo | awk '{print $1}'))
            for i in "${!interfaces[@]}"; do
                ips=$(ip -br a show ${interfaces[$i]} | awk '{print $3}' | cut -d/ -f1)
                echo "$((i+1))) ${interfaces[$i]} - IP: $ips"
            done
            
            # Выбор интерфейса
            read -p "Выберите номер интерфейса: " iface_num
            iface=${interfaces[$((iface_num-1))]}
            
            # Получаем IP интерфейса
            ip_addr=$(ip -br a show $iface | awk '{print $3}' | cut -d/ -f1)
            
            echo -e "Выбран интерфейс: ${GREEN}$iface${NC}"
            echo -e "Его IP адрес: ${GREEN}$ip_addr${NC}"
            
            # Определяем шлюз
            gateway=$(get_gateway $ip_addr)
            echo -e "Шлюз подсети: ${GREEN}$gateway${NC}"
            
            # Поиск свободной таблицы
            table=1
            while ! check_table $table; do
                table=$((table + 1))
                if [[ $table -gt 252 ]]; then
                    echo -e "${RED}Ошибка: нет свободных таблиц маршрутизации (1-252 заняты)${NC}"
                    break 2
                fi
            done
            echo -e "Свободная таблица: ${GREEN}$table${NC}"
            
            # Подтверждение
            echo ""
            echo -e "${YELLOW}Будут выполнены команды:${NC}"
            echo "ip rule add from $ip_addr table $table prio $table"
            echo "ip route add default via $gateway dev $iface table $table"
            echo ""
            read -p "Продолжить? (y/n): " confirm
            
            if [[ $confirm == "y" ]]; then
                # Добавляем правила
                ip rule add from $ip_addr table $table prio $table
                ip route add default via $gateway dev $iface table $table
                
                # Проверяем результат
                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}✓ Правила успешно добавлены${NC}"
                    
                    # Тестируем
                    test_ip $ip_addr
                    
                    # Сохраняем в конфиг для systemd
                    echo "# $iface - $ip_addr" >> /etc/fip-rules.conf
                    echo "ip rule add from $ip_addr table $table prio $table" >> /etc/fip-rules.conf
                    echo "ip route add default via $gateway dev $iface table $table" >> /etc/fip-rules.conf
                    echo "" >> /etc/fip-rules.conf
                else
                    echo -e "${RED}✗ Ошибка при добавлении правил${NC}"
                fi
            fi
            ;;
            
        2)
            echo -e "${YELLOW}Текущие правила маршрутизации:${NC}"
            print_line
            ip rule list
            echo ""
            echo -e "${YELLOW}Таблицы маршрутизации:${NC}"
            for table in $(ip rule list | awk '{print $NF}' | egrep -v 'default|local|main' | sort -u); do
                echo "Таблица $table:"
                ip route show table $table 2>/dev/null || echo "   нет маршрутов"
            done
            print_line
            ;;
            
        3)
            echo -e "${YELLOW}Удаление правила для IP${NC}"
            echo "Текущие правила:"
            ip rule list | grep -v "local\|main\|default"
            echo ""
            read -p "Введите IP для удаления: " del_ip
            
            # Находим таблицу для этого IP
            table=$(ip rule list | grep $del_ip | awk '{print $NF}')
            if [[ -n $table ]]; then
                ip rule del from $del_ip
                ip route flush table $table
                echo -e "${GREEN}✓ Правила для $del_ip удалены${NC}"
                
                # Удаляем из конфига
                sed -i "/$del_ip/d" /etc/fip-rules.conf 2>/dev/null
            else
                echo -e "${RED}✗ Правила для IP $del_ip не найдены${NC}"
            fi
            ;;
            
        4)
            echo -e "${YELLOW}Проверка плавающих IP${NC}"
            echo "Текущие правила:"
            ip rule list | grep -v "local\|main\|default"
            echo ""
            read -p "Введите IP для проверки (Enter - проверить все): " test_ip_addr
            
            if [[ -z $test_ip_addr ]]; then
                # Проверяем все IP из правил
                for ip in $(ip rule list | grep -v "local\|main\|default" | awk '{print $2}' | cut -d: -f2); do
                    test_ip $ip
                done
            else
                test_ip $test_ip_addr
            fi
            ;;
            
        5)
            echo -e "${YELLOW}Сохранение настроек в systemd${NC}"
            
            # Создаем скрипт для загрузки
            cat > /etc/network-fip-rules.sh << 'EOF'
#!/bin/bash
sleep 10
if [[ -f /etc/fip-rules.conf ]]; then
    while IFS= read -r line; do
        if [[ ! $line =~ ^# ]] && [[ ! -z $line ]]; then
            eval $line 2>/dev/null
        fi
    done < /etc/fip-rules.conf
fi
EOF
            chmod 755 /etc/network-fip-rules.sh
            
            # Создаем systemd сервис
            cat > /etc/systemd/system/fip-routing.service << EOF
[Unit]
Description=Floating IP routing rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/network-fip-rules.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

            systemctl daemon-reload
            systemctl enable fip-routing.service
            systemctl start fip-routing.service
            
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}✓ systemd сервис создан и запущен${NC}"
                systemctl status fip-routing.service --no-pager
            else
                echo -e "${RED}✗ Ошибка при создании сервиса${NC}"
            fi
            ;;
            
        6)
            echo -e "${GREEN}До свидания!${NC}"
            exit 0
            ;;
            
        *)
            echo -e "${RED}Неверный выбор. Попробуйте снова.${NC}"
            ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
    clear
done
