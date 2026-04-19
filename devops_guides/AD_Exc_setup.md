# AD
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/ad01.qcow2 80G && sudo chown root:qemu /var/lib/libvirt/images/ad01.qcow2 && sudo chmod 660 /var/lib/libvirt/images/ad01.qcow2

# Exchange
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/exch01-os.qcow2 100G && sudo qemu-img create -f qcow2 /var/lib/libvirt/images/exch01-data.qcow2 100G && sudo chown root:qemu /var/lib/libvirt/images/exch01-*.qcow2 && sudo chmod 660 /var/lib/libvirt/images/exch01-*.qcow2

# Install Windows into AD disk (with ISO)
sudo virt-install --name ad01 --memory 4096 --vcpus 2 --cpu host-passthrough --disk path=/var/lib/libvirt/images/ad01.qcow2,format=qcow2,bus=sata,cache=none --cdrom /var/lib/libvirt/images/SERVER_EVAL_x64FRE_en-us.iso --network network=default,model=e1000e --os-variant win2k22 --graphics spice

# Install Windows into Exchange disks (with ISO)
sudo virt-install --name exch01 --memory 16384 --vcpus 4 --cpu host-passthrough --disk path=/var/lib/libvirt/images/exch01-os.qcow2,format=qcow2,bus=sata,cache=none --disk path=/var/lib/libvirt/images/exch01-data.qcow2,format=qcow2,bus=sata,cache=none --cdrom /var/lib/libvirt/images/SERVER_EVAL_x64FRE_en-us.iso --network network=default,model=e1000e --os-variant win2k22 --graphics spice
