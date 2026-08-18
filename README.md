# libvirt — Practical Guide & Lab

A practical repository for working with **libvirt-based virtualization** using tools like KVM/QEMU.

This project focuses on:

- Real-world configuration examples
- Automation and scripting
- Infrastructure labs (AD, DNS, VPN, etc.)
- Troubleshooting common virtualization issues

---

## 🚀 Overview

**libvirt** is a toolkit that provides a unified API to manage virtualization platforms such as KVM, QEMU, Xen, and more.

This repository is **not a library**, but a **hands-on lab + reference** to:

- Deploy virtual machines
- Configure networks and storage
- Automate infrastructure setups
- Experiment with enterprise environments

---

## 📦 Features

- 🖥️ VM provisioning using `virsh` and XML
- 🌐 Network configuration (NAT, bridge)
- 💾 Storage pools and volumes
- 🔐 Integration with enterprise services (AD, DNS, DHCP)
- ⚙️ Automation scripts
- 🧪 Lab environments (multi-VM setups)

---

## 🛠️ Requirements

- Linux host (recommended: Ubuntu / RHEL / openSUSE)
- KVM support enabled (CPU virtualization)
- Packages:

  ```bash
  sudo apt install qemu-kvm libvirt-daemon-system virt-manager
  ```

Verify installation:

```bash
virsh list --all
```

---

## ⚡ Quick Start

Start the libvirt service:

```bash
sudo systemctl enable --now libvirtd
```

Check status:

```bash
systemctl status libvirtd
```

Create a VM (example):

```bash
virt-install \
  --name test-vm \
  --ram 2048 \
  --vcpus 2 \
  --disk size=20 \
  --os-variant ubuntu22.04 \
  --network network=default \
  --graphics none \
  --console pty,target_type=serial \
  --location 'http://archive.ubuntu.com/ubuntu/dists/jammy/main/installer-amd64/'
```

---

## 🧩 Repository Structure

```
.
├── xml/            # VM definitions (domain XML)
├── scripts/        # Automation scripts
├── network/        # Network configurations
├── storage/        # Storage pools and volumes
├── lab/            # Multi-VM environments
└── docs/           # Additional documentation
```

---

## 🧪 Example: VM XML

Basic domain definition:

```xml
<domain type='kvm'>
  <name>example-vm</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
</domain>
```

libvirt uses XML to define virtual machines, including CPU, memory, and devices.

---

## 🌐 Networking

Default network:

```bash
virsh net-start default
virsh net-autostart default
```

Bridge example (manual setup required):

- Create bridge interface
- Attach VM NIC to bridge

---

## 💾 Storage

List storage pools:

```bash
virsh pool-list --all
```

Create a volume:

```bash
virsh vol-create-as default vm1.qcow2 20G
```

---

## 🔐 Use Cases

- Active Directory lab environments
- VPN servers (RRAS, WireGuard)
- Web servers (IIS / Nginx)
- Multi-tier architectures

---

## 🐞 Troubleshooting

Common checks:

```bash
sudo journalctl -u libvirtd
virsh list --all
virsh dominfo <vm>
```

Permissions issue:

```bash
sudo usermod -aG libvirt $USER
```

---

## 📚 Resources

- Official documentation: https://libvirt.org
- Domain XML reference
- `virsh` command reference

---

## 🤝 Contributing

Contributions are welcome:

- Improve scripts
- Add lab scenarios
- Fix issues or documentation

---

## 📄 License

MIT License (or specify your preferred license)

---

## ⭐ Notes

This repository is intended as a **learning + practical lab environment**, not a production-ready framework.

---
