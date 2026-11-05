# Notas — Zyxel LTE3301-PLUS com OpenWrt (2026-11-04)

Registo técnico do que foi feito, do que falhou e porquê. Tudo medido no aparelho; nada
copiado de terceiros. Os números de sinal e débito são deste local (DIGI/NOS, interior).

## Ponto de partida

Aparelho novo, firmware de fábrica `V1.17(ACCA.0)C0`, gerido por **Nebula**
(`getBasicInformation` sem autenticação devolve `ModelName: LTE3301-PLUS`). Já funcionava
como CPE LTE da DIGI, com LTE-A em B3 e RSSI -63: o OpenWrt foi opção, não reparação.

O stock não tem shell utilizável: `dropbear` só com a password do Nebula e uma CLI Zyxel.
A UI (`/cgi-bin/*`) responde `{"result":"Invalid Username or Password"}` a tudo o que não
tenha sessão — **inclusive endpoints de leitura**. O modelo acabou por sair do **banner do
telnet** (`LTE3301-PLUS login:`), que responde sem credenciais. SSDP/UPnP, SNMP e mDNS mudos;
7547 (TR-069) fechado.

### Autenticação da UI (para automatizar o upload)

```
GET  /getRSAPublickKey            -> PEM
key  = 32 bytes aleatórios (base64)      iv = 32 bytes aleatórios (base64)
POST /UserLogin
  {"content": base64(AES-256-CBC(json, key, iv[:16])),
   "key":     base64(RSA-PKCS1v15(key_b64_string)),
   "iv":      iv_b64}
  json = {"Input_Account","Input_Passwd": base64(password),"currLang":"en",
          "RememberPassword":0,"SHA512_password":false}
resposta {content, iv} -> decifrar com a mesma key; devolve `sessionkey`
```

O upload de firmware não leva cifra: `POST /cgi-bin/Firmware_Upgrade`, multipart com o campo
`filename`, e o header `CSRFToken: <sessionkey>`. Devolveu `{"result":"ZCFG_SUCCESS"}` em
1,2 s. **Atenção:** o `sessionkey` só vale com o cookie `Session` da mesma sessão — usar a
sessão HTTP, não um POST solto (foi um 401 que me atrasou 20 minutos).

Nota de segurança: no primeiro login o aparelho obriga a definir password nova
(`changePw: true`); `admin`/`1234` e a password do Nebula não servem.

## Flash

Sequência real, com as surpresas:

```
1. upload OEM        1,2 s, ZCFG_SUCCESS -> reboot; a 22 passa de dropbear_2018.76
                     para dropbear moderno (é o sinal de que o OpenWrt entrou)
2. shell             SSH root@192.168.1.1 SEM password no initramfs;
                     telnet 23 NÃO existe (contrariamente a outros CPE)
3. NAND              a imagem já traz ubi0 ligado a mtd6 com um volume "data":
                     ubidetach -m6 && ubiformat /dev/mtd6 -y && ubiattach -m6
                     ubimkvol /dev/ubi0 -n0 -N rootfs -s 1MiB
                     ubimkvol /dev/ubi0 -n1 -N rootfs_data -s 1MiB
                     4 blocos maus: 125, 137, 147, 260
4. imagem            HTTP de saída dá EPERM -> transferir por stdin:
                     cat sysupgrade.bin | ssh root@... 'cat > /tmp/sysupgrade.bin'
                     sha256 no aparelho == 47f2fcc9…
5. flash             sysupgrade -T -> rc=0 ; sysupgrade -n -> "Commencing upgrade"
                     (rc=246 = a ligação caiu, não é erro); 22 de volta aos ~80 s
6. confirmado        25.12.6 r33311, / = overlayfs sobre ubi0_1 (rootfs_data ubifs)
```

## O erro que custou a noite: `ipaddr` sem máscara

`uci set network.lan.ipaddr='192.168.3.1'` (sem `netmask`) fez o netifd aplicar
**`192.168.3.1/32`**. Consequências, todas sintomáticas e nenhuma óbvia:

```
PC -> router     SYN chega (o router conta um SYN_RECV)
router -> PC     SYN-ACK sem rota de volta -> sai pelo default (wwan0) e perde-se
tcpdump no PC    só SYNs a sair, nenhum SYN-ACK a entrar
porta 22         funcionava! (dropbear amarrado a br-lan; o uhttpd não)
DHCP             sem sub-rede, o dnsmasq não serve leases
```

Perdi horas a acusar o `ufw` do PC e o WARP, ambos inocentes (com o `ufw` **desligado** o
80/443 continuavam em timeout). A prova de que era o router: com o `ufw` off, o `tcpdump`
mostrou que nada voltava. Correcção: uma linha (`netmask 255.255.255.0`) e o LuCI passou a
responder 200.

**Lição:** a mesma armadilha já estava documentada no repo do Cudy LT300 (perfil com prefixo
inline). Ao mudar a LAN por UCI, escrever sempre a máscara.

## O modem: GPIO, QMI e APN

- `power_modem` (gpio 27) vem a **0** no arranque do OpenWrt: sem modem no USB, sem
  `/dev/cdc-wdm0`, sem `ttyUSB*`. `echo 1 > /sys/class/gpio/power_modem/value` e o EG06-E
  aparece (`2c7c:0306`, ttyUSB2/3 + cdc-wdm0 + wwan0). Persistido no `/etc/rc.local`.
- O primeiro `ifup wan` ainda a meio da inicialização do SIM **pendura o QMI**:
  `Waiting for SIM initialization` → `Request timed out` → `SIM in illegal state -
  Power-cycling SIM` → `Failed to connect to service`. A escada que resolve é
  `killall uqmi` + `--sync` + `ifup` em background; e `AT+CFUN=1,1` só quando está
  registado e sem dados. Nunca na sessão interactiva (perde-se o SSH).
- `pdptype='ipv4'` (o `ipv4v6` pendura estes Quectel, como no LBR20).
- ~~MTU nunca~~ — **corrigido a 2026-11-05**: `mtu='1400'` (= MTU do PDP da DIGI) funciona
  neste firmware (EG06ELAR03A07M4G), sobrevive a `ifdown/ifup` e a arranque a frio, e com
  `mtu_fix 1` dobrou o upload. Ver secção de 2026-11-05.
- APN: o perfil do SIM vem vazio e o OpenWrt espera que a rede o atribua. A DIGI atribui
  (funciona com `apn=''`), mas o APN oficial é `internet` e é o que fica configurado; a
  NOS/WOO não atribui — precisa de `apn='umts'`. Não é avaria, é diferença de software face
  a um CPE de marca (que traz base de dados de APNs).

## Comparação de operadores no mesmo sítio (trocando só o cartão, 2026-11-04, antes da correcção de APN/MTU)

```
                    DIGI (268-02)                    WOO/NOS (268-03)
portadoras          B7 10 MHz + B3 10 MHz            B7 20 MHz + B3 20 MHz
CA                  activado                          "deactivated"
down (router)       62-67 Mbps estável                11-48 Mbps errático
up (telemóvel)      8-13 Mbps                        16,5 Mbps
ping                28-45 ms                          21-152 ms (jitter)
APN                 vazio                             umts
PDP MTU             1400                              1456
IP público          176.223.x                         87.196.80.3 (público, não CGNAT)
```

Escolha para loja: **DIGI**. O critério não é só débito: áudio para colunas é download e
sofre com 150 ms de jitter. A WOO tem uplink melhor e mais espectro por portadora, mas não
agrega — logo metade.

O tecto do aparelho: EG06-E é **Cat 6 (2 portadoras no download, 1 no upload)** e a rede
local só oferece aquelas duas, de 10 MHz cada. 10+10 MHz em 2x2/64QAM dão ≈150 Mbps de PHY
no download e ≈50 no upload; numa célula partilhada, os 83-92 / 15-19 medidos depois da
correcção são o tecto prático. Mais só com portadoras mais largas da operadora ou 5G —
outro rádio, não configuração.

## Desenho final (loja)

```
br-lan    lan1 lan2 lan3    192.168.3.1/24    POS + administração
br-loja   phy0-ap0 phy1-ap0 192.168.4.1/24    clientes, isolados
lan4      wan4 dhcp metric 10                 uplink ethernet opcional (ex. CPE 5G)
wwan0     wan qmi   metric 20                 LTE
```

- Wi-Fi: um SSID nas duas bandas (`psk2`), ch11 HT20 / ch36 VHT80, `isolate 1`,
  `ieee80211k` + `rrm_neighbor_report`. Este hostapd **não tem WNM** (`bss_transition`
  impede-o de arrancar).
- Isolamento de clientes em duas camadas: `ap_isolate` (dentro da BSS) + `brport/isolated`
  (cruzamento 2,4↔5 GHz). Verificado com um Android: fica em `192.168.4.x`, navega a
  59/13,5 Mbps e **`192.168.3.1` está bloqueado**.
- Zona `loja`: input REJECT, forward REJECT, masq, forwarding só para `wan`, e regras
  explícitas para DHCP (67/udp) e DNS (53) — sem elas não há lease nem resolução.
- Admin só pelo cabo: `dropbear` com `PasswordAuth off` e `Interface br-lan` (chave ed25519).

## Watchdog

`/usr/bin/wan-up.sh` por cron a cada minuto, e uma vez pelo hotplug do `wwan0`. Lock em
`/tmp/wan-up.lock`, transições em `/root/wan.log`. Escada: ping por `wwan0` → `ifup` →
sem registo: espera (SIM/cobertura) → registado sem dados: `AT+CFUN=1,1` + `sync` + `ifup`.

Nada de GPIO nem de `modem_switch` — isso é do LBR20.

Medições:

```
ifdown wan propositado      recuperou em ~70 s (log "inicio: rede em baixo")
cold boot -> SSH            72 s   (61 s a 2026-11-05)
cold boot -> LTE com IPv4   104 s, sem intervenção   (97 s a 2026-11-05, com auto=1)
```

## Limpeza e afinações

Removidos 10 pacotes (171 → 161): `luci-app-attendedsysupgrade`, `owut`, `ppp`,
`ppp-mod-pppoe`, `kmod-ppp/pppoe/pppox/slhc`, `odhcpd-ipv6only`, `odhcp6c`.
IPv6 fora (`ip6assign` e `ula_prefix` removidos, odhcpd parado) — o PDP é IPv4.
LEDs todos em `none`, excepto `internet` (netdev `wwan0`, link/tx/rx). `/etc/sysupgrade.conf` passou a incluir `wan-up.sh`, hotplug,
`firewall.user` e crontab (o backup passou de 44 para 42 ficheiros com os scripts dentro).

`flow_offloading` + `flow_offloading_hw` ligados (flowtable com `flags offload`); a 67 Mbps
o MT7621 fica nos 6% de CPU, portanto o offload não é o factor — fica ligado porque o
`lan4` pode um dia levar um 5G ao lado.

## 2026-11-05 — APN, MTU, IRQs e teste de bandas

Ponto de partida: 84-91 Mbps down, **7,8 up**, ping 43 ms (máx. 158). Sinal bom
(RSRP -88, SINR 22,8), CA B3+B7 10+10 MHz activa, CPU 91% livre.

Diagnóstico: o PDP anuncia MTU 1400, mas o `wwan0` estava a 1500 com `mtu_fix 0`;
APN vazio; `wan.auto 0` (o LTE só subia pelo hotplug, 40 s depois).

```
network.wan.apn       internet
network.wan.mtu       1400
network.wan.auto      1
firewall zone wan     mtu_fix 1        (MSS 1360 = rt mtu - 40, nas duas direcções)
/etc/firewall.user    removido         (as regras maxseg 1360 duplicavam o mtu_fix)
```

Resultado: **83-92 / 15-19 Mbps**, ping ~36 ms. Arranque a frio: SSH 61 s, LTE 97 s.

O watchdog disparou no primeiro minuto após o arranque, com o netifd ainda a ligar o QMI
(`killall uqmi` a meio = armadilha do QMI pendurado). Recuperou em 26 s, mas passou a ter
uma guarda: não faz nada com `uptime < 150 s`.

Afinação e limpeza:

- IRQs: estavam todos no CPU0. `irq-spread.sh` (pelo `rc.local`): ethernet CPU0,
  xhci/modem CPU1, mt7615e CPU2. Os números do LTE não mudam (o limite é o rádio).
- Removidas regras wan→lan de IPSec/ISAKMP e IGMP (CGNAT, sem uso) e as opções de
  servidor DHCPv6/RA da `lan` (sem odhcpd, sem efeito).
- `802.11v` (`bss_transition`, `wnm_sleep_mode`) **outra vez testado e outra vez a deitar
  abaixo os dois rádios** com `wpad-basic-mbedtls` — revertido. Confirma a nota acima.

Teste A/B das bandas (mesmo telemóvel, mesmo sítio, speed.cloudflare.com):

```
A   2,4 + 5 GHz, mesmo SSID   82,5 / 17,8   cliente em 5 GHz, -30 dBm, 866,7 Mbit/s
B   só 5 GHz (radio0 off)     89,5 / 18,8   cliente em 5 GHz, -28 dBm, 866,7
A2  2,4 + 5 GHz, mesmo SSID   92,1 / 18,1   cliente em 5 GHz, -29 dBm, 866,7
```

Ter as duas bandas no mesmo SSID **não** custa débito: o MT7615E é DBDC (um rádio e
antenas por banda), e a variação é do LTE. Ocultar/desligar uma banda não ganha nada e
perde o alcance dos 2,4 GHz. O que custaria débito seria um cliente preso nos 2,4 GHz
(HT20 ≈ 40-70 Mbps reais) — para isso há agora o `wifi-log.sh` (cron, a cada minuto,
`/tmp/wifi-clients.log`). Se lá aparecerem clientes em 2,4 GHz com bom sinal, a resposta é
`wpad-mbedtls` + `usteer`, não esconder SSIDs.

## Comandos úteis

```sh
/usr/bin/uq -d /dev/cdc-wdm0 --get-signal-info
/usr/bin/uq -d /dev/cdc-wdm0 --get-lte-cphy-ca-info
/usr/bin/uq -d /dev/cdc-wdm0 --get-current-settings

( cat /dev/ttyUSB2 > /tmp/at.out & echo $! > /tmp/p ); sleep 1
printf 'AT+QENG="servingcell"\r' > /dev/ttyUSB2; sleep 3; kill $(cat /tmp/p)
cat /tmp/at.out

/usr/bin/siglog.sh 6 5
```
