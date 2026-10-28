#!/bin/sh
# Настройка TL-WR840N v6 (OpenWrt 19.07 + WireGuard) для объекта с камерами.
#
# Схема: кабель провайдера в WAN-порт, в нём два VLAN тегами:
#   PPPOE_VLAN — интернет по PPPoE с белым статическим IP;
#   CAM_VLAN   — сеть камер, роутер в ней получает адрес CAM_IP.
# На роутере работает сервер WireGuard: телефон или ноутбук подключаются
# к белому IP и попадают в сеть камер. LAN-порты — для ноутбука монтажника.
#
# Как применить: прошить роутер, подключиться кабелем в LAN-порт,
# зайти ssh root@192.168.1.1, вставить весь текст и нажать Enter.
# Повторный запуск безопасен: ключи WireGuard сохраняются.

ROOT_PASSWORD=''             # пусто = придумаю сам и покажу в конце
PPPOE_VLAN='105'
PPPOE_USER=''
PPPOE_PASS=''
CAM_VLAN='108'
CAM_IP=''                    # адрес роутера в сети камер
CAM_MASK=''
WG_PORT='51820'
WG_NET='10.8.0'              # туннель: роутер .1, клиенты .2, .3 ...
WG_CLIENTS='phone laptop'    # клиенты WireGuard через пробел, у каждого свой ключ
PUBLIC_IP=''                 # белый IP, если известен; пусто = узнать по PPPoE
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
		if [ "$v" -lt 3 ] || [ "$v" -gt 4094 ]; then echo "VLAN $v вне диапазона 3–4094."; return 1; fi
	done
	if [ -n "$WIFI_SSID" ] && [ "${#WIFI_KEY}" -lt 8 ]; then echo "WIFI_KEY должен быть не короче 8 символов."; return 1; fi
	NETWORK=''
	PREFIX=''
	eval "$(ipcalc.sh "$CAM_IP" "$CAM_MASK")"
	if [ -z "$NETWORK" ] || [ -z "$PREFIX" ]; then echo "Проверьте CAM_IP и CAM_MASK."; return 1; fi
	CAM_NET="$NETWORK/$PREFIX"

	# --- пароль root ---
	pw_note=''
	if [ -z "$ROOT_PASSWORD" ]; then
		ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
		pw_note="Пароль root (сохраните!): $ROOT_PASSWORD"
	fi
	printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root >/dev/null 2>&1 ||
		echo "Пароль root сменить не удалось — после скрипта выполните: passwd"

	# --- ключи WireGuard хранятся на роутере и при повторном запуске не меняются ---
	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard
	[ -s /etc/wireguard/server.key ] || wg genkey > /etc/wireguard/server.key

	# --- коммутатор: LAN-порты без тегов, в WAN-порт только тегированные VLAN ---
	sw="$(uci -X show network | sed -n 's/^network\.\([^.=]*\)=switch$/\1/p' | head -n 1)"
	[ -n "$sw" ] || { echo "Не найден коммутатор switch0 в /etc/config/network."; return 1; }
	uci set "network.$sw.enable_vlan=1"
	for s in $(uci -X show network | sed -n 's/^network\.\([^.=]*\)=switch_vlan$/\1/p'); do
		uci delete "network.$s"
	done
	idx=1
	for spec in "1:1 2 3 4 6t" "$PPPOE_VLAN:0t 6t" "$CAM_VLAN:0t 6t"; do
		s="$(uci add network switch_vlan)"
		uci set "network.$s.device=switch0"
		uci set "network.$s.vlan=$idx"
		uci set "network.$s.vid=${spec%%:*}"
		uci set "network.$s.ports=${spec#*:}"
		idx=$((idx + 1))
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
		[ -s "/etc/wireguard/$c.key" ] || wg genkey > "/etc/wireguard/$c.key"
		[ -s "/etc/wireguard/$c.psk" ] || wg genpsk > "/etc/wireguard/$c.psk"
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
PUBLIC_IP='$PUBLIC_IP'
EOF

	# --- firewall ---
	wanzone="$(zone_by_name wan)" && {
		uci -q del_list "firewall.$wanzone.network=wan6"
	}
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

	# --- помощник: конфиги и QR-коды для клиентов ---
	cat > /root/wg-show.sh <<'SHOW_EOF'
#!/bin/sh
# Конфиги и QR-коды WireGuard для клиентов. Запуск: sh /root/wg-show.sh
. /etc/wireguard/site.conf
ip="$PUBLIC_IP"
i=0
while [ -z "$ip" ] && [ "$i" -lt 60 ]; do
	ip="$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
	[ -n "$ip" ] && break
	[ "$i" = 0 ] && echo "Жду подключения PPPoE (до минуты)..."
	i=$((i + 1))
	sleep 1
done
if [ -z "$ip" ]; then
	echo "PPPoE не подключился. Проверьте кабель, VLAN, логин и пароль: logread | grep pppd"
	ip="БЕЛЫЙ_IP_РОУТЕРА"
fi
case "$ip" in
	10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
		echo "ВНИМАНИЕ: PPPoE выдал серый адрес $ip — снаружи к роутеру не подключиться."
		;;
esac
server_pub="$(wg pubkey < /etc/wireguard/server.key)"
while read -r name n; do
	conf="/root/wg-$name.conf"
	cat > "$conf" <<CONF
[Interface]
PrivateKey = $(cat "/etc/wireguard/$name.key")
Address = $WG_NET.$n/32

[Peer]
PublicKey = $server_pub
PresharedKey = $(cat "/etc/wireguard/$name.psk")
Endpoint = $ip:$WG_PORT
AllowedIPs = $WG_NET.0/24, $CAM_NET
PersistentKeepalive = 25
CONF
	echo
	echo "===== $name ($conf) ====="
	cat "$conf"
	if command -v qrencode >/dev/null; then qrencode -t ansiutf8 < "$conf"; fi
done < /etc/wireguard/clients
SHOW_EOF
	chmod 700 /root/wg-show.sh

	echo
	echo "Готово. Применяю настройки сети — связь по SSH может на пару секунд пропасть."
	if [ -n "$pw_note" ]; then echo "$pw_note"; fi
	echo "Сеть камер: $CAM_NET, адрес роутера в ней: $CAM_IP"
	echo "Через минуту выполните: sh /root/wg-show.sh"
	echo "Он покажет QR-коды для приложения WireGuard на телефоне и конфиги для ноутбука."
	if [ "$LAN_IP" != 192.168.1.1 ]; then echo "Адрес роутера в LAN меняется на $LAN_IP — переподключитесь к нему."; fi

	(sleep 2; /etc/init.d/network reload; /etc/init.d/firewall reload; wifi up) >/dev/null 2>&1 &
}
site_setup
