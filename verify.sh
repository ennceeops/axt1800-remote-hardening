#!/bin/sh
#
# verify.sh - read-only posture report for a GL.iNet travel router
#
# Changes nothing. Safe to run any time, including remotely.
#
#   scp -O verify.sh root@<router>:/tmp/
#   ssh root@<router> "sh /tmp/verify.sh"
#
# Reports what the device is actually doing, not what it is
# configured to do. Several checks below exist because config
# state and behaviour diverged during a real build.
#
# License: MIT. See LICENSE.
#
# Provided as is, without warranty. This script modifies network and
# firewall configuration on a live device. Read it before running it.
#

set -u

RED=""; GRN=""; YEL=""; RST=""
if [ -t 1 ]; then
	RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
	YEL="$(printf '\033[33m')"; RST="$(printf '\033[0m')"
fi

hdr()  { printf '\n%s=== %s ===%s\n' "$GRN" "$*" "$RST"; }
pass() { printf '  %s[PASS]%s %s\n' "$GRN" "$RST" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YEL" "$RST" "$*"; }
note() { printf '  %s\n' "$*"; }

# ------------------------------------------------------------

hdr "SYSTEM"
note "hostname:  $(cat /proc/sys/kernel/hostname)"
[ -f /etc/glversion ] && note "gl fw:     $(cat /etc/glversion)"
[ -f /etc/openwrt_release ] && \
	note "openwrt:   $(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d= -f2 | tr -d \')"
note "uptime:    $(uptime | sed 's/^ *//')"

if command -v fw4 >/dev/null 2>&1; then
	note "firewall:  fw4 / nftables"
else
	note "firewall:  fw3 / iptables"
fi

# ------------------------------------------------------------

hdr "IPv6"

A="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '?')"
D="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo '?')"

[ "$A" = "1" ] && pass "all.disable_ipv6 = 1"     || fail "all.disable_ipv6 = $A"
[ "$D" = "1" ] && pass "default.disable_ipv6 = 1" || fail "default.disable_ipv6 = $D"

# The vendor drop-in enables IPv6 despite its filename, and
# sysctl.d loads after sysctl.conf. If your override does not
# sort after it, IPv6 comes back at every boot.
if [ -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
	if grep -q 'disable_ipv6=0' /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null; then
		LAST="$(ls /etc/sysctl.d/ 2>/dev/null | sort | tail -1)"
		if [ "$LAST" = "99-disable-ipv6.conf" ]; then
			fail "vendor 99-disable-ipv6.conf sets disable_ipv6=0 and sorts LAST"
			fail "  IPv6 will be re-enabled at next boot"
		else
			pass "vendor file overridden by $LAST"
		fi
	fi
fi

V6ADDR="$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6' || true)"
[ "$V6ADDR" = "0" ] && pass "no global IPv6 addresses assigned" \
                    || warn "$V6ADDR global IPv6 address(es) present"

# ------------------------------------------------------------

hdr "INTERFACES"
ip -br addr 2>/dev/null | grep -vE '^(gre|erspan|ip6tnl|sit)' | while read -r l; do
	note "$l"
done

# ------------------------------------------------------------

hdr "VPN TUNNEL"

TUN="$(ip -br link 2>/dev/null | awk '/^(wg|tun|tap)/ {print $1}' | head -5)"

if [ -z "$TUN" ]; then
	fail "no tunnel interface present - traffic is unencrypted"
else
	for t in $TUN; do
		A="$(ip -4 addr show dev "$t" 2>/dev/null | awk '/inet /{print $2}')"
		[ -n "$A" ] && pass "$t up, address $A" || warn "$t exists but has no address"
	done
fi

if command -v wg >/dev/null 2>&1 && wg show 2>/dev/null | grep -q interface; then
	HS="$(wg show 2>/dev/null | grep 'latest handshake' | head -1 | cut -d: -f2- | sed 's/^ *//')"
	TX="$(wg show 2>/dev/null | grep 'transfer' | head -1 | cut -d: -f2- | sed 's/^ *//')"
	if [ -n "$HS" ]; then
		pass "handshake: $HS"
		note "transfer:  $TX"
	else
		# An interface with an address and no handshake is dead.
		# It looks identical to a working one in `ip addr`.
		fail "wireguard interface exists but has never handshaked"
	fi
fi

# OpenVPN auth failures are the most common silent fault. The client
# retries forever and traffic falls through to clear. No symptom.
if logread 2>/dev/null | grep -q 'AUTH_FAILED'; then
	fail "AUTH_FAILED in log. This tunnel is not carrying traffic."
	note "    check, in order:"
	note "      1. concurrent session limit for the plan. exceeding it"
	note "         returns AUTH_FAILED, same as a bad password"
	note "      2. credential set. service credentials are separate from"
	note "         the account you log into the provider site with"
	note "      3. re-enter the credentials by hand even if they look"
	note "         right. a corrupted stored value looks identical"
	note "      4. config file age. providers retire old formats. an"
	note "         archived config fails with no useful error and"
	note "         re-entering credentials will not fix it"
	note "      5. recent account password change"
	note "      6. recent firmware update. vendor upgrades can regenerate"
	note "         config sections. the profile survives, the stored"
	note "         credential does not. re-verify after every upgrade"
	logread 2>/dev/null | grep 'AUTH_FAILED' | tail -2 | while read -r l; do
		note "    $l"
	done
fi

# ------------------------------------------------------------

hdr "ROUTING POLICY"

if ip rule show 2>/dev/null | grep -q blackhole; then
	warn "blackhole rules present in policy table:"
	ip rule show 2>/dev/null | grep blackhole | while read -r l; do note "    $l"; done
	note ""
	note "  These are kill-switch rules. They may be inert depending on"
	note "  failover settings. Test rather than assume: disable every"
	note "  tunnel and confirm a page still loads. If it hangs, the kill"
	note "  switch is live and captive portals will deadlock."
else
	pass "no blackhole rules in policy table"
fi

# ------------------------------------------------------------

hdr "WIRELESS"

if command -v iwinfo >/dev/null 2>&1; then
	iwinfo 2>/dev/null | grep -E '^[a-z0-9-]+ +ESSID|Encryption:' | \
	while read -r l; do note "$l"; done
fi

note ""
for sec in $(uci show wireless 2>/dev/null \
             | sed -n 's/^wireless\.\([a-zA-Z0-9_]*\)=wifi-iface$/\1/p'); do
	mode="$(uci -q get "wireless.$sec.mode" || echo '')"
	[ "$mode" = "ap" ] || continue
	iso="$(uci -q get "wireless.$sec.isolate" || echo '0')"
	enc="$(uci -q get "wireless.$sec.encryption" || echo '?')"
	net="$(uci -q get "wireless.$sec.network" || echo '?')"
	wds="$(uci -q get "wireless.$sec.wds" || echo '0')"

	if [ "$iso" = "1" ]; then
		pass "$sec (net=$net enc=$enc) isolation on"
	else
		warn "$sec (net=$net enc=$enc) isolation OFF"
	fi
	[ "$wds" = "1" ] && note "    wds enabled - on some drivers WDS peers bypass isolation"

	case "$enc" in
		psk|psk2|wep*|none) warn "    weak or absent encryption: $enc" ;;
	esac
done

note ""
note "  Config state is not proof. Verify isolation by pinging a client"
note "  FROM the router first to confirm it is live, then from a second"
note "  client. Router reaches it and client cannot means isolation works."

# ------------------------------------------------------------

hdr "FIREWALL"

DEF="$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([a-zA-Z0-9_]*\)=defaults$/\1/p' | head -1)"
if [ -n "$DEF" ]; then
	for k in input output forward syn_flood drop_invalid; do
		v="$(uci -q get "firewall.$DEF.$k" || echo 'unset')"
		case "$k:$v" in
			syn_flood:1|drop_invalid:1) pass "$k = $v" ;;
			syn_flood:*|drop_invalid:*) warn "$k = $v" ;;
			*) note "$k = $v" ;;
		esac
	done
fi

note ""
uci show firewall 2>/dev/null | grep -E "=zone$" | sed 's/=zone$//' | while read -r zs; do
	n="$(uci -q get "$zs.name" || echo '?')"
	i="$(uci -q get "$zs.input" || echo '?')"
	f="$(uci -q get "$zs.forward" || echo '?')"
	note "zone $n: input=$i forward=$f"
done

# ------------------------------------------------------------

hdr "MANAGEMENT EXPOSURE"

PA="$(uci -q get dropbear.@dropbear[0].PasswordAuth || echo '?')"
IF="$(uci -q get dropbear.@dropbear[0].Interface || echo 'all')"
PT="$(uci -q get dropbear.@dropbear[0].Port || echo '22')"

note "dropbear: port=$PT interface=$IF passwordauth=$PA"
[ "$PA" = "off" ] && pass "password auth disabled" \
                  || warn "password auth enabled - key-only auth needs physical access to set up safely"
[ "$IF" = "all" ] && warn "dropbear not bound to an interface" \
                  || pass "dropbear bound to $IF"

for svc in gl_cloud goodcloud; do
	v="$(uci -q get "glconfig.general.$svc" 2>/dev/null || echo '')"
	[ -n "$v" ] && note "$svc = $v"
done
note ""
note "  Vendor cloud management egresses outside the tunnel. Fine as a"
note "  deliberate, time-boxed choice. Unbind when it is no longer needed."

# ------------------------------------------------------------

hdr "CLIENTS"

if [ -f /tmp/dhcp.leases ]; then
	C="$(wc -l < /tmp/dhcp.leases)"
	note "$C lease(s) in /tmp/dhcp.leases"
	awk '{print "    " $3 "  " $4}' /tmp/dhcp.leases
	note ""
	note "  Leases from a previous subnet persist here until reboot."
	note "  The admin panel client list will look empty when isolation"
	note "  is on. That is expected, not a fault."
else
	note "no lease file"
fi

# ------------------------------------------------------------

hdr "PERSISTENCE"

# Firmware upgrades can regenerate config. Keep-settings preserves
# the files in sysupgrade.conf plus a default set, which may not
# include vendor additions or your own drop-ins.
note "Files this build depends on. Confirm each survives any firmware"
note "upgrade, and re-verify the tunnel afterwards rather than assuming."
for f in /etc/sysctl.d/99-zz-disable-ipv6-hardened.conf \
         /etc/config/network /etc/config/wireless \
         /etc/config/firewall /etc/config/dhcp; do
	[ -e "$f" ] && note "  present: $f" || warn "  MISSING: $f"
done
[ -d /etc/openvpn ] && note "  present: /etc/openvpn/ ($(ls /etc/openvpn 2>/dev/null | wc -l) file(s))"

if [ -f /etc/sysupgrade.conf ]; then
	N="$(grep -cvE '^\s*(#|$)' /etc/sysupgrade.conf 2>/dev/null || echo 0)"
	note "  /etc/sysupgrade.conf lists $N extra path(s) for preservation"
fi
note ""
note "  Everything above lives in the overlay. It survives reboot. It"
note "  does not survive sysupgrade without keep-settings, and what"
note "  keep-settings actually covers is worth testing on your own"
note "  hardware rather than trusting."

hdr "CONTROLS ABSENT BY DESIGN IN A REMOTE BUILD"
note "If this device was hardened without physical access, the"
note "following are expected to be missing. Confirm they are on a"
note "deferred list rather than simply forgotten:"
note "  - dropbear key-only auth, LAN binding, non-default port"
note "  - multi-zone segmentation with a portal-tolerant zone"
note "  - kill switch (requires the above to be safe)"
note "  - global firewall input drop"

hdr "NOT CHECKED HERE"
note "These need a client device and cannot be done from the router:"
note "  - public exit address, with the client's own VPN off"
note "  - DNS leak"
note "  - guest zone cannot reach the admin panel"
note "  - captive portal login, against a real venue portal"
note "  - fail-open behaviour with every tunnel disabled"
printf '\n'
