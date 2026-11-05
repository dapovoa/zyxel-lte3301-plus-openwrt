#!/bin/sh
# registo de sinal LTE: "$1" amostras, "$2" segundos entre elas
n=${1:-5}; d=${2:-6}; i=0
while [ $i -lt $n ]; do
  s=$(/usr/bin/uq -d /dev/cdc-wdm0 --get-signal-info 2>/dev/null | tr -d "\n\t ")
  ca=$(/usr/bin/uq -d /dev/cdc-wdm0 --get-lte-cphy-ca-info 2>/dev/null | grep -oE "\"band\":[0-9]+|\"bandwidth\":\"[0-9]+\"|\"state\":\"[a-z]+\"" | tr "\n" " ")
  echo "$(date +%H:%M:%S) $s | $ca" >> /root/signal.log
  i=$((i+1)); [ $i -lt $n ] && sleep $d
done
