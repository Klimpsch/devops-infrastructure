# KVM + Active Directory

Single-forest Windows Server 2022 domain controller in a libvirt VM — the foundation half of the two-VM Windows lab. Pair with the [KVM + Exchange](../kvm-exchange/README.md) guide for mail.

## Provision the VM

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/ad01.qcow2 80G && sudo chown root:qemu /var/lib/libvirt/images/ad01.qcow2 && sudo chmod 660 /var/lib/libvirt/images/ad01.qcow2
```

## Install Windows into the AD disk (with ISO)

```bash
sudo virt-install --name ad01 --memory 4096 --vcpus 2 --cpu host-passthrough --disk path=/var/lib/libvirt/images/ad01.qcow2,format=qcow2,bus=sata,cache=none --cdrom /var/lib/libvirt/images/SERVER_EVAL_x64FRE_en-us.iso --network network=default,model=e1000e --os-variant win2k22 --graphics spice
```

## 1. Static IP + point DNS at self

AD requires a static IP; DNS must point at 127.0.0.1 so this DC resolves itself.

```powershell
Get-NetAdapter    # note the InterfaceAlias, usually "Ethernet"

New-NetIPAddress -InterfaceAlias "Ethernet" `
  -IPAddress 192.168.122.10 -PrefixLength 24 -DefaultGateway 192.168.122.1

Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 127.0.0.1
```

## 2. Install OpenSSH Server

```powershell
# 1. Install the OpenSSH Server capability
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# 2. Start the service and set it to auto-start
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# 3. Open the firewall (the installer usually creates this rule, but confirm)
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# 4. Make PowerShell the default shell (so `ssh user@host` drops you into pwsh, not cmd)
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```

Same steps packaged as [`enable-ssh.ps1`](../windows-enable-ssh/enable-ssh.ps1).

## 3. Rename the computer

Do this BEFORE promoting to DC — renaming a DC afterwards is painful.

```powershell
Rename-Computer -NewName "DC01" -Restart
```

VM reboots. Log back in.

## 4. Install the AD DS role

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
```

## 5. Promote to Domain Controller (creates a new forest)

DSRM password is for Directory Services Restore Mode recovery, not daily use.

```powershell
$DSRMPassword = ConvertTo-SecureString "P@ssw0rd!LabOnly" -AsPlainText -Force

Install-ADDSForest `
  -DomainName "lab.local" `
  -DomainNetbiosName "LAB" `
  -InstallDns:$true `
  -SafeModeAdministratorPassword $DSRMPassword `
  -Force:$true
```

VM reboots automatically. Login screen now shows `LAB\Administrator`.

## 6. Verify AD is healthy

```powershell
Get-Service adws, kdc, netlogon, dns   # all should be Running
Get-ADDomainController                 # should list DC01
Get-ADDomain                           # should show lab.local
```

## 7. (Optional) Test OU + user

```powershell
New-ADOrganizationalUnit -Name "LabUsers" -Path "DC=lab,DC=local"

New-ADUser -Name "Jane Doe" -SamAccountName "jane.doe" `
  -UserPrincipalName "jane.doe@lab.local" `
  -Path "OU=LabUsers,DC=lab,DC=local" `
  -AccountPassword (ConvertTo-SecureString "TempP@ss123!" -AsPlainText -Force) `
  -Enabled $true -ChangePasswordAtLogon $true
```
