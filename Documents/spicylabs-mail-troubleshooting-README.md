# spicylabs.online — Inbound Mail Outage: Troubleshooting & Reference

## Summary
Inbound email to `@spicylabs.online` stopped arriving for about a week (roughly
2026-08-12 through 2026-08-19). Root cause: Tailscale had taken over DNS
resolution on the public-facing mail relay, blocking public DNS lookups that
Postfix needed to process incoming mail. Fixed by disabling Tailscale's DNS
override on the relay. Confirmed working with real external test emails
(Gmail, Wasabi) and confirmed the fix survives a reboot.

## Mail architecture
Because the local ISP (KPN) blocks inbound port 25, mail for the domain does
not go directly to the on-prem mail server. Instead:

```
Internet sender
  -> MX record: mx.spicylabs.online (149.210.166.46)
  -> Postfix relay, hostname "cloud", TransIP VPS (Debian 12, 1 core / 1GB RAM)
  -> Tailscale tunnel (tailnet: tail5daaae.ts.net)
  -> hMailServer on VM-SDC (192.168.2.240), Tailscale IP 100.96.116.70, port 25
  -> Mailbox delivery
```

Key hosts/identifiers:
- **Domain**: `spicylabs.online`, DNS managed via Cloudflare.
- **MX target / relay**: `mx.spicylabs.online` = public IP `149.210.166.46`.
  - Also reachable as Tailscale node `cloud` (`100.66.32.54`).
  - Hosted on TransIP (VPS name `mchalogany-vps`, AMS0 region).
  - SSH login: user `mchalogany`, key-based auth only (see "Access" below).
- **On-prem mail server (hMailServer)**: `VM-SDC`, LAN IP `192.168.2.240`,
  Tailscale IP `100.96.116.70`.
  - hMailServer installed at `C:\Program Files\hMailServer`.
  - Logs at `C:\Program Files\hMailServer\Logs\hMailServer_<yyyy-MM-dd>.log`.
  - hMailServer service name: `hMailServer` (Auto start).
  - Windows Firewall rule `hMailServer SMTP (Port 25)`: allowed, profile `Any`.
- **Outbound relay (unrelated to inbound issue)**: Brevo
  (`smtp-relay.brevo.com:587`), used for sending mail out, not receiving.
- **Access jump box**: `SRV-VDDVMDL5` — a workgroup (non-domain-joined)
  Windows machine on the same LAN as VM-SDC, used to reach VM-SDC via WinRM
  and the relay via SSH.

## Access notes for future reference
- **VM-SDC**: Not domain-joined relative to `SRV-VDDVMDL5`, so WinRM/PS
  Remoting requires either `TrustedHosts` + local credentials, or the
  existing WinRM HTTPS listener on port **5986** (cert issued for
  `spicylabs.online`). Example connection:
  ```powershell
  $opt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
  Enter-PSSession -ComputerName "192.168.2.240" -UseSSL -Port 5986 -Credential (Get-Credential) -SessionOption $opt
  ```
- **Relay (`149.210.166.46`)**: SSH key-based auth only, no password login.
  - Working account: `mchalogany`.
  - Private key used: `id_ed25519_pi-user-windows` (was found in the local
    Downloads folder on `SRV-VDDVMDL5`; corresponds to an SSH key already
    registered in the TransIP account's "SSH Keys" panel, added 2026-07-09).
  - Note: TransIP's "SSH Keys" panel only injects keys into **new** VPS
    installs, not into the already-running VPS — adding a new key there
    does not grant access to the live server.
  - Windows OpenSSH requires restrictive ACLs on private key files:
    ```powershell
    icacls $keyPath /inheritance:r
    icacls $keyPath /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)"
    ```
  - TransIP also provides a web-based VPS console (VNC-like) under
    VPS -> Overview -> click into the console panel, useful if SSH is
    unavailable (no root password was available for this route).

## Root cause
On the relay (`cloud`), Tailscale was configured to override the system's
DNS resolver (`/etc/resolv.conf` pointed only at `100.100.100.100`, Tailscale's
internal resolver). This resolver cannot resolve public internet domains.
Postfix's recipient verification (`reject_unverified_recipient`) and bounce
handling depend on public DNS, so incoming mail failed silently — no queue
entry, no bounce, no log line — which made this very hard to notice.

Evidence trail that led here:
1. hMailServer, Windows Firewall, and the Tailscale tunnel were all healthy
   and had processed relay mail successfully as recently as 2026-08-12.
2. No connection attempts from the relay appeared in hMailServer's logs after
   2026-08-12 — the relay had simply stopped trying, pointing at the relay
   side rather than VM-SDC.
3. On the relay, Postfix's master process and queue were healthy (empty
   queue, port 25 listening), ruling out a crashed/stopped service.
4. `/etc/resolv.conf` showed only Tailscale's DNS server; public domain
   lookups (`host spicylabs.online`, `host gmail.com`) timed out via
   Tailscale DNS but succeeded via public DNS (e.g. `8.8.8.8`).
5. A stuck deferred bounce message in the queue could not resolve the
   sender's domain to send the bounce, confirming the DNS dependency.

Unrelated red herrings ruled out along the way:
- A Postfix `systemctl status` reading of `active (exited)` initially looked
  like Postfix was down — a deeper check showed the master process (PID)
  and all support services (qmgr, smtpd, tlsmgr, etc.) were actually running
  fine, and this was not the real issue.
- A one-time kernel "SYN flooding on port 25" message seen on the VPS
  console was from 2026-07-23, well before the outage window, and unrelated.
- The Brevo SMTP relay is for outbound mail only and is unrelated to
  receiving mail.

## Fix applied
On the relay (`cloud` / `149.210.166.46`):
```bash
sudo tailscale set --accept-dns=false
```
This stops Tailscale from overriding system DNS, letting systemd-resolved
fall back to public DNS servers, while leaving the Tailscale tunnel/routing
to `100.96.116.70` (VM-SDC) fully intact (Postfix's transport map routes to
that host by IP, not hostname, so no DNS is needed for that hop).

After the change:
- `/etc/resolv.conf` showed public nameservers (e.g. `195.8.195.8`,
  `195.135.195.135`) instead of only `100.100.100.100`.
- `host spicylabs.online` / `host gmail.com` resolved correctly.
- The stuck deferred bounce message was cleared: `sudo postsuper -d <queue-id>`.
- An end-to-end test message sent through the relay's public SMTP path
  reached hMailServer successfully.

## Verification performed
- Sent test SMTP transactions directly to the relay's local port 25 and
  confirmed successful queuing/delivery.
- Confirmed real external emails (from Gmail and Wasabi) arrived in the
  mailbox after the fix.
- **Rebooted the relay** and reconfirmed all of the following survived the
  reboot intact:
  - `tailscale debug prefs` shows `"CorpDNS": false` (the DNS-override
    setting is persisted in Tailscale's own state, not just the live
    resolv.conf).
  - Public DNS resolution still works post-reboot.
  - Postfix auto-started and is listening on port 25.
  - Tailscale reconnected and VM-SDC is reachable on port 25 over the tunnel.
  - A post-reboot end-to-end test message was delivered successfully.

## Suggested follow-ups (not yet done)
- Add a scheduled health check on the relay that periodically verifies
  public DNS resolution and mail queue depth, with alerting on failure —
  this outage went unnoticed for about a week.
- Install `rsyslog` on the relay so Postfix logs to `/var/log/mail.log`
  again (Debian 12 uses journald only by default), making future
  investigations much faster.
- Consider basic rate-limiting/fail2ban on port 25 on the relay, since it's
  a small VPS directly exposed to the internet (a SYN-flood event was
  observed once, on 2026-07-23).
- Keep this document updated if the relay, Tailscale tunnel, or hMailServer
  configuration changes.
