2026-11-05 clean: scripts/install-router.sh:8 — the installer needs an SSH key: step 5 sets dropbear PasswordAuth off, so password login stops working after the first run
2026-11-05 clean: scripts/install-router.sh:16 — APN is carrier-specific: DIGI uses internet, NOS/WOO uses umts
2026-11-05 clean: scripts/install-router.sh:17 — PDP MTU is carrier-specific: DIGI 1400, NOS/WOO 1456; read it with uqmi --get-current-settings
2026-11-05 clean: scripts/install-router.sh:22 — run blocks are single-quoted and expanded on the router, so local variables reach them only through VARS
2026-11-05 clean: scripts/install-router.sh:75 — the box has no odhcpd, so the lan DHCPv6/RA options are deleted and IPv6 stays off
2026-11-05 clean: scripts/install-router.sh:82 — mtu_fix on firewall.@zone[1] (the wan zone) clamps MSS to route MTU minus 40 (1360) in both directions
2026-11-05 clean: scripts/wan-up.sh:2 — no GPIO toggling here (that is an LBR20 mechanism); modem recovery is AT+CFUN=1,1 on ttyUSB2 plus ifup only
2026-11-05 clean: scripts/wan-up.sh:7 — with wan auto=1, netifd still brings QMI up during the first 150 s of uptime, so the watchdog exits early then; a killall uqmi in that window wedges QMI
2026-11-05 clean: config/rc.local-e-cron.txt:5 — GPIO 27 (power_modem) is 0 after an OpenWrt boot; rc.local sets it to 1, otherwise the modem never enumerates
2026-11-05 clean: README.md:106 — sysupgrade -n drops the SSH session with rc=246; that is the expected disconnect, not an error; port 22 returns about 80 s later
2026-11-05 clean: NOTES-pt.md:222 — busybox on this build has no timeout; wrap uq calls in a background process with kill
2026-11-05 clean: NOTES-pt.md:227 — the AT port echoes line noise, so read the reply from a file
