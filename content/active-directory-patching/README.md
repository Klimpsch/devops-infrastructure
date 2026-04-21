# Active Directory — Monthly Windows Updates (Two-DC Setup)

**Scope:** Two domain controllers (DC01, DC02) replicating to each other. Routine monthly Windows Updates / security patches.

**Window estimate:** 2-3 hours total for both DCs.

---

## Core principle

**One DC at a time.** The other stays up and serves authentication, DNS, GPO, etc. Users should see no impact.

---

## Before the window

### 1. Verify baseline health

```powershell
# Both DCs replicating cleanly
repadmin /replsummary

# Comprehensive DC health check
dcdiag /e /q
# (empty output = all good; anything printed = investigate)

# Services healthy on both
Invoke-Command -ComputerName DC01,DC02 -ScriptBlock {
    Get-Service NTDS, Netlogon, DNS, KDC, DFSR, W32Time |
        Where-Object Status -ne Running
}
# ^ expect empty
```

**Any error here = stop.** Fix replication before patching.

### 2. Note which DC holds FSMO roles

```powershell
netdom query fsmo
```

Save the output. Patch the DC **without** FSMO roles first (usually the "secondary"). If all roles are on one DC, patch the other one first.

### 3. Pre-flight checklist

- [ ] Change ticket raised if your org requires one
- [ ] Backup from last 24h (System State)
- [ ] 20+ GB free on C: drive of each DC
- [ ] On-call identified

---

## The window

### PASS 1 — Patch the secondary DC (the one without FSMO roles)

Assuming DC02 is secondary:

#### 1. Install updates

```powershell
# If you have PSWindowsUpdate module:
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot

# Or trigger via built-in tool:
UsoClient ScanInstallWait
# Then reboot manually:
Restart-Computer -Force
```

Or via GUI: Settings → Windows Update → Install now → reboot when prompted.

#### 2. Wait for DC02 to come back

Reboot + service startup: 5-15 min for a standard CU. Longer for big updates. Watch via OOB console if you're worried.

#### 3. Verify DC02 health

```powershell
# Services running?
Invoke-Command -ComputerName DC02 {
    Get-Service NTDS, Netlogon, DNS, KDC | Where-Object Status -ne Running
}
# ^ expect empty

# DC advertising itself?
dcdiag /s:DC02 /test:advertising

# Replicating with DC01?
repadmin /showrepl DC02

# Full health check
dcdiag /s:DC02 /q
```

**Don't proceed to DC01 until DC02 is clean.**

### PASS 2 — Patch the primary DC (holds FSMO roles)

#### 1. (Optional) Transfer FSMO roles to DC02

Only if you expect patching to take more than 30 min. For a typical monthly CU, skip this step — brief FSMO unavailability during reboot is harmless.

```powershell
Move-ADDirectoryServerOperationMasterRole -Identity DC02 `
    -OperationMasterRole SchemaMaster, DomainNamingMaster, PDCEmulator,
                         RIDMaster, InfrastructureMaster -Confirm:$false

netdom query fsmo
# Verify all five now on DC02
```

#### 2. Install updates on DC01

Same method as DC02.

#### 3. Wait for DC01 to return

#### 4. Verify DC01 health

```powershell
Invoke-Command -ComputerName DC01 {
    Get-Service NTDS, Netlogon, DNS, KDC | Where-Object Status -ne Running
}

dcdiag /s:DC01 /q
repadmin /showrepl DC01
```

#### 5. (Optional) Transfer FSMO roles back to DC01

Only if you moved them in step 1:

```powershell
Move-ADDirectoryServerOperationMasterRole -Identity DC01 `
    -OperationMasterRole SchemaMaster, DomainNamingMaster, PDCEmulator,
                         RIDMaster, InfrastructureMaster -Confirm:$false
```

Many admins just leave roles wherever they landed until next maintenance — AD doesn't care which DC holds them as long as one does.

---

## Post-window verification

```powershell
# Both DCs healthy
repadmin /replsummary
dcdiag /e /q

# Force a replication cycle to be sure
repadmin /syncall /AdeP

# FSMO roles as expected
netdom query fsmo

# Quick user-facing test
nslookup -type=srv _ldap._tcp.dc._msdcs.your.domain
# Should return both DCs

# Log into a workstation, reset a password, verify it works
```

---

## Quick reference — full procedure in one block

```powershell
# ========== PRE-CHECK ==========
repadmin /replsummary
dcdiag /e /q
netdom query fsmo

# ========== PATCH DC02 (secondary) ==========
# On DC02:
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot
# Wait for reboot and service startup (5-15 min)

# Verify DC02:
dcdiag /s:DC02 /q
repadmin /showrepl DC02

# ========== PATCH DC01 (primary) ==========
# On DC01:
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot
# Wait for reboot and service startup

# Verify DC01:
dcdiag /s:DC01 /q
repadmin /showrepl DC01

# ========== POST-CHECK ==========
repadmin /replsummary
repadmin /syncall /AdeP
dcdiag /e /q
```

---

## Common issues

| Symptom | Cause / fix |
|---|---|
| DC stuck on "Getting Windows ready" after reboot | Normal for big CUs — wait 20-30 min |
| `repadmin` shows replication errors after patching | Wait 15 min then re-check; if persists, `repadmin /syncall /AdeP` |
| NTDS service won't start | Check Directory Service event log, usually points at the cause |
| DNS service failed to start | DNS depends on Netlogon; if Netlogon started late, restart DNS |
| Users report slow logons post-patch | Time drift — check `w32tm /query /status` on PDC |

---

## Things NOT to do

- **Don't patch both DCs simultaneously.** Ever. Even for a "quick" Defender definition update via GPO.
- **Don't hard-reboot a DC** unless graceful shutdown hung for 15+ min.
- **Don't snapshot a running DC VM as backup** — leads to USN rollback if reverted. Use System State backups or shut the VM down before snapshotting.
- **Don't skip the health check between DCs.** Patching DC01 when DC02 came back broken is how you end up with no working DCs.
