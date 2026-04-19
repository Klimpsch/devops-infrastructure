# Samba share on Fedora for Windows KVM guests

A minimal guide for the common lab case: you've got Windows VMs on libvirt's default network (`192.168.122.0/24`) and you want a folder on the Fedora host they can read and write to.

## Prerequisites

- Fedora host with libvirt running and at least one Windows VM on the `default` network
- A regular user account on Fedora (we'll call it `jack` — swap in your own username throughout)
- A VM you can get a PowerShell prompt on

## 1. Install Samba

```bash
sudo dnf install -y samba
```

## 2. Create the folder to share

```bash
mkdir -p ~/vm-share
```

Apply the right SELinux context so Samba is permitted to read and write inside it — without this the share exists but every access gets denied:

```bash
sudo dnf install -y policycoreutils-python-utils   # if semanage is missing
sudo semanage fcontext -a -t samba_share_t "$HOME/vm-share(/.*)?"
sudo restorecon -R ~/vm-share
```

## 3. Add a Samba user

Samba keeps its own password database separate from Linux. The username must match an existing Linux account; the password can be different from your login password.

```bash
sudo smbpasswd -a "$USER"
```

Enter and confirm the password — this is what you'll type from Windows when mapping the share.

## 4. Declare the share

Append this to `/etc/samba/smb.conf`:

```bash
sudo tee -a /etc/samba/smb.conf >/dev/null <<EOF

[vmshare]
   path = $HOME/vm-share
   valid users = $USER
   read only = no
   browseable = yes
EOF
```

Reload Samba so it picks up the new share:

```bash
sudo systemctl enable --now smb nmb
sudo systemctl reload smb
```

Verify Samba is listening on 445:

```bash
sudo ss -tlnp | grep ':445'
```

Expected: one or two lines showing `smbd` listening on `0.0.0.0:445` (and `[::]:445`).

## 5. Open the firewall — to the right zone

This is the step that catches everyone on Fedora. `firewalld` groups network interfaces into zones. Your wifi/ethernet is in one zone, and `virbr0` (the bridge the VMs live on) is in a different zone — usually `libvirt`. Adding `samba` to the default zone does nothing for VM traffic.

Find which zone `virbr0` is in:

```bash
sudo firewall-cmd --get-zone-of-interface=virbr0
```

Add the `samba` service to that zone:

```bash
# Replace 'libvirt' with whatever the above reported
sudo firewall-cmd --zone=libvirt --permanent --add-service=samba
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --zone=libvirt --list-services
```

You should see `samba` in the list. Keeping it scoped to the `libvirt` zone means the share is reachable from VMs but *not* from anyone else on the wifi or ethernet you're on, which is what you want.

## 6. Test from Fedora (optional but useful)

A quick sanity check before touching the VM. `smbclient -L` may warn about SMB1 being disabled — that's harmless; connect directly to the named share instead:

```bash
sudo smbclient //192.168.122.1/vmshare -U "$USER"
```

Enter the `smbpasswd` password. At the `smb: \>` prompt, type `ls` to list contents, then `exit`.

## 7. Map the share from Windows

Inside the VM, open **PowerShell as Administrator**:

```powershell
# Confirm TCP 445 is reachable
Test-NetConnection 192.168.122.1 -Port 445
# Expect: TcpTestSucceeded : True

# Clear any cached failed credentials from earlier attempts
net use * /delete /y

# Map the share to Z:
net use Z: \\192.168.122.1\vmshare /user:jack *
# The * prompts for the password interactively
```

Replace `jack` with the Samba username from step 3. Enter the `smbpasswd` password when prompted.

Test it:

```powershell
Z:
dir
echo "hello from windows" > test.txt
```

Back on Fedora, the file should appear:

```bash
cat ~/vm-share/test.txt
```

## 8. Make the mapping persistent (optional)

The `net use` above disappears after reboot. To keep it:

```powershell
net use Z: \\192.168.122.1\vmshare /user:jack your-password /persistent:yes
```

Putting the password on the line is obviously less private than the `*` prompt, so only do this if you're comfortable with that.

## Troubleshooting

**"Network path not found"** — TCP 445 isn't reaching Samba. 95% of the time it's the firewall zone (step 5). Confirm with:

```powershell
Test-NetConnection 192.168.122.1 -Port 445
```

If that's `False`, fix the zone. If it's `True`, the path is fine and the problem is auth.

**"Access denied" after successful connection** — the user exists but doesn't match what Samba expects. Re-run `smbpasswd -a "$USER"` on Fedora, then in the VM:

```powershell
net use * /delete /y
cmdkey /delete:192.168.122.1
net use Z: \\192.168.122.1\vmshare /user:jack *
```

**Can read but not write** — SELinux context is wrong, or the share is `read only = yes`. Re-run:

```bash
sudo semanage fcontext -a -t samba_share_t "$HOME/vm-share(/.*)?"
sudo restorecon -R ~/vm-share
```

And confirm your `smb.conf` entry has `read only = no`.

**"Multiple connections to a server by the same user"** — Windows already has a connection (even an expired one) to that host with different credentials. Clean it with `net use * /delete /y` and try again.

## Security note

This setup is deliberately loose — password-only auth, SMB on your host, no encryption forced. Fine for an isolated lab network (`192.168.122.0/24` is NAT'd and not reachable from outside). For anything real, force SMB3 encryption in `[global]` with `server smb encrypt = required`, use stronger passwords, and consider per-share `hosts allow = 192.168.122.0/24`. For a temporary lab file-drop, the defaults are fine.
