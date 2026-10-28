#!/bin/sh
# Настройка WireGuard на TL-WR840N v6 с OpenWrt 19.07 (сборка из этого набора).
#
# 1) Заполните поля ниже.
# 2) Подключитесь кабелем в LAN и зайдите: ssh root@192.168.1.1
# 3) Вставьте весь этот текст в окно SSH и нажмите Enter.
# В конце скрипт покажет публичный ключ роутера и готовый блок [Peer] для сервера.
# Повторный запуск безопасен: прежние настройки wg0 перезаписываются.

ROOT_PASSWORD=''             # пароль root — обязательно
WG_ADDR='10.8.0.2/24'        # адрес роутера внутри туннеля (свой на каждом объекте)
WG_PRIVKEY=''                # пусто = ключ сгенерируется на роутере
PEER_PUBKEY=''               # публичный ключ сервера WireGuard — обязательно
PEER_PSK=''                  # PresharedKey, если он есть на сервере
PEER_HOST=''                 # IP или домен сервера (обычный случай: роутер — клиент)
PEER_PORT='51820'            # порт сервера
PEER_ALLOWED='10.8.0.0/24'   # сети за туннелем через пробел, напр. '10.8.0.0/24 192.168.10.0/24'
WG_LISTEN_PORT=''            # только если у объекта белый IP и подключаются К роутеру
LAN_IP=''                    # новый IP роутера, напр. 192.168.51.1 (своя подсеть на объект)
LAN_MASQ='0'                 # 1 — если у камер/регистратора шлюз НЕ этот роутер
WIFI_SSID=''                 # пусто = Wi-Fi не трогать (после прошивки он выключен)
WIFI_KEY=''                  # пароль Wi-Fi, от 8 символов
WIFI_COUNTRY=''              # код страны для Wi-Fi, напр. KG

wg_setup() {
	command -v wg >/dev/null || { echo "Нет WireGuard в прошивке — прошейте сборку из этого набора."; return 1; }
	[ -n "$ROOT_PASSWORD" ] || { echo "Задайте ROOT_PASSWORD."; return 1; }
	[ "${#PEER_PUBKEY}" -eq 44 ] || { echo "PEER_PUBKEY должен быть ключом из 44 символов."; return 1; }
	case "$WG_ADDR" in */*) ;; *) echo "WG_ADDR нужен с маской, напр. 10.8.0.2/24."; return 1 ;; esac
	[ -n "$PEER_HOST" ] || [ -n "$WG_LISTEN_PORT" ] || {
		echo "Укажите PEER_HOST (адрес сервера) или WG_LISTEN_PORT (если роутер сам принимает подключения)."
		return 1
	}
	if [ -n "$WIFI_SSID" ] && [ "${#WIFI_KEY}" -lt 8 ]; then
		echo "WIFI_KEY должен быть не короче 8 символов."
		return 1
	fi

	if printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root >/dev/null 2>&1; then
		echo "Пароль root установлен."
	else
		echo "Пароль root сменить не удалось — после скрипта выполните: passwd"
	fi

	[ -n "$WG_PRIVKEY" ] || WG_PRIVKEY="$(wg genkey)"
	WG_PUBKEY="$(echo "$WG_PRIVKEY" | wg pubkey)" || { echo "Неверный WG_PRIVKEY."; return 1; }

	# --- интерфейс wg0 и сервер как peer ---
	uci -q delete network.wg0
	while uci -q delete "network.@wireguard_wg0[0]"; do :; done
	uci set network.wg0=interface
	uci set network.wg0.proto=wireguard
	uci set network.wg0.private_key="$WG_PRIVKEY"
	uci add_list network.wg0.addresses="$WG_ADDR"
	if [ -n "$WG_LISTEN_PORT" ]; then uci set network.wg0.listen_port="$WG_LISTEN_PORT"; fi

	peer="$(uci add network wireguard_wg0)"
	uci set "network.$peer.description=server"
	uci set "network.$peer.public_key=$PEER_PUBKEY"
	if [ -n "$PEER_PSK" ]; then uci set "network.$peer.preshared_key=$PEER_PSK"; fi
	for net in $PEER_ALLOWED; do uci add_list "network.$peer.allowed_ips=$net"; done
	uci set "network.$peer.route_allowed_ips=1"
	if [ -n "$PEER_HOST" ]; then
		uci set "network.$peer.endpoint_host=$PEER_HOST"
		uci set "network.$peer.endpoint_port=$PEER_PORT"
		uci set "network.$peer.persistent_keepalive=25"
	fi

	# --- зона firewall: из туннеля можно к роутеру и в LAN, из LAN — в туннель ---
	uci -q delete firewall.vpn
	uci set firewall.vpn=zone
	uci set firewall.vpn.name=vpn
	uci set firewall.vpn.input=ACCEPT
	uci set firewall.vpn.output=ACCEPT
	uci set firewall.vpn.forward=REJECT
	uci add_list firewall.vpn.network=wg0
	uci -q delete firewall.vpn_lan
	uci set firewall.vpn_lan=forwarding
	uci set firewall.vpn_lan.src=vpn
	uci set firewall.vpn_lan.dest=lan
	uci -q delete firewall.lan_vpn
	uci set firewall.lan_vpn=forwarding
	uci set firewall.lan_vpn.src=lan
	uci set firewall.lan_vpn.dest=vpn
	uci -q delete firewall.wg_in
	if [ -n "$WG_LISTEN_PORT" ]; then
		uci set firewall.wg_in=rule
		uci set firewall.wg_in.name=Allow-WireGuard
		uci set firewall.wg_in.src=wan
		uci set firewall.wg_in.proto=udp
		uci set firewall.wg_in.dest_port="$WG_LISTEN_PORT"
		uci set firewall.wg_in.target=ACCEPT
	fi

	# Маскарадинг из туннеля в LAN — когда у камер другой шлюз
	lanzone=''
	for z in $(uci -X show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		[ "$(uci -q get "firewall.$z.name")" = lan ] && lanzone="$z"
	done
	if [ -n "$lanzone" ]; then
		uci -q delete "firewall.$lanzone.masq"
		uci -q delete "firewall.$lanzone.masq_src"
		if [ "$LAN_MASQ" = 1 ]; then
			uci set "firewall.$lanzone.masq=1"
			for net in $PEER_ALLOWED; do uci add_list "firewall.$lanzone.masq_src=$net"; done
		fi
	fi

	# --- Wi-Fi только с паролем (WPA2) ---
	if [ -n "$WIFI_SSID" ]; then
		uci set "wireless.@wifi-device[0].disabled=0"
		if [ -n "$WIFI_COUNTRY" ]; then uci set "wireless.@wifi-device[0].country=$WIFI_COUNTRY"; fi
		uci set "wireless.@wifi-iface[0].disabled=0"
		uci set "wireless.@wifi-iface[0].ssid=$WIFI_SSID"
		uci set "wireless.@wifi-iface[0].encryption=psk2"
		uci set "wireless.@wifi-iface[0].key=$WIFI_KEY"
	fi

	# Сервер по домену (DDNS) — раз в минуту переразрешать имя, если туннель простаивает
	case "$PEER_HOST" in
		*[!0-9.]*)
			grep -q wireguard_watchdog /etc/crontabs/root 2>/dev/null ||
				echo '* * * * * /usr/bin/wireguard_watchdog' >> /etc/crontabs/root
			/etc/init.d/cron enable
			/etc/init.d/cron restart
			;;
	esac

	if [ -n "$LAN_IP" ]; then uci set network.lan.ipaddr="$LAN_IP"; fi
	uci commit

	lan_ip="$(uci -q get network.lan.ipaddr)"
	lan_mask="$(uci -q get network.lan.netmask)"
	if [ "$lan_mask" = 255.255.255.0 ]; then lan_net="${lan_ip%.*}.0/24"; else lan_net="<подсеть LAN>"; fi

	echo
	echo "Готово. Публичный ключ роутера: $WG_PUBKEY"
	echo "Добавьте на сервер WireGuard:"
	echo
	echo "[Peer]"
	echo "PublicKey = $WG_PUBKEY"
	if [ -n "$PEER_PSK" ]; then echo "PresharedKey = $PEER_PSK"; fi
	echo "AllowedIPs = ${WG_ADDR%/*}/32, $lan_net"
	echo
	echo "Проверка через минуту: wg show (строка latest handshake)"
	if [ -n "$LAN_IP" ]; then echo "IP роутера меняется на $LAN_IP — переподключитесь к нему."; fi

	(sleep 2; /etc/init.d/network reload; /etc/init.d/firewall reload; wifi up) >/dev/null 2>&1 &
}
wg_setup
