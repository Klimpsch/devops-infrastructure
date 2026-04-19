# ============================================================
# Exchange Server — Clean Shutdown Procedure
# Run from Exchange Management Shell as Administrator
# ============================================================

# 1. Dismount all mailbox databases (flushes transaction logs to disk)
Write-Host "==> Dismounting mailbox databases..." -ForegroundColor Cyan
Get-MailboxDatabase | Dismount-Database -Confirm:$false

# 2. Verify databases are dismounted
Write-Host "==> Verifying dismount..." -ForegroundColor Cyan
Get-MailboxDatabase -Status | Format-Table Name, Mounted, MountedOnServer -AutoSize
$stillMounted = Get-MailboxDatabase -Status | Where-Object Mounted -eq $true
if ($stillMounted) {
    Write-Host "!! Some databases still mounted — aborting" -ForegroundColor Red
    $stillMounted | Format-Table Name, Mounted
    return
}

# 3. Stop Exchange services in dependency order
Write-Host "==> Stopping Exchange services..." -ForegroundColor Cyan
$services = @(
    'MSExchangeTransport',
    'MSExchangeFrontEndTransport',
    'MSExchangeTransportLogSearch',
    'MSExchangeAntispamUpdate',
    'MSExchangeMailboxAssistants',
    'MSExchangeMailboxReplication',
    'MSExchangeDelivery',
    'MSExchangeSubmission',
    'MSExchangeThrottling',
    'MSExchangeDiagnostics',
    'MSExchangeHM',
    'MSExchangeHMRecovery',
    'MSExchangeRepl',
    'MSExchangeRPC',
    'MSExchangeIMAP4',
    'MSExchangePOP3',
    'MSExchangeIMAP4BE',
    'MSExchangePOP3BE',
    'MSExchangeIS',
    'MSExchangeServiceHost',
    'MSExchangeUM',
    'MSExchangeUMCR',
    'MSExchangeFastSearch',
    'HostControllerService',
    'MSExchangeEdgeSync',
    'MSExchangeADTopology'
)
foreach ($s in $services) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Host "   stopping $s"
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }
}

# 4. Catch any Exchange services we missed (belt and braces)
Write-Host "==> Catching any remaining Exchange services..." -ForegroundColor Cyan
Get-Service MSExchange* | Where-Object Status -ne 'Stopped' |
    Stop-Service -Force -ErrorAction SilentlyContinue

# 5. Stop IIS (Exchange's web front-end)
Write-Host "==> Stopping IIS..." -ForegroundColor Cyan
Stop-Service W3SVC, WAS -Force -ErrorAction SilentlyContinue

# 6. Final verification
Write-Host "==> Final check — anything still running?" -ForegroundColor Cyan
$running = Get-Service MSExchange*, W3SVC, WAS, HostControllerService -ErrorAction SilentlyContinue |
    Where-Object Status -ne 'Stopped'

if ($running) {
    Write-Host "!! Still running:" -ForegroundColor Yellow
    $running | Format-Table Name, Status -AutoSize
    Write-Host "!! Investigate before shutting down." -ForegroundColor Yellow
    return
}

Write-Host ""
Write-Host "==> All Exchange services stopped and databases dismounted." -ForegroundColor Green
Write-Host "==> Safe to shut down Windows." -ForegroundColor Green
Write-Host ""

# 7. Shut down Windows (uncomment when you're ready to automate this)
# Stop-Computer -Force
