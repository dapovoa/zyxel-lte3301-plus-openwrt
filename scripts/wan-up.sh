#!/bin/sh
LOG=/root/wan.log
LOCK=/tmp/wan-up.lock
say() { echo "$(date "+%F %T") $*" >> "$LOG"; }
[ -e "$LOCK" ] && exit 0
[ "$(cut -d. -f1 /proc/uptime)" -lt 150 ] && exit 0
: > "$LOCK"
trap "rm -f $LOCK" EXIT INT TERM

net_ok() { ping -c1 -W3 -I wwan0 1.1.1.1 >/dev/null 2>&1; }
uq() {
  out=/tmp/uq.$$; rm -f "$out"
  ( uqmi "$@" > "$out" 2>&1 ) & p=$!
  i=0; while kill -0 $p 2>/dev/null && [ $i -lt 12 ]; do sleep 1; i=$((i+1)); done
  kill -9 $p 2>/dev/null
  cat "$out"; rm -f "$out"
}
net_ok && exit 0
say "inicio: rede em baixo"
killall -q uqmi
uq -d /dev/cdc-wdm0 --sync >/dev/null
( ifup wan >/dev/null 2>&1 & ) ; sleep 25
net_ok && { say "recuperado: ifup"; exit 0; }
reg=$(uq -d /dev/cdc-wdm0 --get-serving-system | grep -c "\"registration\": \"registered\"")
if [ "$reg" = "0" ]; then say "sem registo (SIM/cobertura) - retry no proximo ciclo"; exit 0; fi
say "registado sem dados -> AT+CFUN=1,1"
printf "AT+CFUN=1,1\r" > /dev/ttyUSB2 2>/dev/null
sleep 60
killall -q uqmi
uq -d /dev/cdc-wdm0 --sync >/dev/null
( ifup wan >/dev/null 2>&1 & ) ; sleep 25
net_ok && say "recuperado: reset do modem" || say "continua em baixo"
