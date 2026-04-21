# Exchange 2019 DAG — Routine CU/SU Update Playbook

**Scope:** Two **physical** Windows servers running Exchange 2019 CU14/CU15 in a DAG, both hosting active database copies. Applying a Cumulative Update or Security Update.

**Window estimate:** 4-5 hours for CU, 2-3 hours for SU. Add 30-60 min buffer for hardware delays (POST, RAID init, slow boots).

---

## Before the window (T-1 day or earlier)

### Baseline — capture and save this output

```powershell
# Version/build of each server
Get-ExchangeServer | Format-Table Name, AdminDisplayVersion, Edition -AutoSize
Invoke-Command -ComputerName EXCH01,EXCH02 -ScriptBlock {
    (Get-Command Exsetup.exe).FileVersionInfo.ProductVersion
}

# DAG config
Get-DatabaseAvailabilityGroup | Format-List Name, Servers, WitnessServer, WitnessDirectory

# Database copy layout (which server is active for what)
Get-MailboxDatabase -Status | Format-Table Name, Server, Mounted, ActivationPreference -AutoSize

# Save this — you'll compare against it after the upgrade
```

### Health gate — ALL must be clean

```powershell
# All components Active on both servers
Get-ServerComponentState EXCH01, EXCH02 | Where-Object State -ne Active
# ^ expect empty

# Service and replication health
Test-ServiceHealth -Server EXCH01; Test-ServiceHealth -Server EXCH02
Test-ReplicationHealth -Server EXCH01; Test-ReplicationHealth -Server EXCH02

# Cluster
Get-ClusterNode | Format-Table Name, State, NodeWeight
Test-Cluster -Node EXCH01, EXCH02

# Copy queues must be 0 or near-0
Get-MailboxDatabaseCopyStatus * |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState -AutoSize

# Mail queues not backlogged
Get-Queue -Server EXCH01 | Where-Object MessageCount -gt 10
Get-Queue -Server EXCH02 | Where-Object MessageCount -gt 10
```

**Any unhealthy item is a stop condition.** Fix before the window.

### Physical hardware checks (critical on bare metal)

Bare-metal Exchange has failure modes a VM doesn't. Do these the week before:

```powershell
# Physical disk / RAID health via Windows
Get-PhysicalDisk | Where-Object HealthStatus -ne Healthy
Get-StoragePool | Format-Table FriendlyName, HealthStatus, OperationalStatus
Get-VirtualDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus

# Windows event log — any recent hardware errors?
Get-WinEvent -LogName System -MaxEvents 500 |
    Where-Object {$_.LevelDisplayName -in 'Error','Critical'} |
    Where-Object {$_.ProviderName -match 'disk|storage|WHEA|Kernel|HAL|nvme|raid'} |
    Select-Object TimeCreated, ProviderName, Id, Message |
    Format-Table -AutoSize

# Disk free space
Get-Volume | Where-Object DriveType -eq Fixed |
    Format-Table DriveLetter, FileSystemLabel,
        @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
        @{n='TotalGB';e={[math]::Round($_.Size/1GB,1)}}
```

Also check via your vendor's tools (Dell OpenManage, HPE iLO/Smart Storage Admin, Lenovo XClarity):

- Failed or predictive-failure disks
- RAID array status (degraded? rebuilding?)
- Power supply redundancy (both PSUs healthy?)
- Memory errors (correctable count trending up = DIMM going bad)
- Fan and thermal status
- Battery-backed write cache / capacitor health on the RAID controller

Verify separately:

- **OOB management working** (iDRAC / iLO / IMM). You'll need it if the OS fails to boot post-update
- **Firmware is current** for BIOS, storage controller, NIC, HBA — but **do NOT update firmware in the same window as Exchange**. Schedule firmware work separately
- **Boot drive has enough free space** (30+ GB on the Exchange install volume)
- **UPS/generator** healthy if your site relies on them

### Final prep checklist

- [ ] Change ticket approved, users/stakeholders notified
- [ ] Maintenance window scheduled with enough buffer (physical reboots take 5-15 min, sometimes more)
- [ ] Update ISO downloaded, checksum verified, **copied locally to both servers** (not a network share — works even if SAN hiccups)
- [ ] 30+ GB free on install drive, both servers
- [ ] **Exchange-aware backup within last 24h** (tape/disk backup to a separate system). On physical hardware you do NOT have a snapshot safety net
- [ ] AV exclusions for Exchange paths still valid
- [ ] Schema Master DC identified and reachable
- [ ] `repadmin /replsummary` on a DC — no errors
- [ ] On-call identified, with **hands-on-keyboard local resource** or remote hands arrangement at the datacenter
- [ ] OOB console access (iDRAC/iLO) tested and credentials confirmed for both servers
- [ ] Bootable recovery media available (Windows PE USB, ERD) in case boot fails

### Decide upgrade order

Pick **EXCH01** or **EXCH02** as first. Tie-breakers:

- Server with **fewer** ActivationPreference=1 databases → upgrade first (less rebalancing)
- Server hosting the DAG **witness** directory (if a server is also the witness, upgrade second)
- If symmetric, alphabetical is fine

For this doc, **SERVER A = first, SERVER B = second.** Swap in your actual names.

---

## The window

> Two passes of the same steps. Full verification between passes. **Never both servers down at once.**

## PASS 1 — Upgrade SERVER A

### 1. Move active databases off Server A

```powershell
# See what's currently active on A
Get-MailboxDatabase -Status | Where-Object Server -eq "EXCH01" | Format-Table Name, MountedOnServer

# Move them all to B
Get-MailboxDatabase | Where-Object Server -eq "EXCH01" |
    ForEach-Object {
        Move-ActiveMailboxDatabase -Identity $_.Name -ActivateOnServer EXCH02 -Confirm:$false
    }

# Verify — nothing active on A
Get-MailboxDatabase -Status | Where-Object Server -eq "EXCH01"
# ^ expect empty
```

### 2. Maintenance mode Server A

```powershell
# Block DB activation on this node
Set-MailboxServer EXCH01 -DatabaseCopyActivationDisabledAndMoveNow $true
Set-MailboxServer EXCH01 -DatabaseCopyAutoActivationPolicy Blocked

# Drain transport
Set-ServerComponentState EXCH01 -Component HubTransport -State Draining -Requester Maintenance
Redirect-Message -Server EXCH01 -Target EXCH02.your.domain -Confirm:$false

# Wait for transport queues to drain
while ((Get-Queue -Server EXCH01 | Where-Object {$_.Identity -notlike "*\Poison*" -and $_.MessageCount -gt 0}).Count -gt 0) {
    Write-Host "Waiting for queues to drain..."
    Start-Sleep 10
    Get-Queue -Server EXCH01 | Where-Object MessageCount -gt 0 | Format-Table Identity, MessageCount
}

# Suspend cluster node
Suspend-ClusterNode -Name EXCH01

# Full offline
Set-ServerComponentState EXCH01 -Component ServerWideOffline -State Inactive -Requester Maintenance
```

Verify fully in maintenance:

```powershell
Get-ServerComponentState EXCH01 | Where-Object State -eq Active
# ^ expect empty (or just ForwardSyncDaemon which is fine)

Get-ClusterNode EXCH01 | Format-List Name, State
# ^ State = Paused
```

### 3. Remove Server A from load balancer

Physical servers almost always sit behind a hardware load balancer (F5, Kemp, Citrix ADC, A10) or DNS round-robin. Before Setup:

- **Disable Server A in the LB pool** (or set health probe to force it out)
- Prefer the LB's "drain" or "disabled" state over hard-disable — lets existing sessions finish
- Let connections drain (5-10 min typically)
- Confirm LB is routing only to Server B before proceeding

### 4. Install prerequisites (if required by the CU)

CU release notes list specific .NET, VC++, UCMA versions. Install any missing ones before Setup. Reboot if prompted — and remember, a physical reboot takes 5-15 minutes (POST, RAID init, Windows boot).

### 5. Run Setup on Server A

Mount the ISO you copied locally:

```powershell
$iso = "C:\Updates\ExchangeServer2019-CUxx-x64.ISO"
$mount = Mount-DiskImage -ImagePath $iso -PassThru
$drive = ($mount | Get-Volume).DriveLetter
Set-Location "${drive}:\"
```

From **elevated** PowerShell:

```powershell
.\Setup.exe /Mode:Upgrade /IAcceptExchangeServerLicenseTerms_DiagnosticDataON
```

Runs 30-60 min for a CU, 15-30 for an SU. **Don't interrupt.** Watch `C:\ExchangeSetupLogs\ExchangeSetup.log` if you need to see progress.

Unmount the ISO when done:

```powershell
Dismount-DiskImage -ImagePath $iso
```

### 6. Reboot

```powershell
Restart-Computer -Force
```

**Physical reboot reality:** budget 5-15 minutes for POST, RAID init, Windows boot. If the server's been running for months, first boot after CU may be slower because of delayed Windows Updates applying, disk checks, etc.

**If it doesn't come back within 15 minutes** — connect to the OOB console. Common physical-only issues:

- Stuck at POST due to memory or disk error that surfaced during reboot
- Waiting at "Getting Windows ready" screen (let it run — can be 20+ min on first post-CU boot)
- Automatic Repair triggered after a boot crash
- RAID controller doing a consistency check

Give it 30 minutes before assuming failure and engaging OOB/hands.

### 7. Take Server A out of maintenance

Run these from EMS on **Server B** (since A is still stabilizing):

```powershell
Resume-ClusterNode -Name EXCH01

Set-ServerComponentState EXCH01 -Component ServerWideOffline -State Active -Requester Maintenance
Set-ServerComponentState EXCH01 -Component HubTransport -State Active -Requester Maintenance

Set-MailboxServer EXCH01 -DatabaseCopyActivationDisabledAndMoveNow $false
Set-MailboxServer EXCH01 -DatabaseCopyAutoActivationPolicy Unrestricted
```

### 8. Re-add Server A to the load balancer

Add back to the pool. Wait for **two consecutive successful health probes** before considering it live. Most LBs let you watch health check counters in real-time.

### 9. Health gate before touching Server B

```powershell
# New build present?
Get-ExchangeServer EXCH01 | Format-List Name, AdminDisplayVersion

# Components back Active?
Get-ServerComponentState EXCH01 | Where-Object State -ne Active
# ^ expect empty

# Service + replication healthy?
Test-ServiceHealth -Server EXCH01
Test-ReplicationHealth -Server EXCH01

# Cluster node back?
Get-ClusterNode EXCH01   # State = Up

# Hardware still happy after the reboot?
Invoke-Command -ComputerName EXCH01 -ScriptBlock {
    Get-PhysicalDisk | Where-Object HealthStatus -ne Healthy
    Get-WinEvent -LogName System -MaxEvents 50 |
        Where-Object {$_.LevelDisplayName -in 'Error','Critical'} |
        Where-Object {$_.ProviderName -match 'disk|WHEA|Kernel|raid'}
}

# THE KEY CHECK — copies must be fully caught up
Get-MailboxDatabaseCopyStatus -Server EXCH01 |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState -AutoSize
```

**Wait here until:**

- `Status = Healthy` or `Mounted` (not `Seeding`, `Resynchronizing`, or `FailedAndSuspended`)
- `CopyQueueLength = 0`
- `ReplayQueueLength = 0`
- `ContentIndexState = Healthy`

Can take 10-60 minutes. **Do not start Server B until this is clean** — otherwise you have no healthy passive copies if anything goes wrong on Server B.

Physical servers with dedicated local storage typically seed fast, but content indexing can still lag. If Crawling for >4 hours:

```powershell
Update-MailboxDatabaseCopy -Identity "DB01\EXCH01" -CatalogOnly
```

---

## PASS 2 — Upgrade SERVER B

Before starting, verify AD schema replication completed across sites:

```powershell
# On a DC
repadmin /replsummary
# ^ no errors, no large deltas
```

Then repeat **all 9 steps** from Pass 1 with the server names swapped.

### Server B maintenance mode

```powershell
# Move active DBs off B to A (now running new version)
Get-MailboxDatabase | Where-Object Server -eq "EXCH02" |
    ForEach-Object {
        Move-ActiveMailboxDatabase -Identity $_.Name -ActivateOnServer EXCH01 -Confirm:$false
    }

Set-MailboxServer EXCH02 -DatabaseCopyActivationDisabledAndMoveNow $true
Set-MailboxServer EXCH02 -DatabaseCopyAutoActivationPolicy Blocked
Set-ServerComponentState EXCH02 -Component HubTransport -State Draining -Requester Maintenance
Redirect-Message -Server EXCH02 -Target EXCH01.your.domain -Confirm:$false

# Wait for queues (same loop as Pass 1)

Suspend-ClusterNode -Name EXCH02
Set-ServerComponentState EXCH02 -Component ServerWideOffline -State Inactive -Requester Maintenance
```

### Server B LB removal, Setup, reboot, exit maintenance, LB re-add

Same sequence as Pass 1 on Server A.

### Server B health gate

Same checks. Wait for copies to resync fully before moving on.

---

## Post-window

### Rebalance databases

Databases are probably all active on Server A right now. Put them back where they belong:

```powershell
cd $env:ExchangeInstallPath\Scripts
.\RedistributeActiveDatabases.ps1 -DagName <YourDAGName> -BalanceDbsByActivationPreference -Confirm:$false
```

### Final verification

```powershell
# Both servers on new build
Get-ExchangeServer | Format-Table Name, AdminDisplayVersion

# Compare to baseline — should look the same as before minus new version
Get-MailboxDatabase -Status | Format-Table Name, Server, Mounted, ActivationPreference -AutoSize

# All healthy
Get-ServerComponentState EXCH01,EXCH02 | Where-Object State -ne Active
Test-ServiceHealth -Server EXCH01; Test-ServiceHealth -Server EXCH02
Test-ReplicationHealth -Server EXCH01; Test-ReplicationHealth -Server EXCH02

Get-MailboxDatabaseCopyStatus * |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState -AutoSize

# Mail flow test
Test-MAPIConnectivity -Server EXCH01; Test-MAPIConnectivity -Server EXCH02
Test-OutlookWebServices

# Hardware health on both
Invoke-Command -ComputerName EXCH01,EXCH02 -ScriptBlock {
    Get-PhysicalDisk | Where-Object HealthStatus -ne Healthy
    Get-WinEvent -LogName System -MaxEvents 50 |
        Where-Object {$_.LevelDisplayName -in 'Error','Critical'}
}

# LB pool — confirm via your LB's UI that both members are active and passing health checks

# Send external + internal test messages, confirm delivery
```

### Close out

- [ ] Baseline comparison clean
- [ ] Mail flow verified end-to-end
- [ ] Load balancer shows both members healthy
- [ ] No new hardware errors in event logs
- [ ] Users informed of completion
- [ ] Change ticket closed
- [ ] Update CMDB/docs with new build number
- [ ] File any issues encountered for next run's prep

---

## The key discipline

Four rules that matter more than the rest:

1. **One server at a time.** Never both in maintenance simultaneously.
2. **Health gate between servers.** Copies must be Healthy with zero queues before starting the second server's upgrade.
3. **Active copies off before maintenance.** `Move-ActiveMailboxDatabase` → verify empty → then maintenance commands.
4. **Don't rush.** A 4-hour run that works is infinitely better than a 2-hour run with a broken DAG.

---

## Physical-server failure modes (don't happen on VMs)

| Symptom | Likely cause | Action |
|---|---|---|
| Server won't POST after reboot | Failed DIMM, PSU, or backplane | OOB → system event log → RMA part. Server B runs the org meanwhile |
| Boot stuck at RAID init | Disk predictive failure | Controller logs; replace disk before proceeding |
| NIC not coming up after boot | Firmware/driver mismatch | Disable/enable in Device Manager; worst case reload driver |
| Massive I/O latency spike post-upgrade | Dead BBU / write cache disabled | Check controller status; replace BBU; performance poor until fixed |
| Random WHEA errors in event log | CPU or memory edge-case failure | Memory test (`mdsched.exe`); if repeats, vendor support |
| Server thermal-throttles during Setup | Blocked airflow or dying fan | Check OOB thermals; **don't proceed** with upgrade if throttling |
| Slow first boot after CU | Pending Windows Updates applying during boot | Normal — wait up to 30 min |
| Server boots to Automatic Repair | Boot sector/disk issue during reboot | Boot from recovery media; `bootrec /fixboot /fixmbr /rebuildbcd` |

Hardware rarely fails *during* Setup, but reboots stress components. A disk that's been "fine" for 6 months sometimes picks a post-CU reboot to die. That's why the health gate checks hardware event logs, not just Exchange state.

---

## If something goes wrong

**Setup fails partway through:**

- Check `C:\ExchangeSetupLogs\ExchangeSetup.log` — usually has a specific error
- Common: AV didn't really get disabled, .NET version mismatch, insufficient permissions for AD schema
- Re-running Setup with the same command usually resumes where it stopped

**Server A comes back unhealthy, Server B still on old version:**

- You still have a working Exchange org on Server B — don't panic
- DO NOT start Server B's upgrade
- Recover Server A at your own pace (Setup re-run, `/m:RecoverServer` as last resort)
- Reschedule Server B for a later window once A is fully healthy

**Database copies stuck Failed/Suspended after upgrade:**

```powershell
Resume-MailboxDatabaseCopy -Identity "DB01\EXCH01"
# If that doesn't work:
Update-MailboxDatabaseCopy -Identity "DB01\EXCH01" -DeleteExistingFiles
# ^ reseeds from the active copy — takes hours for large DBs
```

**Cluster shows node offline after reboot:**

```powershell
# From the healthy node
Get-ClusterNode
Start-ClusterNode -Name EXCH01
```

If it won't start, check Windows Event Log → System → FailoverClustering source.

**Server won't boot after upgrade (physical-specific):**

1. Connect to OOB console (iDRAC/iLO)
2. Check POST messages for hardware fault codes
3. If Windows is partly up, try Last Known Good / Safe Mode via F8 at boot
4. If boot loop on a stop error, collect the memory dump via OOB and engage Microsoft support
5. **Do not** begin Server B's upgrade until A is either fully recovered or you've made a decision to leave it offline long-term

**Rollback reality on physical servers:**

No VM snapshot revert. Your rollback options are:

- Re-run Exchange Setup — usually fixes partial failures
- `/m:RecoverServer` — rebuilds Exchange from AD config onto the existing (or new) OS install
- System state restore from backup — slow, invasive
- Bare-metal reinstall + restore — hours to days

This is why the pre-upgrade backup and health-gate discipline matters more on physical than on VMs.

---

## One-time: save this as scripts

Three scripts worth having in `C:\scripts\` on each server:

**`maint-mode-enter.ps1`** — parameter: server name. Does steps 1-2 (move DBs off, maintenance mode).

**`maint-mode-exit.ps1`** — parameter: server name. Does step 7 (resume cluster, activate components, unblock DBs).

**`health-check.ps1`** — runs the full health gate query, returns 0 if healthy, non-zero if not.

Say the word and I'll write those three. LB pool updates can also be scripted if your LB exposes an API (most do — F5 iControl REST, Kemp API, etc.). Automating the boring bits leaves your attention for the part that actually benefits from human judgment: watching Setup run and reacting to anything unusual.
