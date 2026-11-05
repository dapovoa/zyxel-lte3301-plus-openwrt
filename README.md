# Zyxel LTE3301-PLUS on OpenWrt

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.6-00B5E2.svg)
![Target](https://img.shields.io/badge/target-ramips%2Fmt7621-green.svg)
![Device](https://img.shields.io/badge/device-LTE3301--PLUS-orange.svg)
![Shell](https://img.shields.io/badge/shell-ash-lightgrey.svg)

A 4G CPE turned into a small store router.

## Overview

The Zyxel LTE3301-PLUS runs stock OpenWrt 25.12.6, configured as a store router:

1. Admin on one cable port (SSH and LuCI only there)
2. POS on two cable ports, internet only
3. Customers on an isolated Wi-Fi network
4. LTE uplink with a watchdog that brings the link back by itself

Everything below was measured on the hardware, including the two mistakes that cost a
night (a `/32` LAN and a wedged QMI client).

## Hardware

| Part | Detail |
|------|--------|
| SoC | MediaTek MT7621AT (2 cores + HT = 4 threads, 880 MHz) |
| RAM | 256 MB |
| Flash | 128 MB NAND (MX30LF1G18AC), UBI on mtd6 (`ubi`, `0x03ee0000`) |
| Wi-Fi | MediaTek MT7615E (mt76), DBDC: one chip, two radios (2.4 + 5 GHz), 2x2 each |
| Ethernet | 4x Gigabit (`lan1`..`lan4`, DSA switch) |
| LTE | Quectel EG06-E (Cat 6) on USB3, firmware `EG06ELAR03A07M4G` |
| SIM | 1x micro-SIM |
| Antennas | 2x detachable LTE (SMA) |
| Power | 12 V, 1.5 A |
| Serial | header J5, 57600 8N1 (GND/RX/TX/3V3), recovery console |
| GPIO | `power_modem` = gpio 27 (`/sys/class/gpio/power_modem`, active low) |

Do not confuse this device with **LTE3301-M209/M904**: different boards, different images.

## Ports

In OpenWrt **all four ports are in `br-lan` by default**. There is no dedicated WAN port
like the stock firmware (`dedicateEthWan`). This repo splits them:

| Case label | Device | Role |
|------------|--------|------|
| `WAN/LAN1` | `lan1` | Administration. Despite the label, plug the admin PC here |
| `LAN2`, `LAN3` | `lan2`, `lan3` | POS |
| `LAN4` | `lan4` | Optional wired uplink (e.g. a 5G CPE) |

## Network Design

| Bridge / device | Members | Address | Role |
|-----------------|---------|---------|------|
| `br-lan` | `lan1` | `192.168.3.1/24` | Administration (LuCI + SSH only here) |
| `br-pos` | `lan2` `lan3` | `192.168.5.1/24` | POS (internet only, no router access) |
| `br-loja` | `phy0-ap0` `phy1-ap0` | `192.168.4.1/24` | Wi-Fi customers (isolated) |
| `lan4` | `wan4`, DHCP, metric 10 | — | Optional wired uplink |
| `wwan0` | `wan`, QMI, metric 20 | — | LTE |

Firewall zones:

- `lan`: input ACCEPT
- `wan`: input REJECT, masq
- `pos` and `loja`: input REJECT, forward REJECT, masq, forwarding only to `wan`, plus
  explicit rules for DHCP 67/udp and DNS 53/tcp+udp. Without those there is no lease and
  no resolver.

SSH and LuCI listen only on `192.168.3.1`. Admin access from POS or Wi-Fi is blocked by
zone and by bind, not by a port rule.

## Firmware

OpenWrt supports this device since 23.05.0 (commit `2cc50592404a`). Images from release
**25.12.6**, `ramips/mt7621`
([downloads](https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/)):

```
openwrt-25.12.6-ramips-mt7621-zyxel_lte3301-plus-initramfs-recovery.bin
  sha256 75b6c45bb7e304651434910bd43a5b79677328c034bea4daeee125141a79cfc0
openwrt-25.12.6-ramips-mt7621-zyxel_lte3301-plus-squashfs-sysupgrade.bin
  sha256 47f2fcc94f52869140fef080d9c0f8b5dc1f45b2e5443b6df8334b98fde0ea02
```

Hashes are in `firmware/sha256sums`. The binaries are git-ignored, so download them again.

Checks done before flashing:

- The `initramfs-recovery` starts with the **Zyxel `0RDH` header**. Its length field
  (`0x17c`) points exactly at the embedded uImage (`27051956`, "MIPS OpenWrt Linux-6.12.112",
  load address `0x80001000`). That header is why the stock web UI accepts the image.
- The `sysupgrade` tar carries `CONTROL` with `BOARD=zyxel_lte3301-plus`, which matches
  `/tmp/sysinfo/board_name` (`zyxel,lte3301-plus`, comma → underscore). `sysupgrade -T`
  returns 0.

## Flashing from Zyxel Stock

The stock firmware is a Nebula-managed build (`getBasicInformation` is unauthenticated and
reports `ModelName: LTE3301-PLUS`). There is no TFTP recovery on this model. The path is the
OEM web UI, then UBI preparation, then `sysupgrade`.

1. **Log in** as `admin` on `http://192.168.1.1`. A factory unit forces a new admin password
   on first login. Default `admin`/`1234` is rejected.

2. **Upload the initramfs** on *Maintenance → Firmware*. The stock accepts it in about a
   second, answers `{"result":"ZCFG_SUCCESS"}` and reboots into OpenWrt. The upload is a
   plain multipart POST, with no AES layer:

   ```
   POST /cgi-bin/Firmware_Upgrade     field name: filename     header: CSRFToken: <sessionkey>
   ```

   The rest of the UI *is* encrypted: login is `POST /UserLogin` with
   `{"content": AES-256-CBC(json), "key": RSA-PKCS1v15(key_b64), "iv": iv_b64}`.
   Full flow in [NOTES-pt.md](NOTES-pt.md).

3. **Get a shell.** The initramfs runs SSH with **no password**: `ssh root@192.168.1.1`.
   There is **no telnetd** on this build.

4. **Prepare UBI.** The initramfs already attaches `mtd6` as `ubi0` with a leftover `data`
   volume, so `ubiformat` refuses until you detach:

   ```sh
   ubidetach -m6
   ubiformat /dev/mtd6 -y
   ubiattach -m6
   ubimkvol /dev/ubi0 -n0 -N rootfs      -s 1MiB
   ubimkvol /dev/ubi0 -n1 -N rootfs_data -s 1MiB
   ```

   Expect a few bad blocks (this unit: 125, 137, 147, 260). That is normal.

5. **Push the sysupgrade image and flash it.** Outbound HTTP from the initramfs returns
   `EPERM`, so pipe the file over SSH:

   ```sh
   cat openwrt-25.12.6-...-squashfs-sysupgrade.bin \
     | ssh root@192.168.1.1 'cat > /tmp/sysupgrade.bin; sha256sum /tmp/sysupgrade.bin'
   ssh root@192.168.1.1 'sysupgrade -T /tmp/sysupgrade.bin'
   ssh root@192.168.1.1 'sysupgrade -n /tmp/sysupgrade.bin'
   ```

   Port 22 comes back about 80 s later, running 25.12.6 from squashfs with the overlay on
   `ubi0_1`.

## How to Use

Install your SSH key on the router first. Step 5 of the installer turns password login off.

```sh
git clone https://github.com/dapovoa/zyxel-lte3301-plus-openwrt.git
cd zyxel-lte3301-plus-openwrt
WIFI_KEY='...' APN=internet PDP_MTU=1400 ./scripts/install-router.sh 192.168.3.1
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `WIFI_KEY` | (required) | Wi-Fi passphrase |
| `WIFI_SSID` | `dinaferreira.pt` | Wi-Fi name |
| `APN` | `internet` | Operator APN (DIGI `internet`, NOS/WOO `umts`) |
| `PDP_MTU` | `1400` | PDP MTU (DIGI 1400, NOS/WOO 1456) |

The first argument is the router address (default `192.168.3.1`). Add `--dry-run` as the
second argument to print the commands without running them. The script is idempotent.

## Wi-Fi

One SSID on both bands, `psk2` (WPA2-CCMP), country PT, `cell_density 1`:

| Radio | Band | Channel | Width | Note |
|-------|------|---------|-------|------|
| `radio0` | 2.4 GHz | 11 | HT20 | VHT does not exist in 2.4 |
| `radio1` | 5 GHz | 36 | VHT80 | No DFS: radar would drop clients |

Both radios use `isolate 1`, `ieee80211k 1` and `rrm_neighbor_report 1`.

Client-to-client isolation needs **two layers**:

1. `ap_isolate=1` separates clients inside the same BSS (per band).
2. `brport/isolated=1` on every `phy*-ap*` port (`scripts/41-ap-isolate`) separates
   2.4 GHz clients from 5 GHz clients. Both BSS land in the same bridge, and `ap_isolate`
   knows nothing about the other radio.

This `hostapd` build has **no WNM**: `bss_transition=1` makes hostapd refuse to start
("unknown configuration item") and both radios end up on channel 0 / 0 dBm. Band steering
is left to the client (802.11k only). Real steering would need `wpad-mbedtls` (full) +
`usteer`, which is not installed because it was not needed.

**Mixed bands do not cost throughput.** The MT7615E is DBDC: each band has its own radio and
antennas, so 2.4 GHz does not take airtime from 5 GHz. A/B on the same phone, same spot
(Cloudflare, Mbps):

| Test | Setup | Down / up | Client |
|------|-------|-----------|--------|
| A | 2.4 + 5 GHz, same SSID | 82.5 / 17.8 | 5 GHz, -30 dBm, VHT-MCS9 2x2 866.7 |
| B | 5 GHz only | 89.5 / 18.8 | 5 GHz, -28 dBm, 866.7 |
| A2 | 2.4 + 5 GHz, same SSID | 92.1 / 18.1 | 5 GHz, -29 dBm, 866.7 |

The spread is LTE variance (82-92 Mbps on the router itself), not Wi-Fi. What *does* cost
speed is a client on 2.4 GHz (HT20 ≈ 40-70 Mbps real, below the LTE).
`scripts/wifi-log.sh` (cron, every minute) records band, signal and bitrate per client in
`/tmp/wifi-clients.log` to catch that.

## APN, MTU and MSS

The PDP MTU is **1400** with DIGI and **1456** with NOS/WOO (`uqmi --get-current-settings`).
With `wwan0` left at 1500 and `mtu_fix 0`, full-size packets do not fit the bearer and
upload suffers. Validated config (DIGI, EG06ELAR03A07M4G, 25.12.6, survives `ifdown/ifup`
and a cold boot):

| Setting | Value | Why |
|---------|-------|-----|
| `network.wan.apn` | `internet` | Official DIGI APN (NOS/WOO: `umts`) |
| `network.wan.mtu` | `1400` | Equals the PDP MTU; `wwan0` comes up at 1400 |
| `network.wan.auto` | `1` | netifd brings LTE up at boot; the watchdog is the backup |
| `wan` zone `mtu_fix` | `1` | MSS = route MTU - 40 = 1360, both directions |
| `loja` zone `mtu_fix` | `0` | Not needed: clamping happens on the `wan` zone |

Effect, same place, same SIM (router-local, Cloudflare):

| | Before (`apn ''`, `mtu 1500`, `mtu_fix 0`) | After |
|---|---|---|
| Download | 84-91 Mbps | 83-92 Mbps |
| Upload | 7.8 Mbps | **15-19 Mbps** |
| Ping | 43 ms avg, 158 ms max | 36 ms avg |

If a different modem firmware hangs with `mtu` set, fall back to `mtu_fix 1` alone.

## Watchdog

`scripts/wan-up.sh` runs every minute from cron, and once from a net hotplug when `wwan0`
appears. It is locked with `/tmp/wan-up.lock` and logs state transitions to `/root/wan.log`.
It does nothing during the first 150 s of uptime: netifd is still bringing QMI up then, and
a `killall uqmi` in the middle of that is pitfall 2 below.

```
ping -I wwan0 1.1.1.1 ok?               -> exit
killall uqmi; uqmi --sync; ifup wan     -> check again after 25 s
not registered?                          -> leave it alone (SIM/coverage), retry next minute
registered but no data?                  -> AT+CFUN=1,1 on /dev/ttyUSB2, wait 60 s, sync, ifup
```

`/etc/rc.local` raises the modem power GPIO (`power_modem`) once. OpenWrt leaves it at 0 at
boot, and without it the modem never enumerates.

Measured: a deliberate `ifdown wan` recovered in about 70 s. A cold boot reaches SSH in 61 s
and LTE with an IPv4 address in **97 s**, unattended.

## Measurements

DIGI, after the APN/MTU fix (2026-11-05):

| Metric | Value |
|--------|-------|
| Signal | RSRP -88..-91 dBm, RSRQ -9..-14, SINR 16-23 dB |
| Carriers | B3 10 MHz (PCC) + B7 10 MHz (SCC), CA active |
| Download | 83-92 Mbps router-local; 82.5-92.1 from a 5 GHz phone |
| Upload | 15-19 Mbps |
| Ping | ~36 ms |
| CPU | 91% idle during download (the MT7621 is not the bottleneck) |

DIGI was chosen over WOO/NOS (same box, same place) for carrier aggregation, stable download
and low jitter. Audio to speakers is downlink and jitter-sensitive. Full comparison in
[NOTES-pt.md](NOTES-pt.md).

The modem is Cat 6 (2 DL carriers max, 1 UL carrier) and the local cell offers B3 + B7 at
10 MHz each: ≈150 Mbps PHY peak down and ≈50 up. 83-92 / 15-19 of real TCP on a shared cell
is the practical ceiling. More needs wider carriers or a 5G CPE: radio, not configuration.
Band locking does not help, because the neighbour cells are weaker.

`scripts/irq-spread.sh` (from `rc.local`) pins ethernet → CPU0, xhci (modem) → CPU1 and
Wi-Fi → CPU2. By default all three were on CPU0. `packet_steering 1` stays on.

## Pitfalls

1. **`uci set network.lan.ipaddr='192.168.3.1'` without a netmask yields `/32`.** There is no
   route back to the LAN, so the router receives SYNs and cannot answer them. Only port 22
   kept working, because dropbear was bound to `br-lan` (SO_BINDTODEVICE) and uhttpd was
   not. Always write the mask, or use `ipaddr='192.168.3.1/24'`.
2. **QMI hangs when `ifup wan` runs before the SIM is ready**: `Waiting for SIM
   initialization` → `Request timed out` → `SIM in illegal state - Power-cycling SIM` →
   `Failed to connect to service`. `uqmi` clients stay wedged and netifd blocks. The way
   out is `killall uqmi` + `--sync` + `ifup` in the background, and `AT+CFUN=1,1` only when
   the modem is registered but has no data.
3. **`/etc/init.d/network reload` kills dropbear.** Port 22 closes while LuCI (80/443) stays
   up. Recover with a reboot or *System → Startup → dropbear → Restart*.
4. **The LuCI write path sets `dropbear -l br-lan`.** When the LAN address changes, the bind
   can leave no listener: port 22 answers with a RST even though procd says the instance is
   running.
5. **There is no `opkg`** in 25.12; it is `apk`. `uqmi` is already in the image.
6. **`timeout` does not exist** in this busybox. Wrap long commands with a background
   process plus `kill`, or a hung `uqmi` takes the SSH session with it (`scripts/uq`).
7. **Outbound HTTP from the initramfs returns EPERM.** Transfer files over SSH while
   flashing. The installed system downloads normally.
8. **Set the operator APN explicitly.** The OpenWrt QMI profile has an empty APN. DIGI
   happens to work with `''`, but use the official `internet`. NOS/WOO needs `umts`.
9. **`bss_transition` / `wnm_sleep_mode` take both radios down** with `wpad-basic-mbedtls`
   ("unknown configuration item"). `wifi reload` does not recover until they are removed.
10. **The stock web UI is AES+RSA encrypted** and its `cgi-exec` allows only a short list of
    commands. `ubus` over HTTP logs in but denies `uci`/`rc`/`system` for that session.
    Plan on SSH, not on web UI automation.

## Repository Structure

```
zyxel-lte3301-plus-openwrt/
  config/
    uci-export.txt        uci export of the running box (Wi-Fi PSK redacted)
    rc.local-e-cron.txt   rc.local, crontab, sysupgrade.conf
  scripts/
    install-router.sh     push everything and apply uci + cron, idempotent
    wan-up.sh             LTE watchdog
    30-wwan-ifup          hotplug: modem appeared
    41-ap-isolate         hotplug: bridge port isolation for the AP ports
    irq-spread.sh         IRQ affinity (ethernet/modem/Wi-Fi on separate CPUs)
    wifi-log.sh           per-client band/signal/bitrate log (cron, /tmp)
    siglog.sh             LTE signal sampler (siglog.sh <samples> <seconds>)
    uq                    uqmi with a 12 s timeout
  firmware/
    sha256sums            image hashes (binaries are git-ignored)
  NOTES-pt.md             full lab notes (Portuguese)
```

## Prerequisites

- A Zyxel LTE3301-PLUS (not M209/M904)
- The two OpenWrt 25.12.6 images above, checked against `firmware/sha256sums`
- An ed25519 SSH key installed on the router before running the installer
- A SIM with data, and its APN and PDP MTU

## License

This project is under the MIT License. See the [LICENSE](LICENSE) file for details.
