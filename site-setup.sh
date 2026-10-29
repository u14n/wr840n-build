#!/bin/sh
# Настройка TL-WR840N v6 (OpenWrt 19.07 + WireGuard) для объекта с камерами.
#
# Схема: кабель провайдера в WAN-порт, в нём два VLAN тегами:
#   PPPOE_VLAN — интернет по PPPoE с белым IP;
#   CAM_VLAN   — сеть камер, роутер в ней получает адрес CAM_IP.
# На роутере работает сервер WireGuard: телефон или ноутбук подключаются
# к белому IP и попадают в сеть камер. LAN-порты — для ноутбука монтажника.
#
# Как применить (роутер прошит, ноутбук в LAN-порту, IP по DHCP):
#   Windows: положите рядом nastroit.cmd и запустите его двойным щелчком.
#   Вручную: ssh root@192.168.1.1, вставьте весь текст, Enter. Роутер
#            перезагрузится; через 2 минуты: ssh root@192.168.1.1 sh /root/site-check.sh
# site-check.sh проверяет интернет и камеры, выводит конфиги WireGuard
# и в конце задаёт пароль root. Повторный запуск безопасен: ключи сохраняются.

ROOT_PASSWORD=''             # пусто = случайный; его покажет site-check.sh
PPPOE_VLAN='105'
PPPOE_USER=''
PPPOE_PASS=''
CAM_VLAN='108'
CAM_IP=''                    # адрес роутера в сети камер
CAM_MASK=''
WG_PORT='51820'
WG_NET='10.8.0'              # туннель: роутер .1, клиенты .2, .3 ...
WG_CLIENTS='phone laptop'    # клиенты WireGuard через пробел, у каждого свой ключ
PUBLIC_IP=''                 # белый IP, если известен; пусто = взять у PPPoE
LAN_IP='192.168.1.1'         # адрес роутера на LAN-портах
WIFI_SSID=''                 # пусто = Wi-Fi не трогать (после прошивки он выключен)
WIFI_KEY=''                  # пароль Wi-Fi, от 8 символов
WIFI_COUNTRY=''              # код страны для Wi-Fi, напр. KG

zone_by_name() {
	for z in $(uci -X show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		if [ "$(uci -q get "firewall.$z.name")" = "$1" ]; then echo "$z"; return 0; fi
	done
	return 1
}

site_setup() {
	command -v wg >/dev/null || { echo "Нет WireGuard в прошивке — прошейте сборку с WireGuard."; return 1; }
	command -v pppd >/dev/null || { echo "Нет PPPoE в прошивке — прошейте сборку с PPPoE."; return 1; }
	if [ -z "$PPPOE_USER" ] || [ -z "$PPPOE_PASS" ]; then echo "Заполните PPPOE_USER и PPPOE_PASS."; return 1; fi
	if [ -z "$CAM_IP" ] || [ -z "$CAM_MASK" ]; then echo "Заполните CAM_IP и CAM_MASK."; return 1; fi
	for v in "$PPPOE_VLAN" "$CAM_VLAN"; do
		case "$v" in ''|*[!0-9]*) echo "VLAN должен быть числом: '$v'"; return 1 ;; esac
		if [ "$v" -lt 2 ] || [ "$v" -gt 4094 ]; then echo "VLAN $v вне диапазона 2–4094 (1 занят под LAN)."; return 1; fi
	done
	if [ "$PPPOE_VLAN" = "$CAM_VLAN" ]; then echo "PPPOE_VLAN и CAM_VLAN должны различаться."; return 1; fi
	[ -n "$WG_CLIENTS" ] || { echo "Укажите хотя бы одного клиента в WG_CLIENTS."; return 1; }
	for c in $WG_CLIENTS; do
		case "$c" in *[!A-Za-z0-9_-]*) echo "Имя клиента WireGuard — латиница и цифры: '$c'"; return 1 ;; esac
	done
	if [ -n "$WIFI_SSID" ] && [ "${#WIFI_KEY}" -lt 8 ]; then echo "WIFI_KEY должен быть не короче 8 символов."; return 1; fi
	NETWORK=''
	PREFIX=''
	eval "$(ipcalc.sh "$CAM_IP" "$CAM_MASK")"
	if [ -z "$NETWORK" ] || [ -z "$PREFIX" ]; then echo "Проверьте CAM_IP и CAM_MASK."; return 1; fi
	CAM_NET="$NETWORK/$PREFIX"
	if [ "$PREFIX" -ge 24 ]; then
		CAM_SCAN="${NETWORK%.*} $((${NETWORK##*.} + 1)) $((${BROADCAST##*.} - 1))"
	else
		CAM_SCAN="${CAM_IP%.*} 1 254"
	fi

	# --- ключи и пароль хранятся на роутере; ключи при повторном запуске не меняются ---
	if [ -z "$ROOT_PASSWORD" ]; then
		ROOT_PASSWORD="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12)"
	fi
	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard
	[ -s /etc/wireguard/server.key ] || (umask 077; wg genkey > /etc/wireguard/server.key)
	(umask 077; printf '%s\n' "$ROOT_PASSWORD" > /etc/wireguard/.rootpw)

	# --- коммутатор: LAN-порты 1–4 без тегов, в WAN-порт 0 только тегированные VLAN ---
	# У коммутатора MT7628 номер vlan в конфиге и есть VLAN ID (опции vid у него нет).
	sw="$(uci -X show network | sed -n 's/^network\.\([^.=]*\)=switch$/\1/p' | head -n 1)"
	[ -n "$sw" ] || { echo "Не найден коммутатор switch0 в /etc/config/network."; return 1; }
	uci set "network.$sw.enable_vlan=1"
	for s in $(uci -X show network | sed -n 's/^network\.\([^.=]*\)=switch_vlan$/\1/p'); do
		uci delete "network.$s"
	done
	for spec in "1:1 2 3 4 6t" "$PPPOE_VLAN:0t 6t" "$CAM_VLAN:0t 6t"; do
		s="$(uci add network switch_vlan)"
		uci set "network.$s.device=switch0"
		uci set "network.$s.vlan=${spec%%:*}"
		uci set "network.$s.ports=${spec#*:}"
	done

	# --- интерфейсы ---
	uci set network.lan.ifname=eth0.1
	uci set network.lan.ipaddr="$LAN_IP"
	uci -q delete network.wan6
	uci -q delete network.wan
	uci set network.wan=interface
	uci set network.wan.ifname="eth0.$PPPOE_VLAN"
	uci set network.wan.proto=pppoe
	uci set network.wan.username="$PPPOE_USER"
	uci set network.wan.password="$PPPOE_PASS"
	uci set network.wan.ipv6=0
	for d in $(uci -X show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
		if [ "$(uci -q get "network.$d.name")" = eth0.2 ]; then uci set "network.$d.name=eth0.$PPPOE_VLAN"; fi
	done
	uci -q delete network.cam
	uci set network.cam=interface
	uci set network.cam.ifname="eth0.$CAM_VLAN"
	uci set network.cam.proto=static
	uci set network.cam.ipaddr="$CAM_IP"
	uci set network.cam.netmask="$CAM_MASK"
	uci -q delete dhcp.cam
	uci set dhcp.cam=dhcp
	uci set dhcp.cam.interface=cam
	uci set dhcp.cam.ignore=1

	# --- WireGuard-сервер и клиенты ---
	uci -q delete network.wg0
	while uci -q delete "network.@wireguard_wg0[0]"; do :; done
	uci set network.wg0=interface
	uci set network.wg0.proto=wireguard
	uci set network.wg0.private_key="$(cat /etc/wireguard/server.key)"
	uci set network.wg0.listen_port="$WG_PORT"
	uci add_list network.wg0.addresses="$WG_NET.1/24"
	: > /etc/wireguard/clients
	n=2
	for c in $WG_CLIENTS; do
		[ -s "/etc/wireguard/$c.key" ] || (umask 077; wg genkey > "/etc/wireguard/$c.key")
		[ -s "/etc/wireguard/$c.psk" ] || (umask 077; wg genpsk > "/etc/wireguard/$c.psk")
		p="$(uci add network wireguard_wg0)"
		uci set "network.$p.description=$c"
		uci set "network.$p.public_key=$(wg pubkey < "/etc/wireguard/$c.key")"
		uci set "network.$p.preshared_key=$(cat "/etc/wireguard/$c.psk")"
		uci add_list "network.$p.allowed_ips=$WG_NET.$n/32"
		echo "$c $n" >> /etc/wireguard/clients
		n=$((n + 1))
	done
	cat > /etc/wireguard/site.conf <<EOF
WG_PORT='$WG_PORT'
WG_NET='$WG_NET'
CAM_NET='$CAM_NET'
CAM_IP='$CAM_IP'
CAM_VLAN='$CAM_VLAN'
CAM_SCAN='$CAM_SCAN'
PUBLIC_IP='$PUBLIC_IP'
EOF

	# --- firewall ---
	wanzone="$(zone_by_name wan)" && uci -q del_list "firewall.$wanzone.network=wan6"
	uci -q delete firewall.cam
	uci set firewall.cam=zone
	uci set firewall.cam.name=cam
	uci set firewall.cam.input=REJECT
	uci set firewall.cam.output=ACCEPT
	uci set firewall.cam.forward=REJECT
	uci set firewall.cam.masq=1
	uci add_list firewall.cam.network=cam
	uci -q delete firewall.vpn
	uci set firewall.vpn=zone
	uci set firewall.vpn.name=vpn
	uci set firewall.vpn.input=ACCEPT
	uci set firewall.vpn.output=ACCEPT
	uci set firewall.vpn.forward=REJECT
	uci set firewall.vpn.mtu_fix=1
	uci add_list firewall.vpn.network=wg0
	for f in vpn:cam vpn:lan lan:cam; do
		name="$(echo "$f" | tr ':' '_')"
		uci -q delete "firewall.$name"
		uci set "firewall.$name=forwarding"
		uci set "firewall.$name.src=${f%%:*}"
		uci set "firewall.$name.dest=${f#*:}"
	done
	uci -q delete firewall.wg_in
	uci set firewall.wg_in=rule
	uci set firewall.wg_in.name=Allow-WireGuard
	uci set firewall.wg_in.src=wan
	uci set firewall.wg_in.proto=udp
	uci set firewall.wg_in.dest_port="$WG_PORT"
	uci set firewall.wg_in.target=ACCEPT

	# --- Wi-Fi только с паролем ---
	if [ -n "$WIFI_SSID" ]; then
		uci set "wireless.@wifi-device[0].disabled=0"
		if [ -n "$WIFI_COUNTRY" ]; then uci set "wireless.@wifi-device[0].country=$WIFI_COUNTRY"; fi
		uci set "wireless.@wifi-iface[0].disabled=0"
		uci set "wireless.@wifi-iface[0].ssid=$WIFI_SSID"
		uci set "wireless.@wifi-iface[0].encryption=psk2"
		uci set "wireless.@wifi-iface[0].key=$WIFI_KEY"
	fi

	uci commit

	# --- проверка после перезагрузки: интернет, камеры, конфиги WireGuard, пароль root ---
	cat > /root/site-check.sh <<'CHECK_EOF'
#!/bin/sh
# Проверка объекта и конфиги WireGuard. Запуск: sh /root/site-check.sh
umask 077
. /etc/wireguard/site.conf

echo "== Интернет (PPPoE) =="
ip=''
i=0
while [ "$i" -lt 90 ]; do
	ip="$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
	[ -n "$ip" ] && break
	[ "$i" = 0 ] && echo "Жду подключения PPPoE (до 1,5 минуты)..."
	i=$((i + 1))
	sleep 1
done
if [ -n "$ip" ]; then
	echo "PPPoE: подключено, IP $ip"
	if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then echo "Интернет: работает"; else echo "Интернет: ping 8.8.8.8 не проходит"; fi
	case "$ip" in
		10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
			echo "ВНИМАНИЕ: PPPoE выдал серый адрес $ip — снаружи к роутеру не подключиться."
			;;
	esac
else
	echo "PPPoE: НЕ подключилось. Последние сообщения:"
	logread 2>/dev/null | grep -i -e pppd -e pppoe | tail -n 8
fi

echo
echo "== Сеть камер (VLAN $CAM_VLAN, $CAM_NET) =="
if ifstatus cam 2>/dev/null | grep -q '"up": true'; then
	echo "Роутер в сети камер: $CAM_IP"
else
	echo "Интерфейс сети камер не поднят"
fi
set -- $CAM_SCAN
base=$1
first=$2
last=$3
rm -rf /tmp/camscan
mkdir -p /tmp/camscan
n=$first
k=0
while [ "$n" -le "$last" ]; do
	if [ "$base.$n" != "$CAM_IP" ]; then
		(ping -c 1 -W 1 "$base.$n" >/dev/null 2>&1 && touch "/tmp/camscan/$n") &
		k=$((k + 1))
		if [ "$k" -ge 32 ]; then wait; k=0; fi
	fi
	n=$((n + 1))
done
wait
found=0
n=$first
while [ "$n" -le "$last" ]; do
	if [ -e "/tmp/camscan/$n" ]; then
		mac="$(awk -v ip="$base.$n" '$1 == ip { print $4 }' /proc/net/arp)"
		echo "  отвечает: $base.$n  $mac"
		found=$((found + 1))
	fi
	n=$((n + 1))
done
rm -rf /tmp/camscan
if [ "$found" = 0 ]; then echo "  на ping никто не ответил (проверьте кабель и VLAN; некоторые камеры не отвечают на ping)"; fi

echo
echo "== WireGuard =="
port="$(wg show wg0 listen-port 2>/dev/null)"
if [ -n "$port" ]; then echo "Сервер WireGuard работает, порт $port/udp"; else echo "Сервер WireGuard НЕ запущен"; fi
ep="${PUBLIC_IP:-$ip}"
[ -n "$ep" ] || ep="БЕЛЫЙ_IP_РОУТЕРА"
server_pub="$(wg pubkey < /etc/wireguard/server.key)"
while read -r name num; do
	conf="/root/wg-$name.conf"
	cat > "$conf" <<CONF
[Interface]
PrivateKey = $(cat "/etc/wireguard/$name.key")
Address = $WG_NET.$num/32

[Peer]
PublicKey = $server_pub
PresharedKey = $(cat "/etc/wireguard/$name.psk")
Endpoint = $ep:$WG_PORT
AllowedIPs = $WG_NET.0/24, $CAM_NET
PersistentKeepalive = 25
CONF
	echo
	echo "----- BEGIN wg-$name.conf -----"
	cat "$conf"
	echo "----- END wg-$name.conf -----"
	if [ -t 1 ] && command -v qrencode >/dev/null; then qrencode -t ansiutf8 < "$conf"; fi
done < /etc/wireguard/clients

echo
if [ -s /etc/wireguard/.rootpw ]; then
	pw="$(cat /etc/wireguard/.rootpw)"
	if printf '%s\n%s\n' "$pw" "$pw" | passwd root >/dev/null 2>&1; then
		rm -f /etc/wireguard/.rootpw
		echo "Пароль root (сохраните!): $pw"
	else
		echo "Пароль root задать не удалось — выполните: passwd"
	fi
fi
echo "CHECK_DONE"
CHECK_EOF
	chmod 700 /root/site-check.sh

	# --- перезагрузка, когда раздел для настроек готов (на первой загрузке он ещё форматируется) ---
	i=0
	while ! grep -q ' /overlay jffs2 ' /proc/mounts; do
		if [ "$i" = 0 ]; then echo "Жду, пока подготовится раздел для настроек (обычно до минуты)..."; fi
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			echo "Раздел для настроек так и не подготовился — после перезагрузки настройки пропадут. Роутер не перезагружаю."
			return 1
		fi
		sleep 5
	done
	echo
	echo "Настройки записаны. Роутер перезагружается — это 1–2 минуты."
	echo "После загрузки проверка: ssh root@$LAN_IP sh /root/site-check.sh"
	echo "SETUP_OK"
	(sleep 3; reboot) >/dev/null 2>&1 &
	return 0
}
site_setup
