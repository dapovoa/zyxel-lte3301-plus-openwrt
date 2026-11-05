# Zyxel LTE3301-PLUS on OpenWrt — 4G CPE as a store router

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.6-00B5E2)](https://openwrt.org/)
[![Target](https://img.shields.io/badge/target-ramips%2Fmt7621-blue)](https://openwrt.org/docs/techref/targets/ramips)
[![Device](https://img.shields.io/badge/device-Zyxel%20LTE3301--PLUS-informational)](https://openwrt.org/toh/hwdata/zyxel/zyxel_lte3301-plus)

An LTE CPE turned into a small store router: admin on one cable port, POS on two others,
customers on an isolated Wi-Fi network, LTE as uplink, and a watchdog that brings the link back by itself.
Everything below was measured on the hardware — including the two mistakes that cost a
night (a `/32` LAN and a wedged QMI client).

## Hardware

```
SoC        MediaTek MT7621AT (2 cores + HT = 4 threads, 880 MHz)
RAM        256 MB
Flash      128 MB NAND (MX30LF1G18AC), UBI on mtd6 ("ubi", 0x03ee0000)
Wi-Fi      MediaTek MT7615E (mt76), DBDC: one chip, two radios (2.4 + 5 GHz), 2x2 each
Ethernet   4x Gigabit (lan1..lan4, DSA switch)
LTE        Quectel EG06-E (Cat 6) on USB3 — reports "Quectel EG06, EG06ELAR03A07M4G"
SIM        1x micro-SIM
Antennas   2x detachable LTE (SMA)
Power      12 V, 1.5 A
Serial     header J5, 57600 8N1 (GND/RX/TX/3V3) — recovery console
GPIO       power_modem = gpio 27 (exported as /sys/class/gpio/power_modem, ACTIVE_LOW)
```

Ports, left to right on the case: `WAN/LAN1`, `LAN2`, `LAN3`, `LAN4`. In OpenWrt **all four
are in `br-lan` by default** — there is no dedicated WAN port like the stock firmware
(`dedicateEthWan`). This repo splits them:

```
WAN/LAN1   lan1   administration (despite the label — plug the admin PC here)
LAN2-3     lan2   POS
LAN4       lan4   optional wired uplink
```

## Firmware

OpenWrt supports this device since 23.05.0 (commit `2cc50592404a`). Images used here are
from release **25.12.6**, `ramips/mt7621`:

```
openwrt-25.12.6-ramips-mt7621-zyxel_lte3301-plus-initramfs-recovery.bin
  sha256 75b6c45bb7e304651434910bd43a5b79677328c034bea4daeee125141a79cfc0
openwrt-25.12.6-ramips-mt7621-zyxel_lte3301-plus-squashfs-sysupgrade.bin
  sha256 47f2fcc94f52869140fef080d9c0f8b5dc1f45b2e5443b6df8334b98fde0ea02

base: https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/
```

Both are in `firmware/sha256sums` (the binaries themselves are git-ignored — re-download).

Sanity checks before flashing, all done here:

- the `initramfs-recovery` starts with the **Zyxel `0RDH` header**, whose length field
  (`0x17c`) points exactly at the embedded uImage (`27051956`, "MIPS OpenWrt Linux-6.12.112",
  load address `0x80001000`). That header is why the stock web UI accepts the image at all.
- the `sysupgrade` tar carries `CONTROL` with `BOARD=zyxel_lte3301-plus`, which matches
  `/tmp/sysinfo/board_name` (`zyxel,lte3301-plus`, comma → underscore), so `sysupgrade -T`
  returns 0 and the board check passes.

Do not confuse this device with **LTE3301-M209/M904** — different boards, different images.

## Flashing from Zyxel stock

The stock firmware is a Nebula-managed build (`getBasicInformation` is unauthenticated and
reports `ModelName: LTE3301-PLUS`). There is no TFTP recovery on this model; the path is the
OEM web UI, then UBI preparation, then `sysupgrade`.

1. **Log in** as `admin` on `http://192.168.1.1`. On a factory unit the UI forces a new
   admin password on first login. Default `admin`/`1234` is rejected.

2. **Upload the initramfs** on *Maintenance → Firmware*. The stock accepts it in about a
   second and answers `{"result":"ZCFG_SUCCESS"}`; the box reboots into OpenWrt.

   The upload is a plain multipart POST — no AES layer:

   ```
   POST /cgi-bin/Firmware_Upgrade     field name: filename     header: CSRFToken: <sessionkey>
   ```

   (The rest of the UI *is* encrypted: login is `POST /UserLogin` with
   `{"content": AES-256-CBC(json), "key": RSA-PKCS1v15(key_b64), "iv": iv_b64}`.
   See NOTES-pt.md for the whole flow.)

3. **Get a shell.** The initramfs runs SSH with **no password** — `ssh root@192.168.1.1`.
   There is **no telnetd** on this build, despite what other CPE notes suggest.

4. **Prepare UBI.** The initramfs already attaches `mtd6` as `ubi0` with a leftover `data`
   volume, so `ubiformat` refuses until you detach:

   ```sh
   ubidetach -m6
   ubiformat /dev/mtd6 -y
   ubiattach -m6
   ubimkvol /dev/ubi0 -n0 -N rootfs      -s 1MiB
   ubimkvol /dev/ubi0 -n1 -N rootfs_data -s 1MiB
   ```

   Expect a few bad blocks (this unit: 125, 137, 147, 260 — normal).

5. **Push the sysupgrade image and flash it.** Outbound HTTP from the initramfs gave `EPERM`
   here, so `wget` was useless at this step — pipe the file over SSH instead (the installed
   25.12.6 system downloads normally):

   ```sh
   cat openwrt-25.12.6-...-squashfs-sysupgrade.bin \
     | ssh root@192.168.1.1 'cat > /tmp/sysupgrade.bin; sha256sum /tmp/sysupgrade.bin'
   ssh root@192.168.1.1 'sysupgrade -T /tmp/sysupgrade.bin'
   ssh root@192.168.1.1 'sysupgrade -n /tmp/sysupgrade.bin'
   ```

   Port 22 comes back ~80 s later, running 25.12.6 from squashfs with the overlay on
   `ubi0_1`.

## Network design

```
br-lan    lan1              192.168.3.1/24    administration         (LuCI + SSH only here)
br-pos    lan2 lan3         192.168.5.1/24    POS                    (internet only, no router access)
br-loja   phy0-ap0 phy1-ap0 192.168.4.1/24    Wi-Fi customers        (isolated)
lan4      wan4  proto dhcp  metric 10         optional wired uplink  (e.g. a 5G CPE)
wwan0     wan   proto qmi   metric 20         LTE
```

Firewall zones: `lan` (input ACCEPT), `wan` (input REJECT, masq), and `pos` / `loja`
(input REJECT, forward REJECT, masq, forwarding only to `wan`, plus explicit rules for
DHCP 67/udp and DNS 53/tcp+udp — without those there is no lease and no resolver).
SSH and LuCI listen only on `192.168.3.1`, so admin access from POS or Wi-Fi is blocked
by zone and by bind, not by a port rule.

## Wi-Fi

One SSID on both bands, `psk2` (WPA2-CCMP), country PT, `cell_density 1`:

```
radio0  2.4 GHz  ch11  HT20    (VHT does not exist in 2.4)
radio1  5   GHz  ch36  VHT80   (no DFS: radar would drop clients)
both    isolate 1, ieee80211k 1, rrm_neighbor_report 1
```

Client-to-client isolation needs **two layers**:

1. `ap_isolate=1` — separates clients inside the same BSS (per band);
2. `brport/isolated=1` on every `phy*-ap*` port (`scripts/41-ap-isolate`) — separates
   2.4 GHz clients from 5 GHz clients, because both BSS land in the same bridge and
   `ap_isolate` knows nothing about the other radio.

This `hostapd` build has **no WNM**: `bss_transition=1` makes hostapd refuse to start
("unknown configuration item") and both radios end up on channel 0 / 0 dBm. Do not use it.
Band steering is therefore left to the client (802.11k only). Real steering would need
`wpad-mbedtls` (full) + `usteer`; not installed, because it was not needed:

**Mixed bands do not cost throughput — measured.** The MT7615E is DBDC: each band has its
own radio and antennas, so the 2.4 GHz radio does not take airtime from 5 GHz. A/B on the
same phone, same spot (Cloudflare speed test, Mbps down/up):

```
A   2.4 + 5 GHz, same SSID   82.5 / 17.8    client on 5 GHz, -30 dBm, VHT-MCS9 2x2 866.7
B   5 GHz only (radio0 off)  89.5 / 18.8    client on 5 GHz, -28 dBm, 866.7
A2  2.4 + 5 GHz, same SSID   92.1 / 18.1    client on 5 GHz, -29 dBm, 866.7
```

The spread is LTE variance (82-92 Mbps measured on the router itself), not Wi-Fi. Hiding or
disabling a band gains nothing and loses the 2.4 GHz range. What *does* cost speed is a
client sitting on 2.4 GHz (HT20 ≈ 40-70 Mbps real, below the LTE). `scripts/wifi-log.sh`
(cron, every minute) records band / signal / bitrate per client in `/tmp/wifi-clients.log`
to catch exactly that.

## APN, MTU and MSS

The PDP MTU is **1400** with DIGI and **1456** with NOS/WOO (`uqmi --get-current-settings`).
With `wwan0` left at 1500 and `mtu_fix 0`, full-size packets do not fit the bearer, and upload
suffers. Validated config (DIGI, EG06ELAR03A07M4G, 25.12.6, survives `ifdown/ifup` and a
cold boot):

```
network.wan.apn      'internet'     official DIGI APN (NOS/WOO: 'umts')
network.wan.mtu      '1400'         = PDP MTU; wwan0 comes up at 1400
network.wan.auto     '1'            netifd brings LTE up at boot (watchdog is the backup)
firewall zone wan    mtu_fix 1      MSS = route MTU - 40 = 1360, both directions
firewall zone loja   mtu_fix 0      not needed: clamping happens on the wan zone
/etc/firewall.user   removed        the manual maxseg 1360 rules duplicated mtu_fix
```

Effect, same place, same SIM (router-local, Cloudflare):

```
                 before (apn '', mtu 1500, mtu_fix 0)   after
download         84-91 Mbps                             83-92 Mbps
upload           7.8 Mbps                               15-19 Mbps
ping             43 ms avg, 158 ms max                  36 ms avg
```

If a different modem firmware hangs with `mtu` set, fall back to `mtu_fix 1` alone.

## Watchdog

`scripts/wan-up.sh`, called every minute by cron and once from a net hotplug when `wwan0`
appears. Locked with `/tmp/wan-up.lock`, logs state transitions to `/root/wan.log`. It does
nothing during the first 150 s of uptime: with `auto 1`, netifd is still bringing QMI up
then, and a `killall uqmi` in the middle of that is pitfall 2 below.

```
ping -I wwan0 1.1.1.1 ok?               -> exit
killall uqmi; uqmi --sync; ifup wan     -> check again after 25 s
not registered?                          -> leave it alone (SIM/coverage), retry next minute
registered but no data?                  -> AT+CFUN=1,1 on /dev/ttyUSB2, wait 60 s, sync, ifup
```

The modem power GPIO (`power_modem`) is raised once by `/etc/rc.local`: OpenWrt leaves it
at 0 at boot, and without it the modem never enumerates.

Measured: a deliberate `ifdown wan` recovered in ~70 s; a cold boot reaches SSH in 61 s and
LTE with an IPv4 address in **97 s**, unattended.

## Measurements

DIGI, after the APN/MTU fix (2026-11-05):

```
signal     RSRP -88..-91 dBm, RSRQ -9..-14, SINR 16-23 dB
carriers   B3 10 MHz (PCC) + B7 10 MHz (SCC), CA active
download   83-92 Mbps   router-local, 1 or 4 streams; 82.5-92.1 from a 5 GHz phone
upload     15-19 Mbps
ping       ~36 ms
CPU        91% idle during the download (MT7621 is not the bottleneck)
```

DIGI was chosen over WOO/NOS (same box, same place): carrier aggregation active, stable
download, low jitter — audio-to-speakers is downlink and jitter-sensitive. Full comparison
in NOTES-pt.md. The modem is
Cat 6 (2 DL carriers max, 1 UL carrier) and the local cell offers B3 + B7 at 10 MHz each:
≈150 Mbps PHY peak down (2x2, 64QAM) and ≈50 up; 83-92 / 15-19 of real TCP on a shared cell
is the practical ceiling. More needs wider carriers from the operator or a 5G CPE — radio,
not configuration. Band locking does not help: the neighbour cells are weaker.

## IRQ affinity

`scripts/irq-spread.sh` (from `rc.local`) pins ethernet → CPU0, xhci (modem) → CPU1,
Wi-Fi → CPU2; by default all were on CPU0. `packet_steering 1` stays on.

## Pitfalls that cost real time

1. **`uci set network.lan.ipaddr='192.168.3.1'` without a netmask yields `/32`.** No route
   back to the LAN, so the router receives SYNs and cannot answer them. Only port 22 kept
   working because dropbear is bound to `br-lan` (SO_BINDTODEVICE) while uhttpd is not.
   Always write the mask, or `ipaddr='192.168.3.1/24'`.
2. **QMI hangs when `ifup wan` runs before the SIM is ready** — `Waiting for SIM
   initialization` → `Request timed out` → `SIM in illegal state - Power-cycling SIM` →
   `Failed to connect to service`. `uqmi` clients stay wedged and netifd blocks. The way
   out is `killall uqmi` + `--sync` + `ifup` in the background, and `AT+CFUN=1,1` only when
   the modem is registered but has no data.
3. **`/etc/init.d/network reload` kills dropbear.** Port 22 goes closed while LuCI (80/443)
   stays up. Recover with a reboot or `System → Startup → dropbear → Restart`.
4. **The LuCI write path sets `dropbear` `-l br-lan`**; when the LAN address changes the
   bind can leave no listener. Port 22 then answers with a RST (connection refused) even
   though procd says the instance is running.
5. **There is no `opkg`** in 25.12 — it is `apk`. `uqmi` *is* already in the image.
6. **`timeout` does not exist** in busybox here; wrap long commands with a background
   process plus `kill` (or you lose the SSH session to a hung `uqmi`).
7. **Outbound HTTP from the initramfs returned EPERM**; transfer files over SSH while
   flashing. The installed system downloads normally (`wget`/`uclient-fetch`).
8. **Set the operator APN explicitly** (the OpenWrt QMI profile has an empty APN). DIGI
   happens to work with `''`, but use the official `internet`; NOS/WOO needs `umts`.
9. **`bss_transition` / `wnm_sleep_mode` take both radios down** with `wpad-basic-mbedtls`
   ("unknown configuration item"); `wifi reload` does not recover until they are removed.
10. **The web UI is AES+RSA encrypted**, and its `cgi-exec` allows only a short list of
   commands (ACL); `ubus` over HTTP logs in fine but denies `uci`/`rc`/`system` actions for
   that session. Plan on SSH, not on LuCI automation.

## Files

```
config/uci-export.txt        real `uci export` of system/network/wireless/dhcp/firewall/
                             dropbear/uhttpd/luci on the running box (the Wi-Fi PSK is
                             redacted; set it with WIFI_KEY when running install-router.sh)
config/rc.local-e-cron.txt   rc.local, crontab, sysupgrade.conf
scripts/wan-up.sh            LTE watchdog
scripts/30-wwan-ifup         hotplug: modem appeared
scripts/41-ap-isolate        hotplug: bridge port isolation for the AP ports
scripts/irq-spread.sh        IRQ affinity (ethernet/modem/Wi-Fi on separate CPUs)
scripts/wifi-log.sh          per-client band/signal/bitrate log (cron, /tmp)
scripts/siglog.sh            LTE signal sampler (siglog.sh <samples> <seconds>)
scripts/uq                   uqmi with a 12 s timeout (a hung uqmi does not freeze SSH)
scripts/install-router.sh    push all of the above and apply uci + cron, idempotent
                             (WIFI_KEY=... APN=internet PDP_MTU=1400 ./install-router.sh)
firmware/sha256sums          image hashes (binaries are git-ignored)
```

## License

MIT — see `LICENSE`.
