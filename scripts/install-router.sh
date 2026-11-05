#!/bin/sh
# install-router.sh — aplica este kit num Zyxel LTE3301-PLUS já com OpenWrt.
# Idempotente: pode correr duas vezes seguidas que o resultado é o mesmo.
#
#   ./install-router.sh [ROUTER] [--dry-run]
#   ROUTER default: 192.168.3.1
#
# Requer chave SSH (o dropbear do alvo é key-only depois da primeira execução).
set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ROUTER=${1:-192.168.3.1}
SSID=${WIFI_SSID:-dinaferreira.pt}
KEY=${WIFI_KEY:-}
[ -n "$KEY" ] || { echo "falta WIFI_KEY (a passphrase do SSID). Ex: WIFI_KEY='...' $0 $ROUTER"; exit 1; }
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new root@$ROUTER"
SCP="scp -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

run() {
	if [ "$DRY" = 1 ]; then
		echo "[dry] $*"
	else
		$SSH "$*"
	fi
}

say() { printf '\n== %s\n' "$*"; }

say "alvo: $ROUTER"
$SSH 'cat /etc/openwrt_release | grep -E "DISTRIB_RELEASE|DISTRIB_TARGET"' ||
	{ echo "sem SSH. Verifica a chave e a porta 22."; exit 1; }

say "1/7 copiar scripts"
$SCP "$SRC_DIR/scripts/wan-up.sh" "$SRC_DIR/scripts/uq" "$SRC_DIR/scripts/siglog.sh" \
	"root@$ROUTER:/usr/bin/"
$SCP "$SRC_DIR/scripts/30-wwan-ifup" "$SRC_DIR/scripts/41-ap-isolate" \
	"root@$ROUTER:/etc/hotplug.d/net/"
$SCP "$SRC_DIR/scripts/firewall.user" "root@$ROUTER:/etc/"
run 'chmod +x /usr/bin/wan-up.sh /usr/bin/uq /usr/bin/siglog.sh /etc/hotplug.d/net/30-wwan-ifup /etc/hotplug.d/net/41-ap-isolate'

say "2/7 rede: lan /24 e rede loja (Wi-Fi isolada)"
run 'uci set network.lan.device="br-lan"; uci set network.lan.proto="static"
uci set network.lan.ipaddr="192.168.3.1"; uci set network.lan.netmask="255.255.255.0"
uci delete network.lan.ip6assign 2>/dev/null
uci delete network.globals.ula_prefix 2>/dev/null
uci -q delete network.loja || true
uci show network | grep -q "name=.br-loja." || { uci add network device; uci set network.@device[-1].name="br-loja"; uci set network.@device[-1].type="bridge"; }
uci set network.loja=interface; uci set network.loja.device="br-loja"
uci set network.loja.proto="static"; uci set network.loja.ipaddr="192.168.4.1"
uci set network.loja.netmask="255.255.255.0"
uci -q delete network.wan4 || true
uci set network.wan4=interface; uci set network.wan4.device="lan4"
uci set network.wan4.proto="dhcp"; uci set network.wan4.metric="10"
uci set network.wan4.peerdns="0"; uci set network.wan4.dns="1.1.1.1 1.0.0.1"
uci set network.wan.proto="qmi"; uci set network.wan.device="/dev/cdc-wdm0"
uci set network.wan.pdptype="ipv4"; uci set network.wan.auth="none"
uci set network.wan.ipv6="0"; uci set network.wan.metric="20"
uci set network.wan.auto="0"
uci commit network'

say "3/7 dhcp + zonas de firewall + MSS"
run 'uci set dhcp.loja=dhcp; uci set dhcp.loja.interface="loja"
uci set dhcp.loja.start="100"; uci set dhcp.loja.limit="100"; uci set dhcp.loja.leasetime="2h"
uci commit dhcp
uci -q delete firewall.loja || true
uci set firewall.loja=zone; uci set firewall.loja.name="loja"
uci set firewall.loja.network="loja"; uci set firewall.loja.input="REJECT"
uci set firewall.loja.output="ACCEPT"; uci set firewall.loja.forward="REJECT"
uci set firewall.loja.masq="1"; uci set firewall.loja.mtu_fix="0"
uci set firewall.@zone[1].mtu_fix="0"
uci -q delete firewall.loja_fwd || true
uci set firewall.loja_fwd=forwarding; uci set firewall.loja_fwd.src="loja"
uci set firewall.loja_fwd.dest="wan"
uci -q delete firewall.loja_dhcp || true
uci set firewall.loja_dhcp=rule; uci set firewall.loja_dhcp.name="loja-dhcp"
uci set firewall.loja_dhcp.src="loja"; uci set firewall.loja_dhcp.proto="udp"
uci set firewall.loja_dhcp.dest_port="67"; uci set firewall.loja_dhcp.target="ACCEPT"
uci -q delete firewall.loja_dns || true
uci set firewall.loja_dns=rule; uci set firewall.loja_dns.name="loja-dns"
uci set firewall.loja_dns.src="loja"; uci set firewall.loja_dns.proto="tcp udp"
uci set firewall.loja_dns.dest_port="53"; uci set firewall.loja_dns.target="ACCEPT"
uci show firewall | grep -q "path=./etc/firewall.user" || { uci add firewall include; uci set firewall.@include[-1].path="/etc/firewall.user"; uci set firewall.@include[-1].fw4_compatible="1"; }
uci commit firewall
fw4 check && fw4 reload'

say "4/7 wi-fi: um SSID nas duas bandas, isolamento"
run 'uci set wireless.radio0.country="PT"; uci set wireless.radio0.channel="11"
uci set wireless.radio0.htmode="HT20"; uci set wireless.radio0.disabled="0"
uci set wireless.radio1.country="PT"; uci set wireless.radio1.channel="36"
uci set wireless.radio1.htmode="VHT80"; uci set wireless.radio1.disabled="0"
uci set wireless.radio0.cell_density="1"; uci set wireless.radio1.cell_density="1"
for i in 0 1; do
  uci set wireless.default_radio$i.network="loja"
  uci set wireless.default_radio$i.mode="ap"
  uci set wireless.default_radio$i.ssid="$SSID"
  uci set wireless.default_radio$i.key="$KEY"
  uci set wireless.default_radio$i.encryption="psk2"
  uci set wireless.default_radio$i.disabled="0"
  uci set wireless.default_radio$i.isolate="1"
  uci set wireless.default_radio$i.ieee80211k="1"
  uci set wireless.default_radio$i.rrm_neighbor_report="1"
done
uci commit wireless; wifi reload; /etc/hotplug.d/net/41-ap-isolate'

say "5/7 admin so pelo cabo"
run 'uci set dropbear.main.PasswordAuth="off"
uci set dropbear.main.Interface="br-lan"
uci commit dropbear; /etc/init.d/dropbear restart'

say "6/7 watchdog + backup do overlay"
run 'printf "echo 1 > /sys/class/gpio/power_modem/value 2>/dev/null\n" > /dev/null
grep -q power_modem /etc/rc.local || sed -i "/^exit 0/i echo 1 > /sys/class/gpio/power_modem/value 2>/dev/null" /etc/rc.local
grep -q wan-up /etc/crontabs/root || echo "* * * * * /usr/bin/wan-up.sh" >> /etc/crontabs/root
/etc/init.d/cron enable; /etc/init.d/cron restart
for f in /usr/bin/wan-up.sh /usr/bin/siglog.sh /etc/firewall.user /etc/crontabs/root; do
  grep -q "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
grep -q /etc/hotplug.d/net /etc/sysupgrade.conf || echo "/etc/hotplug.d/net/" >> /etc/sysupgrade.conf'

say "7/7 verificar"
$SSH 'echo "lan:    $(ip -4 addr show br-lan | grep -oE "inet [0-9./]+")"
echo "loja:   $(ip -4 addr show br-loja | grep -oE "inet [0-9./]+")"
echo "wifi:   $(iwinfo 2>/dev/null | grep -oE "ESSID: \"[^\"]*\"" | sort -u | tr "\n" " ")"
echo "wan:    $(ip -4 addr show wwan0 2>/dev/null | grep -oE "inet [0-9./]+" || echo pendente)"
echo "zonas:  $(uci show firewall | grep -oE "zone\[[0-9]\]\.name=.[a-z]+." | cut -d= -f2- | tr "\n" " ")"
echo "cron:   $(crontab -l | tr "\n" " ")"
echo "dropbear: password=$(uci get dropbear.main.PasswordAuth) iface=$(uci get dropbear.main.Interface)"'

echo
echo "Feito. Se o LTE ainda nao tiver IP, corre: /usr/bin/wan-up.sh (ou espera 1 min pelo cron)."
