#!/bin/sh
L=/tmp/wifi-clients.log; T=$(date "+%F %T")
for i in phy0-ap0 phy1-ap0; do b=2.4; [ $i = phy1-ap0 ] && b=5
iw dev $i station dump | awk -v t="$T" -v b=$b "/^Station/{m=\$2} /signal:/{s=\$2} /tx bitrate/{tx=\$3} /rx bitrate/{print t, b\"GHz\", m, s\"dBm\", \"tx=\"tx, \"rx=\"\$3}" >> $L
done
[ $(wc -l < $L) -gt 2000 ] && sed -i 1,500d $L
