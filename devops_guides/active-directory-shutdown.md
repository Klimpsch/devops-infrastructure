# Active Directory — Shutdown Procedure (Two-DC Setup)

**Scope:** Planned shutdown of two domain controllers (DC01, DC02) replicating to each other.

**Use cases:**

- Full datacenter power-down (UPS test, electrical work)
- Both DCs need to go down together
- Single DC shutdown for hardware maintenance
- Emergency shutdown (imminent power loss, fire alarm)

---

## Decide which scenario applies

| Scenario | Procedure |
|---|---|
| One DC down, other stays up (hardware maintenance) | **Procedure A** — single DC graceful shutdown |
| Both DCs down (planned full outage) | **Procedure B** — full DC shutdown |
| Emergency — both down NOW | **Procedure C** — fast controlled shutdown |
| Imminent power loss (seconds) | **Procedure D** — minimum-damage emergency |

---

## Key principle

AD is more forgiving of abrupt shutdowns than Exchange — the ESE database engine under NTDS is designed for crash recovery. That said, dirty shutdowns can still cause:

- Replication hiccups requiring manual sync after reboot
- Tombstone inconsistencies
- USN issues in rare cases
- SYSVOL/DFSR recovery cycles that take longer

Graceful > abrupt, always. But don't panic if something forces an abrupt shutdown — AD usually survives.

---

## Before any planned shutdown

### Health check

```powershell
# Replication healthy
repadmin /replsummary
dcdiag /e /q

# Services running
Invoke-Command -ComputerName DC01,DC02 {
    Get-Service NTDS, Netlogon, DNS, KDC, DFSR, W32Time |
        Where-Object Status -ne Running
}
# ^ expect empty

# FSMO location
netdom query fsmo > C:\ADOps\fsmo-before-shutdown.txt
```

Fix any issues before shutting down — you don't want to restart into a broken state.

### Communicate

- Anything that depends on AD (Exchange, file servers, SQL, apps using Kerberos/LDAP) will have authentication issues during a full AD outage
- Notify dependent-system owners in advance
- During a full shutdown, new logons fail, cached credentials on already-logged-in machines still work briefly

### Identify dependent services

Things that break when AD is fully down:

- Kerberos authentication (domain logons)
- LDAP queries
- DNS (if DNS is hosted on the DCs — very common)
- GPO processing
- Exchange (needs AD + DNS)
- SQL Server Windows Auth
- File server permissions for domain users
- VPN/wireless if using RADIUS against AD

For a full shutdown (Procedure B), consider whether dependent services should be shut down first too.

---

## Procedure A — Single DC Graceful Shutdown

**Scenario:** Taking ONE DC down for hardware maintenance, OS upgrade prep, etc. Other DC stays up and serves users.

### 1. Verify the OTHER DC is healthy

Critical — if the surviving DC isn't healthy, don't shut down the first one.

Assuming you're shutting down DC02:

```powershell
# DC01 should be fully healthy
dcdiag /s:DC01 /q
Invoke-Command -ComputerName DC01 {
    Get-Service NTDS, Netlogon, DNS, KDC | Where-Object Status -ne Running
}

# Replication clean between the two
repadmin /showrepl DC01
repadmin /showrepl DC02
```

### 2. Check if DC02 holds any FSMO roles

```powershell
netdom query fsmo
```

If DC02 has FSMO roles and the shutdown will last more than 30-60 min, transfer them to DC01 first:

```powershell
Move-ADDirectoryServerOperationMasterRole -Identity DC01 `
    -OperationMasterRole SchemaMaster, DomainNamingMaster, PDCEmulator,
                         RIDMaster, InfrastructureMaster -Confirm:$false

# Verify
netdom query fsmo
```

For a quick reboot (under 30 min), FSMO unavailability is usually harmless. For extended outages, always transfer.

### 3. Verify clients will use DC01 after DC02 is down

DNS SRV records and load balancing usually handle this automatically — but check:

```powershell
nslookup -type=srv _ldap._tcp.dc._msdcs.your.domain
# Should return both DCs. Clients that can't reach DC02 will use DC01.
```

If you have machines hardcoded to use DC02 for DNS, update them first.

### 4. Force a final replication sync

```powershell
# Push any pending changes from DC02 to DC01 before shutdown
repadmin /syncall DC02 /AdeP
```

### 5. Shut down Windows gracefully

```powershell
# On DC02
Stop-Computer -Force
```

Or from OOB console with a graceful power action. Don't hard-power-off.

### 6. Verify DC01 is handling everything

```powershell
# From DC01 or a workstation
dcdiag /s:DC01 /q
nslookup something.your.domain    # DNS still working?

# Test a user logon or GPO refresh from a workstation
gpupdate /force
```

At this point DC01 is running the whole domain alone. Users see no impact (aside from the brief moment DC02 went away, which should be invisible).

### When DC02 comes back

See **Startup Procedure** at the end.

---

## Procedure B — Full AD Shutdown (both DCs)

**Scenario:** Planned full AD outage. Both DCs down at the same time.

### Pre-flight

- **Shut down dependent services first** if they're also going down:
  - Exchange, SQL, file servers, application servers
  - Better to shut them down cleanly while AD is up than let them die when AD goes away
- Warn users about cached-credential behavior:
  - Domain-joined machines already logged in will work with cached creds for a while
  - New logons will fail until AD is back
  - Kerberos tickets expire after ~10 hours by default

### 1. Final health check and baseline

```powershell
repadmin /replsummary
dcdiag /e /q
netdom query fsmo > C:\ADOps\fsmo-before-full-shutdown.txt

# Force final replication both ways
repadmin /syncall DC01 /AdeP
repadmin /syncall DC02 /AdeP
```

Wait for any pending replication to complete:

```powershell
repadmin /showrepl DC01
repadmin /showrepl DC02
# USN numbers should be converged
```

### 2. Decide shutdown order

Shut down the **DC without FSMO roles first**, then the FSMO holder. This way:

- FSMO operations stay available as long as possible
- The last DC down (the FSMO holder) is the first one to bring up on restart
- Replication state at shutdown time is clearer (last DC has the most current data)

Assuming DC02 is secondary (no FSMO) and DC01 is primary (all FSMO):

### 3. Shut down DC02 first

```powershell
# On DC02
Stop-Computer -Force
```

Wait for it to fully power off (3-5 min for graceful shutdown). Verify via OOB console on physical hardware.

### 4. Verify DC01 is still happy running alone

```powershell
# On DC01 or a workstation
dcdiag /s:DC01 /q
Get-Service NTDS, Netlogon, DNS, KDC -ComputerName DC01 |
    Where-Object Status -ne Running
```

### 5. Shut down DC01

```powershell
# On DC01
Stop-Computer -Force
```

The domain is now offline. Cached logins continue to work on already-logged-in machines for a while; new authentications against the domain will fail.

### Optional: shut down dependent servers in order

If this is part of a bigger datacenter shutdown, a reasonable order is:

1. Application servers (Exchange, SQL, file servers)
2. DC02 (secondary AD)
3. DC01 (primary AD / FSMO holder)
4. DNS-only or other infrastructure servers
5. Network infrastructure (switches, firewalls) — if applicable

Reverse on startup.

---

## Procedure C — Emergency But Controlled Shutdown

**Scenario:** Something's wrong, you need both DCs down in 5-10 minutes. Not pulling the plug, but not luxuriating either.

### 1. Skip the careful sync dance

```powershell
# Quick health snapshot (optional, skip if really rushed)
repadmin /replsummary
```

### 2. Shut down both

Do them sequentially, not in parallel — in parallel you'll have 5 seconds where both are half-shutting-down and that's worse than just being fast:

```powershell
# On DC02 first
Stop-Computer -Force -ComputerName DC02

# Wait ~60 seconds for DC02 to actually go down
Start-Sleep -Seconds 60

# Then DC01
Stop-Computer -Force -ComputerName DC01
```

Or via OOB: trigger graceful power action on DC02, wait a minute, trigger on DC01.

### 3. Confirm power-off via OOB

On physical hardware, verify both servers actually powered down. If either is hung past 5 minutes at "Shutting down," force-off via OOB. Dirty but acceptable in emergencies.

---

## Procedure D — Minimum-Damage Emergency

**Scenario:** Imminent power loss. You have seconds.

### The triage

Unlike Exchange, AD doesn't have a "dismount database" equivalent — NTDS.dit stays mounted as long as the service runs. The best you can do in seconds is:

```powershell
# Stop NTDS cleanly — flushes the database
Stop-Service NTDS -Force
```

Or just trigger fast shutdown on both:

```powershell
Stop-Computer -ComputerName DC01,DC02 -Force
```

Or physical power button (graceful shutdown signal, not hard-off — requires holding for 4+ seconds for hard power-off).

### If power dies mid-shutdown

AD almost always recovers on its own. On next boot:

- ESE replays the transaction log automatically
- NTDS service starts, DC rejoins replication
- Expect ~5-10 min of log replay delay on startup
- Replication catches up from the partner DC

Worst case (rare): USN rollback detection. Recovery requires forced demotion and re-promotion of the affected DC, which is hours of work but not catastrophic as long as the OTHER DC is fine.

### Don't do these

- **Don't hard-power-off both DCs if you can help it.** If you must cut power, prefer to do it to one DC at a time 30 seconds apart — gives AD a chance to see one going away and flush state.
- **Don't revert VM snapshots of running DCs** after an emergency shutdown. USN rollback territory.

---

## Startup Procedure

### Boot order

**Boot the DC that was shut down LAST first.** That one had the most current database state when it went offline.

In Procedure B, that's the FSMO holder (DC01 in our example).

### 1. Boot DC01 first

Let it come fully up. Physical servers: 5-15 min for POST, RAID, Windows boot, services.

### 2. Verify DC01 is functioning alone

Once Windows is up, give it another 5 minutes for services to fully initialize, then:

```powershell
# Services running
Get-Service NTDS, Netlogon, DNS, KDC, DFSR, W32Time |
    Where-Object Status -ne Running
# ^ expect empty

# DC advertising itself
dcdiag /s:DC01 /test:advertising

# FSMO roles still owned correctly
netdom query fsmo

# DNS working
Resolve-DnsName DC01.your.domain
nslookup -type=srv _ldap._tcp.dc._msdcs.your.domain

# Replication partnerships visible (DC02 will show as failed until it boots)
repadmin /showrepl DC01
```

At this point DC01 should be fully functional. Users can log in, Kerberos works, DNS resolves.

### 3. Boot DC02

### 4. Verify DC02 joins replication

After DC02's services are up:

```powershell
# Services up
Get-Service NTDS, Netlogon, DNS -ComputerName DC02 |
    Where-Object Status -ne Running

# Replicating with DC01
repadmin /showrepl DC02

# Force a sync to catch up anything missed during the outage
repadmin /syncall DC02 /AdeP
```

### 5. Full health check

```powershell
repadmin /replsummary
dcdiag /e /q

# Any errors in Directory Service event log on either DC?
Get-WinEvent -LogName "Directory Service" -MaxEvents 50 -ComputerName DC01 |
    Where-Object {$_.LevelDisplayName -in 'Error','Critical'}
Get-WinEvent -LogName "Directory Service" -MaxEvents 50 -ComputerName DC02 |
    Where-Object {$_.LevelDisplayName -in 'Error','Critical'}
```

### 6. Compare FSMO layout to baseline

```powershell
netdom query fsmo
# Compare to C:\ADOps\fsmo-before-shutdown.txt

# If something drifted (rare), transfer back:
# Move-ADDirectoryServerOperationMasterRole -Identity DC01 -OperationMasterRole ...
```

### 7. Start dependent services

If you shut down Exchange, SQL, file servers, etc. during the outage, bring them up now — in order of dependencies. AD/DNS must be fully healthy before starting AD-dependent services.

---

## Common startup problems

| Symptom | Cause | Fix |
|---|---|---|
| NTDS won't start after reboot | Dirty shutdown mid-transaction | Usually auto-recovers after 5-10 min; check Directory Service event log. Worst case, offline defrag: `ntdsutil` |
| `repadmin` errors about USN | USN rollback detected (extremely rare from normal shutdown) | Force-demote affected DC, clean metadata, re-promote |
| DC02 boots but stays isolated | DNS issue — can't find DC01 | Check DNS client config on DC02, verify DC02 points at DC01 as primary DNS |
| Clients can't authenticate | Time drift during outage | `w32tm /resync` on both DCs; ensure PDC syncs from external NTP |
| DNS queries fail | DNS service didn't start or has no data | `Restart-Service DNS`; if zones are empty, check AD-integrated DNS replicated properly |
| SYSVOL share missing | DFSR didn't converge | `Get-DfsrBacklogInformation`; wait it out or force replication |
| Group Policy processing slow | Stale KDC tickets after outage | `klist purge` on clients, or wait for tickets to renew |

---

## The key discipline

Four rules:

1. **Never shut down both DCs simultaneously in parallel.** Sequentially with a 60-second gap minimum.
2. **Boot the last-shutdown DC first.** It has the most current data.
3. **Verify the survivor is healthy before shutting down the second DC.** "Both in an uncertain state" is the worst possible position.
4. **AD forgives more than Exchange.** If a shutdown goes sideways, don't panic — ESE recovery on boot handles most issues automatically.

---

## One-liner cheatsheet

```powershell
# Single DC graceful shutdown (taking DC02 down, DC01 stays up)
# Optional FSMO transfer first if DC02 has them:
Move-ADDirectoryServerOperationMasterRole -Identity DC01 -OperationMasterRole 0,1,2,3,4 -Confirm:$false
Stop-Computer -ComputerName DC02 -Force

# Full AD shutdown (both DCs — sequential, secondary first)
repadmin /syncall DC01 /AdeP
Stop-Computer -ComputerName DC02 -Force
Start-Sleep -Seconds 60
Stop-Computer -ComputerName DC01 -Force

# Emergency (both down, under 2 min)
Stop-Computer -ComputerName DC02 -Force; Start-Sleep 60; Stop-Computer -ComputerName DC01 -Force

# Startup verification (run after both are back)
repadmin /replsummary; dcdiag /e /q; netdom query fsmo; repadmin /syncall /AdeP
```

---

## What's different from the Exchange shutdown procedure

If you've read the Exchange DAG shutdown doc, a few key differences:

- **No database dismount step.** NTDS.dit doesn't get "dismounted" — the service just stops.
- **Less fragile.** AD tolerates dirty shutdowns much better than Exchange mailbox databases do. ESE log replay on boot is fast and reliable.
- **No cluster.** DCs don't use failover clustering. They replicate but each stands alone operationally.
- **No maintenance mode concept.** DCs don't have `Set-ServerComponentState`. You just shut them down.
- **Order matters differently.** For Exchange, you move active DBs. For AD, you move FSMO roles (for long outages only).
- **Caching buys you time.** Users already logged in keep working with cached Kerberos tickets and cached group policies for hours even with all DCs down. Exchange has no such grace period.
