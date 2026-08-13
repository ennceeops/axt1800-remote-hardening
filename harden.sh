#!/bin/sh
#
# harden.sh - GL.iNet travel router hardening
#
# Runs ON the router. Copy it across and execute, or pipe it in:
#   scp -O harden.sh root@<router>:/tmp/
#   ssh root@<router> "sh /tmp/harden.sh"
#
# Tested on GL firmware 4.8.x / OpenWrt 23.05 (fw4/nftables).
# Read the whole thing before running it.
#
# License: MIT. See LICENSE.
#
# Provided as is, without warranty. This script modifies network and
# firewall configuration on a live device. Read it before running it.
#

set -u

# ============================================================
#  CONFIGURATION - edit these
# ============================================================

LAN_IP="192.168.20.1"
GUEST_IP="192.168.30.1"

SSID_LAN="Main-SSID"
SSID_GUEST="Guest-SSID"

# Keys are NOT set here. The script prompts for them, so they
# never end up in your shell history or in this file.
# Set SKIP_KEYS=1 to leave existing keys untouched.
SKIP_KEYS=0

# ============================================================
#  SAFETY FLAGS
# ============================================================

# REMOTE=1 skips everything that can sever your own access.
# Set this if you are not physically next to the router.
# Specifically it skips the LAN address change, which is the
# one thing a config backup cannot rescue you from.
REMOTE=1

# DRY_RUN=1 prints what would happen and changes nothing.
DRY_RUN=0

# APPLY=0 stages and commits config but does not reload the
# network. Nothing takes effect until you reload manually or
# reboot. Leave at 0 if you are remote.
APPLY=0

# ============================================================

RED=""; GRN=""; YEL=""; RST=""
if [ -t 1 ]; then
	RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
	YEL="$(printf '\033[33m')"; RST="$(printf '\033[0m')"
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*"; exit 1; }

run() {
	if [ "$DRY_RUN" = "1" ]; then
		printf '    would run: %s\n' "$*"
	else
		"$@"
	fi
}

# ------------------------------------------------------------
#  Preflight
# ------------------------------------------------------------

[ "$(id -u)" = "0" ] || die "must run as root"
command -v uci >/dev/null 2>&1 || die "uci not found - is this OpenWrt?"

info "Router: $(cat /proc/sys/kernel/hostname)"
[ -f /etc/glversion ] && info "GL firmware: $(cat /etc/glversion)"
[ -f /etc/openwrt_release ] && info "$(grep DISTRIB_DESCRIPTION /etc/openwrt_release | cut -d= -f2 | tr -d \')"
say ""

if [ "$DRY_RUN" = "1" ]; then
	warn "DRY RUN - nothing will be changed"
	say ""
fi

if [ "$REMOTE" = "1" ]; then
	warn "REMOTE mode. Skipping:"
	warn "  - LAN address change (can lock you out with no recovery)"
	say ""
fi

warn "THIS IS A REDUCED BUILD."
warn ""
warn "The following are NOT applied. Each would sever access to a"
warn "remotely-managed router with no recovery path. None of them"
warn "are optional in a full build:"
warn "  - dropbear hardening (key auth, LAN bind, password auth off)"
warn "  - multi-zone segmentation with a portal-tolerant zone"
warn "  - kill switch (deadlocks captive portals without that zone)"
warn "  - global firewall input policy drop"
warn "  - firmware upgrade"
warn ""
warn "If the device is in front of you, do those too. If it is not,"
warn "record the gap in your handoff rather than calling this done."
say ""

if [ "$DRY_RUN" != "1" ]; then
	printf 'Continue? [y/N] '
	read -r ans
	case "$ans" in
		y|Y|yes|YES) ;;
		*) die "aborted" ;;
	esac
	say ""
fi

# ------------------------------------------------------------
#  Backup first. Always.
# ------------------------------------------------------------

BACKUP="/root/pre-harden-$(date +%Y%m%d-%H%M%S).tar.gz"
info "Backing up to $BACKUP"
if [ "$DRY_RUN" != "1" ]; then
	sysupgrade -b "$BACKUP" >/dev/null 2>&1 || die "backup failed, refusing to continue"
	[ -s "$BACKUP" ] || die "backup file is empty, refusing to continue"
	info "  $(ls -lh "$BACKUP" | awk '{print $5}')"
	warn "  /root survives reboot but NOT sysupgrade or factory reset."
	warn "  Get this file off the device."
	warn "  It contains /etc/shadow - restoring reverts the admin password."
fi
say ""

# ------------------------------------------------------------
#  1. IPv6
# ------------------------------------------------------------

info "Disabling IPv6 at kernel level"
run sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
run sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null

# Vendor ships /etc/sysctl.d/99-disable-ipv6.conf which, despite
# the name, sets disable_ipv6=0. sysctl.d loads after sysctl.conf,
# so appending to sysctl.conf gets silently overridden at boot.
# Use a higher-sorting drop-in instead. Do not edit the vendor
# file, it gets regenerated.
DROPIN="/etc/sysctl.d/99-zz-disable-ipv6-hardened.conf"
info "Writing persistent drop-in: $DROPIN"
if [ "$DRY_RUN" != "1" ]; then
	cat > "$DROPIN" <<-'EOF'
	net.ipv6.conf.all.disable_ipv6=1
	net.ipv6.conf.default.disable_ipv6=1
	net.ipv6.conf.lo.disable_ipv6=1
	EOF
	[ -s "$DROPIN" ] || die "drop-in write failed"
fi

info "Disabling IPv6 interfaces in UCI"
for i in wan6 wwan6 tethering6; do
	if uci -q get "network.$i" >/dev/null 2>&1; then
		run uci set "network.$i.disabled=1"
	fi
done

run uci set network.globals.ula_prefix=''
uci -q get network.lan.ip6assign   >/dev/null 2>&1 && run uci delete network.lan.ip6assign
uci -q get network.guest.ip6assign >/dev/null 2>&1 && run uci delete network.guest.ip6assign

# Stale IPv6 DNS advertisements point at addresses that no longer
# exist. Clients time out on them before falling back to v4.
uci -q get dhcp.lan.dns   >/dev/null 2>&1 && run uci delete dhcp.lan.dns
uci -q get dhcp.guest.dns >/dev/null 2>&1 && run uci delete dhcp.guest.dns

run uci commit network
run uci commit dhcp
say ""

# ------------------------------------------------------------
#  2. Hostname suppression
# ------------------------------------------------------------

# The repeater interface announces the system hostname to every
# network joined, disclosing the router model. Setting a uci
# option to empty removes it entirely, which is what we want.
info "Suppressing DHCP hostname on repeater interface"
if uci -q get network.wwan >/dev/null 2>&1; then
	run uci set network.wwan.hostname=''
	run uci commit network
else
	warn "  no wwan interface found, skipping"
fi
say ""

# ------------------------------------------------------------
#  3. Wireless
# ------------------------------------------------------------

# Enumerate AP sections rather than assuming indices. Section
# names map to hardware, not zones, and the count varies by
# model. Hardcoding wifi-iface[0..5] breaks on two-radio devices.
info "Enumerating wireless AP interfaces"

AP_SECTIONS=""
for sec in $(uci show wireless 2>/dev/null \
             | sed -n 's/^wireless\.\([a-zA-Z0-9_]*\)=wifi-iface$/\1/p'); do
	mode="$(uci -q get "wireless.$sec.mode" || echo '')"
	[ "$mode" = "ap" ] || continue
	AP_SECTIONS="$AP_SECTIONS $sec"
	net="$(uci -q get "wireless.$sec.network" || echo '?')"
	ssid="$(uci -q get "wireless.$sec.ssid" || echo '?')"
	say "    $sec  network=$net  ssid=$ssid"
done

[ -n "$AP_SECTIONS" ] || die "no AP interfaces found"
say ""

info "Applying encryption and client isolation"
for sec in $AP_SECTIONS; do
	run uci set "wireless.$sec.encryption=sae-mixed"
	run uci set "wireless.$sec.isolate=1"
	run uci set "wireless.$sec.disabled=0"
done

info "Setting SSIDs by zone"
for sec in $AP_SECTIONS; do
	net="$(uci -q get "wireless.$sec.network" || echo '')"
	case "$net" in
		lan)   run uci set "wireless.$sec.ssid=$SSID_LAN"   ;;
		guest) run uci set "wireless.$sec.ssid=$SSID_GUEST" ;;
		*)     warn "  $sec is on network '$net' - not touching SSID" ;;
	esac
done

if [ "$SKIP_KEYS" = "1" ]; then
	warn "SKIP_KEYS set, leaving existing wireless keys alone"
elif [ "$DRY_RUN" = "1" ]; then
	say "    would prompt for wireless keys"
else
	say ""
	info "Wireless keys (input hidden, 20+ chars, avoid ambiguous characters)"
	printf '  LAN key: '   ; stty -echo 2>/dev/null; read -r K_LAN;   stty echo 2>/dev/null; say ""
	printf '  Guest key: ' ; stty -echo 2>/dev/null; read -r K_GUEST; stty echo 2>/dev/null; say ""

	[ ${#K_LAN}   -ge 8 ] || die "LAN key too short"
	[ ${#K_GUEST} -ge 8 ] || die "guest key too short"
	[ "$K_LAN" != "$K_GUEST" ] || die "keys are identical - guest zone provides no credential separation"

	for sec in $AP_SECTIONS; do
		net="$(uci -q get "wireless.$sec.network" || echo '')"
		case "$net" in
			lan)   uci set "wireless.$sec.key=$K_LAN"   ;;
			guest) uci set "wireless.$sec.key=$K_GUEST" ;;
		esac
	done
	unset K_LAN K_GUEST
	info "  keys set"
fi

run uci commit wireless
say ""

# ------------------------------------------------------------
#  4. Guest network
# ------------------------------------------------------------

if uci -q get network.guest >/dev/null 2>&1; then
	info "Configuring guest network: $GUEST_IP"
	run uci set network.guest.ipaddr="$GUEST_IP"
	run uci set network.guest.disabled=0
	# bridge_empty lets the bridge start with no ports attached,
	# which is its state until the APs come up.
	run uci set network.guest.bridge_empty=1
	run uci commit network
else
	warn "No guest interface found. Create it before enabling guest APs,"
	warn "or clients will associate and never receive an address."
fi
say ""

# ------------------------------------------------------------
#  5. Firewall
# ------------------------------------------------------------

info "Firewall defaults"
DEF="$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([a-zA-Z0-9_]*\)=defaults$/\1/p' | head -1)"
if [ -n "$DEF" ]; then
	run uci set "firewall.$DEF.drop_invalid=1"
	run uci set "firewall.$DEF.syn_flood=1"
	run uci commit firewall
	say "    section: $DEF"
else
	warn "  could not locate firewall defaults section"
fi

# Global input drop is correct in principle and the fastest way
# to lock yourself out of a remote device. Not done here.
warn "  global input policy left as-is. Set to drop only with"
warn "  physical access."
say ""

# Verify the guest zone can actually serve DHCP. Its absence is
# the classic 'associates but gets no address' failure.
if uci show firewall 2>/dev/null | grep -q "src='guest'"; then
	if uci show firewall 2>/dev/null | grep -A3 "src='guest'" | grep -q "67-68\|67 68"; then
		info "Guest zone has a DHCP allow rule"
	else
		warn "Guest zone found but no DHCP (UDP 67-68) allow rule visible."
		warn "Clients may associate and never get an address."
	fi
fi
say ""

# ------------------------------------------------------------
#  6. LAN address - gated
# ------------------------------------------------------------

if [ "$REMOTE" = "1" ]; then
	warn "Skipping LAN address change (REMOTE=1)"
	warn "  Current: $(uci -q get network.lan.ipaddr)"
	warn "  Intended: $LAN_IP"
	warn "  Apply this with physical access, wired, not over wifi."
else
	info "Setting LAN address: $LAN_IP"
	warn "  This will drop every client on the LAN."
	run uci set network.lan.ipaddr="$LAN_IP"
	run uci commit network
fi
say ""

# ------------------------------------------------------------
#  Apply
# ------------------------------------------------------------

if [ "$APPLY" = "1" ] && [ "$DRY_RUN" != "1" ]; then
	warn "Reloading network. All wireless clients will drop."
	warn "If you are remote, expect to lose your session."
	sleep 3
	/etc/init.d/network restart
else
	info "Config committed to disk. Nothing has been applied."
	say ""
	say "  To apply:  /etc/init.d/network restart"
	say ""
	warn "  Every wireless client drops and must rejoin with the new"
	warn "  SSIDs and keys. Do this when someone is there to reconnect"
	warn "  them."
fi

say ""
info "Done. Run verify.sh and check the output before trusting any of it."
say ""
warn "Reminder: this is a reduced build. The controls listed at the"
warn "start were not applied. Do not treat this as complete."
