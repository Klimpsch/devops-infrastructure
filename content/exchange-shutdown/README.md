# Exchange 2019 DAG — Shutdown Procedure (Two Physical Servers)

**Scope:** Planned shutdown of a two-server Exchange 2019 DAG running on physical Windows servers. Both servers host active database copies.

**Use cases:**

- Full datacenter power-down (UPS test, electrical work)
- Both servers need to be shut down together (HVAC outage, building evacuation)
- Partial shutdown (one server for hardware maintenance)
- Emergency shutdown (unplanned but controlled — imminent power loss, fire alarm)

---

## Decide which scenario applies

| Scenario | Procedure |
|---|---|
| One server down, other stays up (e.g. DIMM replacement) | **Procedure A** — single-server graceful shutdown |
| Both servers down (planned full outage) | **Procedure B** — full DAG shutdown |
| Emergency — both down NOW | **Procedure C** — fast controlled shutdown |
| Immediate UPS failure / imminent power loss | **Procedure D** — minimum-damage emergency |

Procedures A, B, and C start with the same discipline: databases dismounted cleanly, services stopped in order, cluster drained properly. D is the "you don't have time for all that" version.

---

## Before any planned shutdown

### Health check — is the DAG actually healthy right now?

You don't want to shut down a DAG that's already in a degraded state and discover that fact at startup. Run these first:

```powershell
# Both servers responding and healthy
Get-ExchangeServer | Format-Table Name, AdminDisplayVersion, ServerRole
Test-ServiceHealth -Server EXCH01
Test-ServiceHealth -Server EXCH02

# All components Active
Get-ServerComponentState EXCH01,EXCH02 | Where-Object State -ne Active

# Cluster healthy, witness reachable
Get-ClusterNode | Format-Table Name, State, NodeWeight
Get-ClusterQuorum | Format-List

# Database copies all Healthy, no lag
Get-MailboxDatabaseCopyStatus * |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState -AutoSize

# Mail queues not backlogged
Get-Queue -Server EXCH01 | Where-Object MessageCount -gt 10
Get-Queue -Server EXCH02 | Where-Object MessageCount -gt 10
```

Expected: no errors, all Active, zero queue lengths, both nodes Up.

If anything is already degraded, **fix it first** or the shutdown becomes a recovery exercise.

### Capture current state

Save this before shutting down — you'll compare on startup:

```powershell
Get-MailboxDatabase -Status |
    Select-Object Name, Server, Mounted, MountedOnServer, ActivationPreference |
    Export-Csv C:\ExchangeOps\pre-shutdown-dbstate.csv -NoTypeInformation

Get-ClusterNode | Export-Csv C:\ExchangeOps\pre-shutdown-clusterstate.csv -NoTypeInformation
```

### Communicate

- Notify users and business stakeholders
- If external mail routing depends on these servers, coordinate with whoever manages the inbound MTA or smart host
- Inform monitoring team so they don't escalate during the planned outage

---

## Procedure A — Single Server Graceful Shutdown

**Scenario:** Hardware maintenance (DIMM swap, disk replacement, firmware) on ONE server. Other server stays up and serves users.

### 1. Move active databases off the target server

Assuming you're shutting down EXCH01:

```powershell
# See what's currently active on EXCH01
Get-MailboxDatabase -Status | Where-Object Server -eq "EXCH01" | Format-Table Name, MountedOnServer

# Move to EXCH02
Get-MailboxDatabase | Where-Object Server -eq "EXCH01" |
    ForEach-Object {
        Move-ActiveMailboxDatabase -Identity $_.Name -ActivateOnServer EXCH02 -Confirm:$false
    }

# Verify empty
Get-MailboxDatabase -Status | Where-Object Server -eq "EXCH01"
# ^ expect empty
```

### 2. Block activation and drain transport

```powershell
Set-MailboxServer EXCH01 -DatabaseCopyActivationDisabledAndMoveNow $true
Set-MailboxServer EXCH01 -DatabaseCopyAutoActivationPolicy Blocked

# Drain transport queues
Set-ServerComponentState EXCH01 -Component HubTransport -State Draining -Requester Maintenance
Redirect-Message -Server EXCH01 -Target EXCH02.your.domain -Confirm:$false

# Wait until queues drain
while ((Get-Queue -Server EXCH01 | Where-Object {$_.Identity -notlike "*\Poison*" -and $_.MessageCount -gt 0}).Count -gt 0) {
    Write-Host "Waiting for queues to drain..."
    Start-Sleep 10
}
```

### 3. Remove from load balancer

Pull EXCH01 out of the LB pool. Wait for existing connections to drain (5-10 min typical).

### 4. Suspend cluster node

```powershell
Suspend-ClusterNode -Name EXCH01
```

This pauses the node in the cluster — it still counts for quorum but won't own any resources.

### 5. Stop Exchange services and dismount any remaining databases

```powershell
# Dismount any database copies that happen to be mounted on EXCH01 (shouldn't be any now, but check)
Get-MailboxDatabase -Server EXCH01 -Status | Where-Object Mounted -eq $true |
    Dismount-Database -Confirm:$false

# Full offline
Set-ServerComponentState EXCH01 -Component ServerWideOffline -State Inactive -Requester Maintenance

# Stop all Exchange services (Force handles dependencies)
Get-Service MSExchange* | Stop-Service -Force
Get-Service W3SVC, WAS -Force -ErrorAction SilentlyContinue | Stop-Service -Force
```

### 6. Verify fully stopped

```powershell
Get-Service MSExchange* | Where-Object Status -ne Stopped
# ^ expect empty

Get-Queue -Server EXCH01
# ^ empty

Get-ClusterNode EXCH01 | Format-List Name, State
# ^ State = Paused
```

### 7. Shut down Windows

```powershell
Stop-Computer -Force
```

Or from the OOB console if Windows is unreachable. Give it 3-5 minutes for a clean physical shutdown.

### 8. On the OTHER server — verify everything still works

```powershell
# EXCH02 should still be mounting all databases, serving users normally
Get-MailboxDatabase -Status | Format-Table Name, Server, Mounted
Test-ServiceHealth -Server EXCH02
Get-Queue -Server EXCH02
```

At this point EXCH02 is running the whole org alone. Users see no disruption. Proceed with hardware work on EXCH01.

### When EXCH01 comes back

See the **Startup Procedure** at the end of this doc.

---

## Procedure B — Full DAG Shutdown (both servers)

**Scenario:** Planned whole-environment outage. Both Exchange servers will be down at the same time. Datacenter power work, HVAC outage, etc.

### Pre-flight

- Confirm the DC(s) providing AD/DNS are not also being shut down — or if they are, include them in the plan with proper ordering
- Confirm the DAG witness server will remain running (or is being shut down too)
- Notify users well in advance; external mail will queue on the sending side during the outage (usually fine for 4-24 hours)

### Decide shutdown order

Shut down the server with **fewer active databases** first. Typically the one you designated as "Server B" in the upgrade order. For this doc, shut down **EXCH02 first**, then **EXCH01**.

This matters because of quorum: a two-node DAG with a file share witness stays quorate as long as any two of {node A, node B, witness} are up. When you shut down the first node, you still have (surviving node + witness) = quorum. When you then shut down the second node, the DAG becomes offline cleanly — no split-brain risk.

### Phase 1 — Shut down EXCH02 (secondary)

Follow **Procedure A steps 1-7** for EXCH02. Move its active DBs to EXCH01, maintenance mode, pull from LB, suspend cluster node, stop services, shut down Windows.

After EXCH02 is powered off, verify EXCH01 is still healthy:

```powershell
# All databases should now be active on EXCH01
Get-MailboxDatabase -Status | Format-Table Name, Server, Mounted, MountedOnServer

# EXCH01 still serving users
Test-ServiceHealth -Server EXCH01
Get-Queue -Server EXCH01
```

### Phase 2 — Shut down EXCH01

Now you can't move databases anywhere — EXCH02 is off. You just need to dismount and stop cleanly.

```powershell
# 1. Dismount all databases (flushes logs, ensures clean shutdown state)
Get-MailboxDatabase | Dismount-Database -Confirm:$false

# 2. Verify all dismounted
Get-MailboxDatabase -Status | Format-Table Name, Mounted
# ^ Mounted should all be False

# 3. Block activation (belt and braces in case the server boots alone later)
Set-MailboxServer EXCH01 -DatabaseCopyActivationDisabledAndMoveNow $true

# 4. Stop Exchange services
Get-Service MSExchange* | Stop-Service -Force
Get-Service W3SVC, WAS -Force -ErrorAction SilentlyContinue | Stop-Service -Force

# 5. Stop the cluster service (important — leaves cluster in a clean stopped state)
Stop-ClusterNode -Name EXCH01

# 6. Verify
Get-Service MSExchange* | Where-Object Status -ne Stopped
Get-Service ClusSvc | Format-List Name, Status

# 7. Shut down Windows
Stop-Computer -Force
```

### Optional: shut down the witness

If the witness is a dedicated file server that's also part of the planned outage, shut it down **after** both Exchange servers. Power it back up **before** either Exchange server during startup.

If the witness is a DC that stays up for AD purposes, leave it alone.

---

## Procedure C — Emergency but Controlled Shutdown

**Scenario:** Something bad is happening and you need both servers down in 10-15 minutes. Not pulling the plug, but not luxuriating in full graceful steps either.

**Trade-off:** Fewer steps = faster but less safe. Skip load balancer drain and user-level notifications. You'll lose in-flight messages still in transport queues. Mailbox data is still safe as long as you dismount.

### 1. Dismount databases everywhere — no DB moves

Forget moving active databases between nodes. Just dismount them in place.

```powershell
# On EITHER server — this affects the whole org via EMS
Get-MailboxDatabase | Dismount-Database -Confirm:$false

# Verify
Get-MailboxDatabase -Status | Format-Table Name, Mounted, MountedOnServer
```

### 2. Stop services on both servers, in parallel

From two EMS windows or over SSH to both at once:

```powershell
# On EXCH01
Get-Service MSExchange* | Stop-Service -Force

# On EXCH02 (simultaneously)
Get-Service MSExchange* | Stop-Service -Force
```

### 3. Stop cluster nodes

```powershell
Stop-ClusterNode -Name EXCH02
Stop-ClusterNode -Name EXCH01
```

### 4. Shut down Windows on both

```powershell
# Both servers, as fast as possible
Stop-Computer -ComputerName EXCH01 -Force
Stop-Computer -ComputerName EXCH02 -Force
```

Or from OOB consoles if needed: graceful shutdown via iDRAC/iLO power action (not force off).

### 5. Confirm power-off via OOB

Watch both servers' OOB consoles to confirm they've actually powered down. On physical hardware, sometimes a service hangs the shutdown and you think it's off but it's still trying to stop things — iDRAC/iLO shows real power state.

If a server hangs past 5 minutes of "shutting down," **force power off via OOB**. Dirty, but better than letting it hang indefinitely.

**Total time budget:** 10-15 minutes including OOB confirmation.

---

## Procedure D — Minimum-Damage Emergency (imminent power loss)

**Scenario:** UPS is failing and you have 2-5 minutes before hard power loss. You can't do it gracefully — you're just trying to minimize damage.

### The triage

You have time for exactly one thing: **dismount databases**. That's it.

```powershell
# From EMS — affects both servers at once
Get-MailboxDatabase | Dismount-Database -Confirm:$false
```

That single command flushes outstanding transaction logs to disk and marks databases as cleanly dismounted. If power dies after this completes, you'll have clean databases that mount instantly on restart. If power dies before it completes, you'll have dirty databases that need log replay — usually automatic, occasionally requires `eseutil`.

If you have another 30 seconds:

```powershell
# Stop the Information Store (final flush)
Stop-Service MSExchangeIS -Force
```

Then shut down via whatever means is fastest:

```powershell
# PowerShell, fastest
Stop-Computer -Force -ComputerName EXCH01,EXCH02
```

Or OOB graceful power action on both. If you're physically in the room, the power button on a Windows server triggers a graceful shutdown (not instant off) unless held for 4+ seconds.

**Do NOT hard-power-off via OOB if there's any chance of a graceful path.** Dirty Exchange shutdowns cost hours of recovery; a 60-second extended shutdown costs nothing.

### If power dies mid-dismount

Not the end of the world. On next boot:

- Exchange will auto-replay transaction logs (takes 5-30 min depending on size)
- Most databases come back Healthy on their own
- Worst case: `eseutil /r E00 /l <logpath> /d <dbpath>` for manual replay
- Absolute worst case: restore from backup

The single-command dismount in step 1 is what separates "clean recovery" from "page through error-level event logs for an hour."

---

## Startup Procedure

After any shutdown, bringing it back up has its own order.

### Pre-boot checklist

- DC(s) powered on and AD functional BEFORE Exchange boots. Exchange won't start properly without AD
- DNS working (test from a laptop: `Resolve-DnsName exch01.your.domain`)
- Witness server online (if separate from a DC)
- Network infrastructure (switches, firewalls, LB) back up and working
- Storage (SAN/iSCSI) up before the Exchange servers, if you use it

### Boot order for a two-server DAG

**1. Boot the server that was shut down LAST first.** This is the one that held the databases when the DAG went offline. In our example, that was EXCH01.

Why: this server has the most current copy of every database. Booting it first means it becomes active for its databases naturally, then EXCH02 seeds from it when it comes up.

**2. On EXCH01 after Windows is fully up:**

```powershell
# Verify cluster service started
Get-Service ClusSvc

# If cluster node shows Paused (it would be, from shutdown):
Resume-ClusterNode -Name EXCH01

# Check databases — they may auto-mount or may need manual mount
Get-MailboxDatabase -Status | Format-Table Name, Mounted, MountedOnServer

# If any aren't mounted:
Get-MailboxDatabase | Where-Object {-not $_.Mounted} | Mount-Database

# Take out of maintenance mode
Set-MailboxServer EXCH01 -DatabaseCopyActivationDisabledAndMoveNow $false
Set-MailboxServer EXCH01 -DatabaseCopyAutoActivationPolicy Unrestricted
Set-ServerComponentState EXCH01 -Component ServerWideOffline -State Active -Requester Maintenance
Set-ServerComponentState EXCH01 -Component HubTransport -State Active -Requester Maintenance

# Verify services
Test-ServiceHealth -Server EXCH01
Get-Queue -Server EXCH01
```

**3. Add EXCH01 back to load balancer.** Let it take user traffic alone for now.

**4. Boot EXCH02.**

**5. On EXCH02 after Windows is fully up:**

```powershell
# Cluster node
Get-ClusterNode
Resume-ClusterNode -Name EXCH02

# Exchange services — should auto-start
Get-Service MSExchange* | Where-Object Status -ne Running
Get-Service MSExchange* | Where-Object {$_.Status -ne 'Running' -and $_.StartType -eq 'Automatic'} | Start-Service

# Take out of maintenance
Set-MailboxServer EXCH02 -DatabaseCopyActivationDisabledAndMoveNow $false
Set-MailboxServer EXCH02 -DatabaseCopyAutoActivationPolicy Unrestricted
Set-ServerComponentState EXCH02 -Component ServerWideOffline -State Active -Requester Maintenance
Set-ServerComponentState EXCH02 -Component HubTransport -State Active -Requester Maintenance

# Check database copies are seeding/catching up
Get-MailboxDatabaseCopyStatus -Server EXCH02 |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState
```

**6. Wait for copies to catch up.** Can take 10-60+ minutes depending on how long the outage lasted and how much changed. Don't re-add EXCH02 to the LB pool until copies are Healthy.

**7. Rebalance databases.** Put them back where they belong by activation preference:

```powershell
cd $env:ExchangeInstallPath\Scripts
.\RedistributeActiveDatabases.ps1 -DagName <YourDAGName> -BalanceDbsByActivationPreference -Confirm:$false
```

**8. Add EXCH02 back to LB pool.** Wait for two successful health probes.

**9. Post-startup verification:**

```powershell
# Compare to pre-shutdown baseline
Get-MailboxDatabase -Status |
    Select-Object Name, Server, Mounted, MountedOnServer, ActivationPreference
# Compare vs C:\ExchangeOps\pre-shutdown-dbstate.csv

# All healthy
Get-ServerComponentState EXCH01,EXCH02 | Where-Object State -ne Active
Test-ReplicationHealth -Server EXCH01; Test-ReplicationHealth -Server EXCH02
Get-MailboxDatabaseCopyStatus * |
    Format-Table Name, Status, CopyQueueLength, ReplayQueueLength, ContentIndexState

# Mail flow test — send from external address, confirm delivery
```

---

## Common startup problems

| Symptom | Cause | Fix |
|---|---|---|
| Databases won't mount | Dirty shutdown (services killed too hard) | `eseutil /mh <db>` to check state; `eseutil /r` to replay logs |
| `Mount-Database` says "copy not up to date" | DB active on the other node already | Check `MountedOnServer`; use `Move-ActiveMailboxDatabase` if needed |
| Cluster service won't start | Witness unreachable → quorum issue | Check witness server is up; as last resort force quorum (`Start-ClusterNode -ForceQuorum`) |
| EXCH02 copies stuck Failed after startup | Logs are too far behind, reseed needed | `Update-MailboxDatabaseCopy -Identity "DB01\EXCH02" -DeleteExistingFiles` |
| Content index Crawling forever | Index got corrupt during outage | `Update-MailboxDatabaseCopy -Identity "DB01\EXCH01" -CatalogOnly` |
| OWA/ECP broken after boot | IIS didn't start properly | `iisreset /noforce`; check WAS and W3SVC services |
| Mail flow works internally, fails externally | LB pool still marked both nodes down, or MX smart-host stale | Re-verify LB health probes, check external MTA is still pointed at you |
| Both servers fighting for active copy | Witness down, split-brain | Shut one node, bring witness up first, then start both nodes |

---

## Critical discipline reminders

**Never hard-power-off (force power) unless:**

- Graceful shutdown has been hanging for 10+ minutes AND
- You've already tried `Stop-Computer -Force` AND
- There's an imminent risk bigger than data corruption (fire, real flood, active attack)

**Never boot both DAG members simultaneously.** Boot the one that was shut down last first, verify healthy, then boot the second. Parallel boot causes cluster quorum races and occasionally split-brain if the witness comes up slowly.

**Never skip the health check after startup.** A DAG that boots with copies in `Failed` or content indexes stuck doesn't fix itself. You might not notice for days, and then discover you've had no redundancy the whole time.

**Always dismount before shutdown if at all possible.** Single command, 30 seconds, prevents most painful recovery scenarios. Even in emergencies, it's usually worth the time.

---

## One-liner cheatsheet

Stick this on a Post-it:

```powershell
# Clean single-server shutdown (this server)
Get-MailboxDatabase | Where-Object Server -eq $env:COMPUTERNAME | ForEach-Object { Move-ActiveMailboxDatabase -Identity $_.Name -ActivateOnServer <OtherServer> -Confirm:$false }
Set-MailboxServer $env:COMPUTERNAME -DatabaseCopyAutoActivationPolicy Blocked
Suspend-ClusterNode -Name $env:COMPUTERNAME
Get-Service MSExchange* | Stop-Service -Force
Stop-Computer -Force

# Emergency "get it down" (both servers, from one EMS)
Get-MailboxDatabase | Dismount-Database -Confirm:$false
Invoke-Command -ComputerName EXCH01,EXCH02 { Get-Service MSExchange* | Stop-Service -Force }
Stop-Computer -ComputerName EXCH02 -Force
Stop-Computer -ComputerName EXCH01 -Force

# "We have 30 seconds" ultimate triage
Get-MailboxDatabase | Dismount-Database -Confirm:$false
Stop-Computer -ComputerName EXCH01,EXCH02 -Force
```

---

## Want me to script this?

Three scripts would cover 95% of what you do:

**`graceful-shutdown.ps1 [EXCH01|EXCH02|both]`** — runs Procedure A or B depending on argument.

**`emergency-shutdown.ps1`** — runs Procedure C — dismounts, stops services on both, powers off.

**`dag-startup.ps1`** — post-boot helper that waits for services, exits maintenance, checks copy health, and rebalances.

Combined with the `maint-mode-enter/exit` and `health-check` scripts from the upgrade playbook, you'd have a full DAG operations toolkit.
