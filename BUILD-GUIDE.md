# Hardened Travel Router Build

Generic build for a GL.iNet travel router on firmware 4.x. Two zones, policy-routed VPN with failover, no kill switch.

Written for a deployment where the operator is non-technical and the device may be configured remotely. If you have physical access and a competent user, build more than this.

Addressing and SSIDs below are placeholders. Substitute your own.

---

## Reduced build. Know what is missing.

Every omission below comes from not having the device present. None were judged unnecessary. Each would sever access to a remotely-managed router with no way back in.

| Control | Why it is not here |
|---|---|
| SSH daemon hardening | Key-only auth, LAN binding, non-default port, password auth off. Any of these kills the channel you are working through. No key, no console, permanent lockout. |
| Multi-zone segmentation | Four zones including a portal-tolerant one. Interface, bridge, DHCP and firewall changes in sequence, each with a failure mode that takes hands-on iteration to find. |
| Kill switch | Falls out of the above. Without the portal-tolerant zone it deadlocks the user at every captive portal. |
| Global firewall input drop | Fastest way to lock yourself out. |
| Firmware upgrade | Only real brick vector on this hardware. Wired, local, before anything else. |

Call it 60 percent of a full build with none of the lockout risk. Correct trade when you cannot reach the device. Wrong trade when you can.

Physical access: the deferred list at the end is your next steps, not optional extras. Remote only: write the gap into your handoff. Do not ship a reduced build as a finished one.

---

## Scope

**In:** IPv6 removal, addressing, wireless, two-zone segmentation, VPN failover, repeater hardening.

**Out:** everything in the table above.

---

## Architecture

```
Client -> Router (LAN or Guest zone) -> Policy routing -> WireGuard (P1) or OpenVPN (P2) -> Provider -> Internet
```

Two tunnel profiles in priority order. WireGuard primary because it is faster and reconnects cleanly when the upstream changes. OpenVPN fallback because it survives in places that fingerprint and block WireGuard.

Use a provider's multi-hop option if they offer one. Entry node in one jurisdiction, exit in another, so no single hop sees both client identity and destination.

---

## Addressing

| Zone | Subnet | Gateway | DHCP | Lease |
|---|---|---|---|---|
| Main LAN | 192.168.20.0/24 | 192.168.20.1 | .100 to .249 | 12h |
| Guest | 192.168.30.0/24 | 192.168.30.1 | .100 to .249 | 12h |

Move off the vendor default. It is the first thing anyone probes.

Avoid these ranges:

- `192.168.0.0/24` and `192.168.1.0/24`. Ubiquitous on hotel and home networks. Guaranteed collision eventually.
- `10.42.0.0/24`. NetworkManager default for Linux shared connections and hotspots.
- `192.168.43.0/24`. Android hotspot default.
- `192.168.137.0/24`. Windows ICS default.

Pick something unusual in the third octet and stay consistent per deployment.

---

## SSID naming

| SSID | Zone | Bands |
|---|---|---|
| Main-SSID | Guest | 2.4 + 5 GHz |
| Guest-SSID | Main LAN | 2.4 + 5 GHz |

Invert the mapping. The names should not describe the zones they serve. Anyone targeting the network that sounds important reaches the guest zone.

Use device-format names rather than anything personal. A printer model, a generic router name, an appliance. Nobody attacks a printer.

Same SSID and key on both bands within a zone so clients roam without a second network entry. Matters if the user is joining by hand.

**Hidden SSIDs:** skip them unless your user can reliably enter a network name manually on every device. The obscurity is defeated by observing probe traffic anyway. The support burden is real.

---

## Pre-build

- Provider VPN config files for the regions you need. **Download them fresh and confirm each one authenticates before you start.** Do not assume a profile works because it worked once. See finding 1 in the README.
- Two random keys, one per zone. 20+ characters, alphanumeric. Avoid symbols and ambiguous characters if the user types them by hand on mobile.
- Admin password, generated and stored.
- Wired connection to a LAN port if you have physical access. Never configure over the wifi you are about to change.
- Firmware current, applied on a wired local session before anything else.

---

## Step 1: IPv6

Kernel first. UCI changes need a network restart, which will drop you if you are remote.

```sh
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

Both must return 1.

Persistence. Do not append to `/etc/sysctl.conf`, it gets overridden. See finding 2.

```sh
cat > /etc/sysctl.d/99-zz-disable-ipv6-hardened.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
```

UCI layer:

```sh
uci set network.wan6.disabled='1'
uci set network.wwan6.disabled='1'
uci set network.tethering6.disabled='1'
uci set network.globals.ula_prefix=''
uci delete network.lan.ip6assign
uci delete network.guest.ip6assign
uci commit network
```

Stale IPv6 DNS advertisements point at addresses that no longer exist. Clients time out on them before falling back. Remove:

```sh
uci delete dhcp.lan.dns
uci delete dhcp.guest.dns
uci commit dhcp
```

Residual `ip6hint`, `ip6class` and odhcpd `ra_*` options can stay. They modify an assignment mechanism that no longer exists on a disabled stack.

---

## Step 2: WAN and repeater

MAC randomisation. Check first, it may already be set.

```sh
uci show network | grep mac_mode
```

Panel: Network, Ethernet Port, MAC Mode Random. Auto Update MAC **By Reboot**, not By Time. By Reboot rotates per location while staying stable within a stay. By Time rotates mid-session and breaks portal authentication.

Hostname suppression. The repeater interface announces the system hostname to every network joined, which discloses the router model.

```sh
uci set network.wwan.hostname=''
uci commit network
```

Note: setting a UCI option to an empty string removes it. A later `uci get` returning "not found" is success.

Repeater settings in the panel, per saved network:

- **Auto-Enable Login Mode for Public Hotspots: ON.** Handles captive portals. Relaxes DNS to the venue resolver during the portal window only. Bounded exposure, and the alternative is a user who cannot get online.
- **Camouflage: ON.** Router presents the DHCP fingerprint of an attached client rather than a router. Reduces fingerprinting, and some venues block routers outright.

These are per saved network, not global. New venues may not inherit them.

---

## Step 3: Addressing

Guest first. It is usually disabled and carries no risk.

```sh
uci set network.guest.ipaddr='192.168.30.1'
uci set network.guest.disabled='0'
uci commit network
```

Confirm `bridge_empty='1'` is present. It lets the bridge come up with no ports attached, which is its state until the APs are enabled. Without it the interface can fail to start.

LAN last:

```sh
uci set network.lan.ipaddr='192.168.20.1'
uci commit network
```

DHCP pools are offsets, not absolute addresses. They follow the interface automatically.

---

## Step 4: Wireless

Enumerate what exists before writing anything:

```sh
uci show wireless | grep -E "ssid|network=|disabled"
```

Section names map to **hardware, not zones**. On a two-radio device `radio0` and `radio1` are the 5 GHz and 2.4 GHz radios. Each hosts one LAN AP and one guest AP. Assuming radio0 is the main network puts the guest key on the main network.

Per AP:

```sh
uci set wireless.<section>.encryption='sae-mixed'
uci set wireless.<section>.isolate='1'
uci set wireless.<section>.ssid='<zone SSID>'
uci set wireless.<section>.key='<zone key>'
uci set wireless.<section>.disabled='0'
uci commit wireless
```

`sae-mixed` gives WPA3 to capable clients and WPA2 fallback to everything else. Pure `sae` with 802.11w Required breaks older devices.

Verify keys without echoing them:

```sh
uci get wireless.<section>.key | wc -c
uci get wireless.<section>.key | md5sum
```

Hashes must differ between zones. Equal character counts do not prove different keys.

Check `random_bssid` is set on both radios. Often already on.

---

## Step 5: Firewall

Guest zone should already exist on GL firmware. Verify rather than build:

```sh
uci show firewall | grep -A8 guest
```

Confirm an `Allow-DHCP` rule permitting UDP 67-68 from the guest zone. Its absence is the classic "device associates but gets no address" failure.

| Zone | Input | Output | Forward |
|---|---|---|---|
| lan | ACCEPT | ACCEPT | ACCEPT |
| guest | REJECT | ACCEPT | REJECT |
| wan | DROP | ACCEPT | REJECT |

Globals:

```sh
uci set firewall.@defaults[0].drop_invalid='1'
uci commit firewall
```

`syn_flood` is usually already on. Check.

Global input drop is correct in principle. Do not do it remotely.

---

## Step 6: VPN

Import both profiles. Structure the policy entries so failover is unambiguous:

| Priority | Profile | From | To | Mode |
|---|---|---|---|---|
| 1 | WireGuard | All Clients | All targets | Failover |
| 2 | OpenVPN | All Clients | All targets | Failover |

Both scoped to All Clients. Mismatched scoping produces behaviour nobody can explain later.

Per-tunnel options:

- **Kill Switch: OFF.** Badge should read Failover. See the kill switch section in the README.
- **Services from GL.iNet Use VPN: OFF** if you are managing the device through the vendor cloud. Routing the management channel through the tunnel means losing access when the tunnel is unstable.
- **Allow Remote Access to LAN Subnet: OFF.**
- **IP Masquerading: ON.**
- **MTU: 1420 for WireGuard.** Leave empty for OpenVPN. Unset MTU on WireGuard over a hotel link produces intermittent large-packet failures that look like "some sites do not load".
- **All Other Traffic: ON.** This is the global setting that permits non-VPN traffic.

Bring up Priority 1 alone first. Confirm it works before adding the second variable.

---

## Step 7: Apply and verify

One network reload applies everything:

```sh
/etc/init.d/network restart
```

This drops all wireless clients. Devices must rejoin with the new SSIDs and keys.

Then run the verification table in the README. All of it. Config state is not evidence.

Minimum:

```sh
ip -br addr          # bridges at new addresses, tunnel interface present, no v6
wg show              # handshake age, transfer counters
iwinfo               # SSIDs, encryption, per band
ip rule show         # policy routing installed
nft list ruleset     # or fw4 status
```

From a client, not the router: public IP check with the client's own VPN disabled and cellular off. The router's own egress often bypasses the tunnel by design and tells you nothing about client protection.

---

## Backup

```sh
sysupgrade -b /root/backup.tar.gz
```

Get it off the device. `/root` survives reboot but not sysupgrade or factory reset.

Take two: one before changes, one after. Label each with the admin password it corresponds to, because restoring reverts `/etc/shadow`.

Retrieval over a cloud relay is painful. LuCI over the local LAN is fast. Have the user do it if they are on site.

---

## Recovery

Failsafe mode and U-Boot web recovery are **ethernet only**. Wi-Fi is not up in either.

If the user travels with phones and tablets only, pack a USB-C to ethernet adapter or these paths do not exist for them.

Pre-stage on their laptop and phone, downloaded and available offline:

- Firmware image for the exact model
- A retrieved config archive
- The admin password

Recovery that needs internet during an outage is not recovery.

The real redundancy is not a backup. It is the user's phone with a VPN app and always-on enabled, which is a working protected hotspot if the router dies.

---

## Known limitations of this build

Document these rather than hiding them.

- **No kill switch.** Traffic falls through to clear if all tunnels fail. Protection relocated to endpoint VPN apps.
- **DNS rebind protection off.** Vendor default. Enabling it breaks captive portals.
- **Login Mode enabled.** DNS reverts to the venue resolver during the portal window.
- **Root SSH with password auth.** Cannot be hardened while a cloud channel is the management path. Mitigated by wan zone input drop.
- **Two zones only.** No work or IoT separation.
- **Global firewall input ACCEPT.** Per-zone policies govern actual traffic.
- **Client list appears empty.** Side effect of isolation. See finding 4.
- **Everything lives in the overlay.** Survives reboot. Does not survive factory reset. Whether it survives a firmware upgrade depends on what "keep settings" actually preserves, which is a file list you have not read. Treat every upgrade as a config change and re-verify afterwards.

---

## Deferred: do these with physical access

Not optional extras. These are the controls a complete build includes and this one does not.

- SSH daemon hardening. Key auth, LAN binding, non-default port, password auth off.
- Global firewall input drop.
- Multi-zone architecture with a portal-tolerant zone, which is the correct fix for the kill switch problem.
- Obfuscated WireGuard for DPI-heavy destinations. Supported by the firmware, needs a self-hosted endpoint since commercial providers do not offer it.

---

## After any firmware upgrade

An upgrade is a config change whether or not you intended one. "Keep settings" preserves the files in `/etc/sysupgrade.conf` plus a default set. Vendor additions and your own drop-ins may or may not be in that list.

Re-run `verify.sh` and check specifically:

- Tunnel authenticates. A profile can survive as a named entry with its stored credential gone. Read the log, do not trust the dashboard.
- IPv6 sysctl still returns 1, and your drop-in still exists and still sorts after the vendor file.
- Client isolation still set on every AP.
- Firewall zones intact.

Then from a client: public IP check with the client's own VPN off.

To find out exactly what your hardware preserves, capture before and after:

```sh
cat /etc/sysupgrade.conf
md5sum /etc/config/* /etc/openvpn/* 2>/dev/null
```

Diff the hashes. Anything changed was regenerated, not preserved.

---

## Do not accept the LuCI ifname migration prompt

Opening Network, Interfaces in LuCI raises a prompt offering to migrate `ifname` options to `device` options and restart the network.

Decline it. GL firmware is a fork. Its own scripts for repeater handling, tethering and VPN orchestration read `ifname` directly in places the vanilla migration does not account for. The tethering interface carries an `ifname` binding and tethering is often the fallback WAN path.

No benefit, real risk.

---

## License

CC BY 4.0. The scripts in this repository are MIT. See `LICENSE`.
