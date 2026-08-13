# Hardening a GL.iNet Travel Router Remotely

Notes from hardening a GL.iNet travel router for a friend traveling internationally. The router was several hundred miles away. He is not technical. There was no console, no serial, and no way to get hands on the device.

Most travel router guides assume you are holding the thing. This one does not.

---

## Read this before you copy anything

**This is not a complete build. It is what can be done safely without physical access.**

Nothing below was skipped because it was judged unnecessary. Each one would have severed the management channel with no way back in. The router was several hundred miles away. No console, no serial, no user who could power cycle on request, and a departure date that ruled out shipping it back.

Not applied:

- **SSH daemon hardening.** Key-only auth, LAN binding, non-default port, password auth off. Any of these kills the channel you are working through. No key installed, no console, permanent lockout.
- **Multi-zone segmentation.** Four zones including a portal-tolerant one. Needs interface, bridge, DHCP and firewall changes in sequence. Every one has a failure mode that takes hands-on iteration to find. Not viable blind.
- **Kill switch.** Falls out of the above. Without the portal-tolerant zone it deadlocks the user at every hotel sign-in page. Not an independent decision.
- **Global firewall input drop.** Fastest way to lock yourself out.

What is left is the subset that is safe to apply blind. Call it 60 percent of a full build with none of the lockout risk. Correct trade when you cannot reach the device. Wrong trade when you can.

Device in front of you: use the deferred list in `BUILD-GUIDE.md` as your starting point. Working remote: write the gap into your own handoff notes. Do not ship a reduced build as a finished one.

---

## 1. OpenVPN auth failures are silent and traffic falls through to clear

The device arrived with its VPN client switched off. Assumption was the owner disabled it to fix a connectivity problem. Wrong. It had been failing authentication:

```
AUTH: Received control message: AUTH_FAILED
SIGTERM[soft,auth-failure] received, process exiting
```

**The failure is invisible.** Internet keeps working. Traffic falls through to clear. No error at the client, no notification, nothing a user would notice. This router had been running unencrypted across various networks for an undetermined stretch.

The owner is not technical. He plugs it in and expects it to work. He had no reason to check the connection every time he joined a new network, and no way to tell the difference if he had. When it stopped working he turned the VPN off to get internet back, which is the reasonable thing to do if you cannot read a log.

### Root cause here: unconfirmed

The config was pulled fresh from the provider nine months before the fault was found, and the tunnel was verified working at build time. Re-entering the same credentials from the account page fixed it. No new credentials were requested. So the credentials were valid the whole time and the router was sending something wrong.

It worked at build time, so the fault developed later without user action. Most likely candidate is a firmware update regenerating the profile section, leaving the named entry intact and the stored credential not. Not proven. Router logs are a RAM ring buffer and were long overwritten by the time anyone looked.

### Causes to check, in order

**Concurrent session limit.** Every provider caps simultaneous connections per plan. Exceed it and you get AUTH_FAILED, identical to a bad password. Easy to hit when apps on phones and laptops hold sessions the router is competing with.

**Credential set.** Configs using `auth-user-pass` authenticate against service credentials, not the account you log into the provider site with. Most providers issue a separate username and password.

**Stored value corruption.** Re-enter the credentials by hand even if you believe they are correct. Costs nothing and it is what fixed this one.

**Retired config format.** Providers deprecate old configs on security grounds. Proton set a hard cutoff of 28 February 2026 for manual OpenVPN configs downloaded before September 2023, moving to AES-256-GCM and TLS-Crypt. App users unaffected, router and third-party setups broke. Re-entering credentials does not fix this. Check the file's age and download a fresh one.

**Account password change.** Can invalidate service credentials depending on the provider.

**Firmware update.** Vendor firmware can regenerate config sections during an upgrade. A profile survives as a named entry while the stored credential is dropped or mangled. Everything looks configured. Nothing authenticates. "Keep settings" on an upgrade preserves the files in `/etc/sysupgrade.conf` plus a default set, and whether vendor additions like VPN credential files are in that list is not obvious from the UI. Assume nothing survived until you have re-verified it.

### Checking it

Read the log. Do not trust the dashboard, a client in a retry loop shows "connecting" indefinitely.

```sh
logread | grep -i "auth\|vpn"
```

Do not assume a disabled VPN was a deliberate choice. Here it was a symptom nobody had diagnosed.

WireGuard does not have this failure mode. Keypair auth fails at handshake rather than after connection, and there is no username or password to store wrong. Prefer it as primary where the destination allows.

## 2. `99-disable-ipv6.conf` enables IPv6

GL firmware ships a file at `/etc/sysctl.d/99-disable-ipv6.conf`. Contents:

```
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.accept_ra=2
```

The name describes the admin panel toggle that writes it. Not the contents.

`sysctl.d` loads after `sysctl.conf`. The file sorts at 99. So appending your IPv6 settings to `/etc/sysctl.conf` gets silently overridden at every boot.

**Fix:** use a higher-sorting drop-in. Do not edit the vendor file, it gets regenerated.

```sh
cat > /etc/sysctl.d/99-zz-disable-ipv6-hardened.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
```

Verify after a reboot, not before. `sysctl net.ipv6.conf.all.disable_ipv6` must return 1.

---

## 3. GL firmware 4.x has no config backup in the admin panel

The System menu in 4.x contains Overview, Admin Password, Upgrade, Scheduled Tasks, Display Management, USB and Power, Time Zone, Toggle Button, Security, Reset Firmware, Log, Advanced Settings, Language, Help.

No Backup entry. The Upgrade page is firmware only. Reset Firmware is a single destructive button.

Backup is available two ways:

```sh
# SSH
sysupgrade -b /root/backup.tar.gz
```

Or LuCI: System, Backup / Flash Firmware, Generate archive.

This changed from 3.x. If you are writing instructions for someone else to follow, they will not find it where you expect.

Two related traps:

- `/tmp` is tmpfs. A backup written there is gone on reboot. Write to `/root`, then get it off the device.
- The archive contains `/etc/shadow`. Restoring it reverts the admin password to whatever it was when the archive was taken. Label every archive with the credential it matches.

---

## 4. Client isolation breaks the GL client list

Enable AP isolation and the Clients page in the admin panel goes empty. Devices are connected, have addresses, have internet. The page shows nothing.

Not a bug. The panel correlates DHCP leases against ARP and bridge forwarding state to decide what is "present". Isolation suppresses the layer 2 visibility that depends on.

```
192.168.20.103 lladdr aa:bb:cc:11:22:33 REACHABLE
192.168.20.162 INCOMPLETE
192.168.20.245 FAILED
```

Wireless power save compounds it. Idle devices stop answering ARP entirely.

Use the lease file instead:

```sh
cat /tmp/dhcp.leases
```

Do not disable isolation to get a UI list back. Tell the user the page is expected to be empty, or they will report it as broken.

---

## 5. Testing client isolation is easy to get wrong

Two false results hit during verification.

**The laptop pinged itself.** The target address turned out to be the laptop's own. It replied instantly from its own stack without touching the network. Looked like isolation had failed.

**A stale lease.** Another target was a lease from the previous subnet. Unreachable from everywhere. Looked like isolation was working.

Valid method:

1. Confirm the target is live by pinging it **from the router**. The router sits above isolation and will get replies.
2. Then ping the same target from another client.
3. Router reaches it, client cannot: isolation is enforcing.

Check `ipconfig` or `ip addr` on the source machine before trusting any result. Old leases persist in `/tmp/dhcp.leases` after a subnet change until reboot.

Worth noting: WDS is enabled by default on GL AP interfaces. On some drivers WDS peers bypass isolation. It did not on this hardware. Test rather than assume.

---

## Remote work: what is safe and what will strand you

The device was managed through the vendor cloud console. Roughly five minute idle timeout on the web terminal.

**Never remotely:**

- SSH daemon hardening. Binding dropbear to LAN, changing the port, or disabling password auth kills your own access. No key installed, no console, permanent lockout.
- Firmware upgrade. Only real brick vector on this hardware.
- Anything touching `network.lan`. Address, netmask, DHCP range, admin access restrictions. This is the one category a config backup cannot save you from, because restoring requires reaching the admin panel.
- Global firewall input policy set to drop.

**Safe:**

- `sysctl` changes. Take effect immediately, no service restart.
- `uci set` and `uci commit`. Writes config, does not reload anything.
- Read-only inspection.

**Working pattern**, given the timeout:

```
set -> uci show to verify -> commit -> grep the file on disk
```

Never leave changes staged across a pause. Staging lives in tmpfs and a dropped session can lose it.

For anything genuinely risky, arm a rollback first:

```sh
sysupgrade -b /root/pre.tar.gz
(sleep 600 && sysupgrade -r /root/pre.tar.gz && reboot) &
echo $! > /tmp/rollback.pid
# verify the change and that your session is alive, then:
kill $(cat /tmp/rollback.pid)
```

Costs thirty seconds. Turns a lockout into a ten minute wait.

---

## Kill switch versus captive portals

Standard advice is enable the kill switch. On a single-LAN travel router that is wrong.

The kill switch drops all traffic before the tunnel is up. That includes the DNS resolution a hotel portal needs to load its login page. Result: dead internet, no error, no recourse. For a non-technical user in a hotel lobby, unrecoverable.

Options:

1. **Multi-zone build with a portal-tolerant zone.** Correct answer. Needs physical access to build and test.
2. **Kill switch off, protection at the endpoints.** VPN apps on phone and laptop with always-on and block-connections-without-VPN. Testable before departure. What was done here.
3. **Kill switch on, brief the user on the sequence.** Join network, complete portal, verify tunnel, enable kill switch. Requires them to remember a sequence under stress.

Option 2 was chosen. Documented as an accepted limitation, not hidden.

**Verify it actually fails open.** Disable every tunnel and load a page. If it loads showing the venue address, no deadlock. If it hangs, the kill switch is active regardless of what the panel says.

---

## Re-verify after every firmware update

Any firmware change is a config change whether or not you intended one. "Keep settings" is not a guarantee, it is a claim about a file list you have not read.

After any upgrade, before you consider the device deployed:

```sh
wg show                                          # handshake age, transfer counters
logread | grep -i "auth\|vpn"                    # AUTH_FAILED, retry loops
sysctl net.ipv6.conf.all.disable_ipv6            # must be 1
ls /etc/sysctl.d/                                 # is your drop-in still there and still sorting last
uci show wireless | grep isolate                  # isolation still set
```

Then from a client: public IP check with the client's own VPN off. Config surviving an upgrade is not the same as the tunnel working.

If you want to know exactly what an upgrade preserves on your hardware, capture it before and after:

```sh
cat /etc/sysupgrade.conf
md5sum /etc/config/* /etc/openvpn/* 2>/dev/null
```

Run the upgrade, run the same commands, diff. Anything with a changed hash was regenerated, not preserved, regardless of what the checkbox said.

---

## Verify against behaviour, not config

Every control was tested by observing what the device did, not by reading what it was set to.

| Control | Method |
|---|---|
| Tunnel carries client traffic | Client in airplane mode, its own VPN app off, so router wifi is the only path. Check public IP. |
| IPv6 disabled | Same test. IP check pages report v6 status separately. |
| Handshake genuine | `wg show` for handshake age and transfer counters. An interface with an address and no handshake is dead. |
| Failover | Disable primary tunnel, reload, confirm the exit address changed. |
| Fails open | Disable all tunnels, confirm a page still loads. |
| Client isolation | Router reaches client, second client cannot. |
| Guest segregation | Client on guest SSID attempts to load the admin panel. |
| Captive portal | Fresh association to a real portal. Confirm tunnels reconnect unattended afterwards. |

The portal test is the one people skip. Do it at a real venue before departure, not after.

---

## Contents

- `README.md`: this file, the findings
- `BUILD-GUIDE.md`: the generic build, step by step
- `harden.sh`: the UCI sequence as a script. Runs on the router. Backs up first, prompts for keys so they stay out of your shell history, and gates the LAN address change behind a REMOTE flag because that is the one change a backup cannot rescue you from. Supports dry-run.
- `verify.sh`: read-only posture report. Changes nothing. Checks the things that diverged between config and behaviour on a real build, including the sysctl load-order trap and OpenVPN auth failures in the log.

- `LICENSE`: MIT for the scripts, CC BY 4.0 for the docs

Addressing and SSIDs are placeholders. Substitute your own.

Neither script does SSH daemon hardening, firmware upgrades, or global firewall input drop. Those need physical access and are listed as deferred in the build guide.

---

## License

Dual licensed.

- **Scripts** (`harden.sh`, `verify.sh`): MIT
- **Documentation** (`README.md`, `BUILD-GUIDE.md`): CC BY 4.0

See `LICENSE`.

The scripts modify network and firewall configuration on a live device. They
are provided without warranty. Read them before running them, take a backup
first, and do not run them against anything you cannot recover.
