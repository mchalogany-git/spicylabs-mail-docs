# Incident 2: VM-SDC Tailscale client internal hang (2026-09-08 to 2026-09-13)

## Summary
Inbound email to `@spicylabs.online` silently failed to arrive for ~5 days
(2026-09-08 23:35 through 2026-09-13 21:10). Unlike Incident 1 (see main
README), this was **not** a DNS-override issue. Root cause: the Tailscale
Windows client (`tailscaled`) on `VM-SDC` — the final hop hosting hMailServer
— hung internally. The Windows service kept reporting `Running` the entire
time, but the tunnel's control-plane/netcheck/DERP logic had effectively
stalled, making `VM-SDC` unreachable from the relay (`cloud`) over Tailscale.

## Symptom
- A test email sent from Gmail to `mchalogany@spicylabs.online` never
  arrived, with no bounce.
- Outbound mail from spicylabs.online to other providers (e.g. Hotmail)
  worked fine — this asymmetry pointed at inbound-specific delivery, not a
  DNS/SPF/MX misconfiguration.

## Investigation trail
1. **DNS ruled out early** (unlike Incident 1): `host spicylabs.online` and
   `host gmail.com` resolved correctly from the relay. `/etc/resolv.conf`
   showed proper public nameservers, and `tailscale debug prefs` did not
   show `CorpDNS` re-enabled.
2. **MX/SPF checked and confirmed correct**: `mx.spicylabs.online` →
   `149.210.166.46` (the relay's public IP, intentional — see main README
   architecture). SPF and DMARC records were valid and unrelated to inbound
   delivery.
3. **Relay mail queue (`sudo postqueue -p`) showed the smoking gun**: dozens
   of deferred messages, including the original Gmail test, all failing
   with the identical error:
   ```
   connect to 100.96.116.70[100.96.116.70]:25: Connection timed out
   ```
   `100.96.116.70` is VM-SDC's Tailscale IP — the relay could not complete
   the final hop to hMailServer.
4. **Ruled out on VM-SDC itself**:
   - No unexpected reboot/crash (`Get-WinEvent` for Event IDs 41/1074/6005/
     6006/6008 in the outage window: no matches).
   - No Windows Update activity in the window.
   - NIC power management: `Get-NetAdapterPowerManagement` showed every
     feature (`SelectiveSuspend`, `WakeOnMagicPacket`, etc.) as
     `Unsupported` on both the Hyper-V synthetic adapter and the Tailscale
     Tunnel adapter — nothing to disable, nothing silently enabled.
   - Windows Firewall: `hMailServer SMTP (Port 25)` rule was `Enabled`,
     `Profile: Any` — not a firewall-profile mismatch.
   - `Get-NetConnectionProfile` showed both the Ethernet and Tailscale
     adapters as `DomainAuthenticated`, not `Public`.
5. **Ruled out on the Hyper-V host** (`SRV-VDDVMDL5` — see correction note
   below): zero checkpoints ever taken on the VM
   (`Get-VMSnapshot` returned nothing), and no
   `Microsoft-Windows-Hyper-V-Worker-Admin` / `-VMMS-Admin` events in the
   outage window. No host-side pause/backup/checkpoint caused this.
6. **Root cause found in Tailscale's own service logs**
   (`C:\ProgramData\Tailscale\Logs\tailscale-service-*.txt` — note: `.txt`,
   not `.log`; only the installer/updater use `.log`). Daily rotated log
   files for 2026-09-08 through 2026-09-12 were all **exactly 424,949 bytes**
   — identical size across 5 different days. Their content was a tight,
   unchanging repeating loop:
   ```
   health(warnable=no-derp-connection): ok
   health(warnable=no-derp-connection): error: ...'Frankfurt' relay server...
   ```
   flipping every ~10 seconds with **no other log activity whatsoever** (no
   netcheck reports, no magicsock activity, no WireGuard keepalives, no
   control-plane polling). The 2026-09-13 log file was 0 bytes until
   **21:10**, at which point normal activity abruptly resumed (netcheck
   reports, `magicsock: derp-14 connected`, control `PollNetMap`, WireGuard
   keepalives) — timed suspiciously close to when diagnostic commands
   (`tailscale status`, `tailscale ping`) were run interactively on that
   console session, suggesting IPC interaction with the stuck `tailscaled`
   process is what kicked it out of the hang.

**Conclusion**: `tailscaled`'s real networking loop stalled for ~5 days
while only a lightweight health-check timer kept ticking on stale state.
The OS-level process never exited, so `Get-Service`/service-restart
monitoring never caught it.

## Correction to main README
The main README previously described `SRV-VDDVMDL5` as just an "access jump
box." It is actually **the Hyper-V host** running VM-SDC and the other
homelab VMs. VM-SDC's Hyper-V VM object name is **`VM-WINSRV-2025-DC2RY`**
(not `VM-SDC` — that's only the guest OS hostname). Confirmed by matching
the guest's Ethernet MAC (`00-15-5D-02-FB-07`) against
`Get-VM | Get-VMNetworkAdapter` output on the host.

## Fix applied
1. On the relay (`cloud`), once VM-SDC's tunnel recovered on its own,
   flushed the backlog immediately rather than waiting for Postfix's next
   retry interval:
   ```bash
   sudo postqueue -f
   ```
   This delivered the original Gmail test message and everything else
   queued since 2026-09-09.
2. Updated the Tailscale client on VM-SDC:
   ```powershell
   tailscale update   # 1.102.2 -> 1.102.4
   ```

## Follow-up: monitoring added
Since this outage went undetected for 5 days (same blind spot as
Incident 1) and `Get-Service` cannot detect an internally-hung-but-running
`tailscaled` process, a watchdog was added on VM-SDC:

- Script: [`scripts/Watch-Tailscale.ps1`](../scripts/Watch-Tailscale.ps1)
- Deployed as Scheduled Task `TailscaleWatchdog`, running as `SYSTEM` every
  5 minutes.
- Logic: pings the relay (`100.66.32.54`) via `tailscale ping`; after 3
  consecutive failures, force-restarts the `Tailscale` service and logs the
  event to `C:\ProgramData\Tailscale\Logs\watchdog.log`.
- Persists across reboots (Scheduled Task, `SYSTEM` context, no logon
  trigger required).

## Known limitations of the current mitigation
- The watchdog protects against *this* failure mode (tunnel silently hung)
  and general connectivity blips. It does not detect a repeat of the
  Incident 1 DNS-override scenario, Postfix itself crashing, disk space
  issues, or upstream ISP/relay outages — those would need separate checks.
- Root cause of *why* `tailscaled` hung in the first place was not fully
  determined (no OS/power/Hyper-V trigger found); the 1.102.2 → 1.102.4
  update may or may not resolve the underlying bug. Monitor for recurrence.
