#!/bin/sh
set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
ROUTER=${1:-192.168.3.1}
SSID=${WIFI_SSID:-dinaferreira.pt}
KEY=${WIFI_KEY:-}
[ -n "$KEY" ] || { echo "falta WIFI_KEY (a passphrase do SSID). Ex: WIFI_KEY='...' $0 $ROUTER"; exit 1; }
APN=${APN:-internet}
PDP_MTU=${PDP_MTU:-1400}
case "$SSID$KEY$APN$PDP_MTU" in *\'*) echo "SSID/KEY/APN nao podem ter plicas (')"; exit 1;; esac
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

VARS="SSID='$SSID'; KEY='$KEY'; APN='$APN'; PDP_MTU='$PDP_MTU'"

SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new root@$ROUTER"
SCP="scp -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"

run() {
	if [ "$DRY" = 1 ]; then
		echo "[dry] $*"
	else
		$SSH "$VARS; $*"
	fi
}

say() { printf '\n== %s\n' "$*"; }

say "alvo: $ROUTER"
$SSH 'cat /etc/openwrt_release | grep -E "DISTRIB_RELEASE|DISTRIB_TARGET"' ||
	{ echo "sem SSH. Verifica a chave e a porta 22."; exit 1; }

say "1/7 copiar scripts"
$SCP "$SRC_DIR/scripts/wan-up.sh" "$SRC_DIR/scripts/uq" "$SRC_DIR/scripts/siglog.sh" \
	"$SRC_DIR/scripts/irq-spread.sh" "$SRC_DIR/scripts/wifi-log.sh" "root@$ROUTER:/usr/bin/"
$SCP "$SRC_DIR/scripts/30-wwan-ifup" "$SRC_DIR/scripts/41-ap-isolate" \
	"root@$ROUTER:/etc/hotplug.d/net/"
run 'chmod +x /usr/bin/wan-up.sh /usr/bin/uq /usr/bin/siglog.sh /usr/bin/irq-spread.sh /usr/bin/wifi-log.sh /etc/hotplug.d/net/30-wwan-ifup /etc/hotplug.d/net/41-ap-isolate'

say "2/7 rede: lan1 admin, lan2/lan3 pos, rede loja (Wi-Fi isolada)"
run 'uci set network.lan.device="br-lan"; uci set network.lan.proto="static"
uci set network.lan.ipaddr="192.168.3.1"; uci set network.lan.netmask="255.255.255.0"
uci delete network.lan.ip6assign 2>/dev/null
uci delete network.globals.ula_prefix 2>/dev/null
d=$(uci show network | grep "name=.br-lan." | cut -d. -f2)
uci -q delete network.$d.ports || true; uci add_list network.$d.ports="lan1"
uci -q delete network.pos_dev || true
uci set network.pos_dev=device; uci set network.pos_dev.name="br-pos"; uci set network.pos_dev.type="bridge"
uci add_list network.pos_dev.ports="lan2"; uci add_list network.pos_dev.ports="lan3"
uci -q delete network.pos || true
uci set network.pos=interface; uci set network.pos.device="br-pos"; uci set network.pos.proto="static"
uci set network.pos.ipaddr="192.168.5.1"; uci set network.pos.netmask="255.255.255.0"
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
uci set network.wan.apn="$APN"
uci set network.wan.mtu="$PDP_MTU"
uci set network.wan.auto="1"
uci set network.globals.packet_steering="1"
uci commit network'

say "3/7 dhcp + zonas de firewall + MSS"
run 'uci set dhcp.loja=dhcp; uci set dhcp.loja.interface="loja"
uci set dhcp.loja.start="100"; uci set dhcp.loja.limit="100"; uci set dhcp.loja.leasetime="2h"
uci set dhcp.pos=dhcp; uci set dhcp.pos.interface="pos"
uci set dhcp.pos.start="100"; uci set dhcp.pos.limit="50"; uci set dhcp.pos.leasetime="12h"
for o in dhcpv6 ra ra_slaac ra_flags; do uci -q delete dhcp.lan.$o; done
uci commit dhcp
uci -q delete firewall.loja || true
uci set firewall.loja=zone; uci set firewall.loja.name="loja"
uci set firewall.loja.network="loja"; uci set firewall.loja.input="REJECT"
uci set firewall.loja.output="ACCEPT"; uci set firewall.loja.forward="REJECT"
uci set firewall.loja.masq="1"; uci set firewall.loja.mtu_fix="0"
uci set firewall.@zone[1].mtu_fix="1"
for n in Allow-ISAKMP Allow-IPSec-ESP Allow-IGMP; do
  i=$(uci show firewall | grep "name=.$n.$" | cut -d. -f2); [ -n "$i" ] && uci delete firewall.$i
done
i=$(uci show firewall | grep "path=./etc/firewall.user." | cut -d. -f2); [ -n "$i" ] && uci delete firewall.$i
rm -f /etc/firewall.user
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
for z in pos; do
  uci -q delete firewall.$z || true
  uci set firewall.$z=zone; uci set firewall.$z.name="$z"; uci set firewall.$z.network="$z"
  uci set firewall.$z.input="REJECT"; uci set firewall.$z.output="ACCEPT"; uci set firewall.$z.forward="REJECT"
  uci -q delete firewall.${z}_fwd || true
  uci set firewall.${z}_fwd=forwarding; uci set firewall.${z}_fwd.src="$z"; uci set firewall.${z}_fwd.dest="wan"
  uci -q delete firewall.${z}_dhcp || true
  uci set firewall.${z}_dhcp=rule; uci set firewall.${z}_dhcp.name="$z-dhcp"; uci set firewall.${z}_dhcp.src="$z"
  uci set firewall.${z}_dhcp.proto="udp"; uci set firewall.${z}_dhcp.dest_port="67"; uci set firewall.${z}_dhcp.target="ACCEPT"
  uci -q delete firewall.${z}_dns || true
  uci set firewall.${z}_dns=rule; uci set firewall.${z}_dns.name="$z-dns"; uci set firewall.${z}_dns.src="$z"
  uci set firewall.${z}_dns.proto="tcp udp"; uci set firewall.${z}_dns.dest_port="53"; uci set firewall.${z}_dns.target="ACCEPT"
done
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

say "5/7 admin so pelo cabo na lan1 (SSH e LuCI so em 192.168.3.1)"
run 'uci set dropbear.main.PasswordAuth="off"
uci set dropbear.main.Interface="lan"
uci -q delete dropbear.main.DirectInterface || true; uci -q delete dropbear.main._direct || true
uci commit dropbear; /etc/init.d/dropbear restart
uci -q delete uhttpd.main.listen_http || true; uci -q delete uhttpd.main.listen_https || true
uci add_list uhttpd.main.listen_http="192.168.3.1:80"; uci add_list uhttpd.main.listen_https="192.168.3.1:443"
uci commit uhttpd; /etc/init.d/uhttpd restart'

say "6/7 watchdog + backup do overlay"
run 'grep -q power_modem /etc/rc.local || sed -i "/^exit 0/i echo 1 > /sys/class/gpio/power_modem/value 2>/dev/null" /etc/rc.local
grep -q irq-spread /etc/rc.local || sed -i "/^exit 0/i /usr/bin/irq-spread.sh" /etc/rc.local
/usr/bin/irq-spread.sh
grep -q wan-up /etc/crontabs/root || echo "* * * * * /usr/bin/wan-up.sh" >> /etc/crontabs/root
grep -q wifi-log /etc/crontabs/root || echo "* * * * * /usr/bin/wifi-log.sh" >> /etc/crontabs/root
/etc/init.d/cron enable; /etc/init.d/cron restart
sed -i "\#/etc/firewall.user#d" /etc/sysupgrade.conf
for f in /usr/bin/wan-up.sh /usr/bin/siglog.sh /usr/bin/irq-spread.sh /usr/bin/wifi-log.sh /etc/rc.local /etc/crontabs/root; do
  grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
grep -q /etc/hotplug.d/net /etc/sysupgrade.conf || echo "/etc/hotplug.d/net/" >> /etc/sysupgrade.conf'

say "7/7 verificar"
$SSH 'echo "lan:    $(ip -4 addr show br-lan | grep -oE "inet [0-9./]+")"
echo "pos:    $(ip -4 addr show br-pos | grep -oE "inet [0-9./]+")"
echo "loja:   $(ip -4 addr show br-loja | grep -oE "inet [0-9./]+")"
echo "wifi:   $(iwinfo 2>/dev/null | grep -oE "ESSID: \"[^\"]*\"" | sort -u | tr "\n" " ")"
echo "wan:    $(ip -4 addr show wwan0 2>/dev/null | grep -oE "inet [0-9./]+" || echo pendente) apn=$(uci -q get network.wan.apn) mtu=$(uci -q get network.wan.mtu)"
echo "mss:    $(nft list ruleset | grep -c "maxseg size set rt mtu") regras (esperado 2)"
echo "zonas:  $(uci show firewall | grep -oE "zone\[[0-9]\]\.name=.[a-z]+." | cut -d= -f2- | tr "\n" " ")"
echo "cron:   $(crontab -l | tr "\n" " ")"
echo "dropbear: password=$(uci get dropbear.main.PasswordAuth) iface=$(uci get dropbear.main.Interface)"'

echo
echo "Feito. Se o LTE ainda nao tiver IP, corre: /usr/bin/wan-up.sh (ou espera 1 min pelo cron)."
