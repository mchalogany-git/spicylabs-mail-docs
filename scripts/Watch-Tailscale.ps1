# Watch-Tailscale.ps1
#
# Deployed on VM-SDC as Scheduled Task "TailscaleWatchdog" (runs as SYSTEM,
# every 5 minutes). See incidents/2026-09-13-vm-sdc-tailscale-hang.md for
# the failure mode this protects against: tailscaled reporting "Running"
# in Get-Service while its internal networking loop has silently hung.
#
# Deployment:
#   New-Item -ItemType Directory -Path "C:\Scripts" -Force
#   (save this file to C:\Scripts\Watch-Tailscale.ps1)
#
#   $action = New-ScheduledTaskAction -Execute "powershell.exe" `
#       -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Watch-Tailscale.ps1"'
#   $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
#       -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
#   $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
#   Register-ScheduledTask -TaskName "TailscaleWatchdog" -Action $action -Trigger $trigger `
#       -Settings $settings -RunLevel Highest -User "SYSTEM"

param(
    [string]$TargetPeer = "100.66.32.54",
    [int]$FailureThreshold = 3,
    [int]$PingTimeoutSec = 5,
    [string]$LogPath = "C:\ProgramData\Tailscale\Logs\watchdog.log",
    [string]$StateFile = "C:\ProgramData\Tailscale\Logs\watchdog_failcount.txt"
)

function Write-Log($message) {
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    "$timestamp $message" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

$failCount = 0
if (Test-Path $StateFile) {
    $raw = Get-Content $StateFile -ErrorAction SilentlyContinue
    if ($raw -match '^\d+$') { $failCount = [int]$raw }
}

$pingOk = $false
try {
    $result = & tailscale ping --timeout "$($PingTimeoutSec)s" -c 1 $TargetPeer 2>&1
    if ($LASTEXITCODE -eq 0 -and ($result -join "`n") -match "pong from") {
        $pingOk = $true
    }
} catch {
    $pingOk = $false
}

if ($pingOk) {
    if ($failCount -gt 0) {
        Write-Log "Ping to $TargetPeer succeeded, resetting failure count (was $failCount)."
    }
    Set-Content -Path $StateFile -Value 0
    exit 0
}

$failCount++
Write-Log "Ping to $TargetPeer failed (consecutive failures: $failCount)."
Set-Content -Path $StateFile -Value $failCount

if ($failCount -ge $FailureThreshold) {
    Write-Log "Failure threshold ($FailureThreshold) reached. Restarting Tailscale service."
    try {
        Restart-Service -Name Tailscale -Force
        Write-Log "Tailscale service restarted."
    } catch {
        Write-Log "Failed to restart Tailscale service: $_"
    }
    Set-Content -Path $StateFile -Value 0
}
