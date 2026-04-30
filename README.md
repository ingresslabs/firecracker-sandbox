# Firecracker Sandbox

Small Makefile toolkit for building and running local Firecracker microVMs with
tap networking, console access, snapshots, and cleanup commands.

Background: [Secure CI/CD Isolation With Firecracker And Wireguard](https://medium.com/@antonvkrylov/secure-ci-cd-isolation-with-firecracker-and-wireguard-2df3aef6c64a)

## Requirements

- Linux host with KVM support
- Firecracker installed and available on `PATH`
- `sudo`, `iproute2`, `iptables`, `screen`, and `curl`
- Build tools for kernel/rootfs generation
- A valid `vm-config.json`

## Quick Start

```bash
# Build kernel and rootfs artifacts.
make build-all

# Start the VM in a detached screen session.
make up-detached

# Attach to the VM console.
make login

# Inspect and stop the VM.
make list-vms
make down
```

`make build-all` produces the default `vmlinux` and
`firecracker-rootfs.ext4` artifacts used by `vm-config.json`.

## Common Targets

| Target | Purpose |
| --- | --- |
| `make build-kernel` | Build the latest stable Linux kernel. |
| `make build-rootfs` | Create a Debian rootfs matched to the kernel. |
| `make build-all` | Build kernel and rootfs artifacts. |
| `make net-up` | Create `tap0`, NAT, and forwarding rules. |
| `make net-down` | Remove Firecracker networking rules. |
| `make up` | Start the VM in the foreground. |
| `make up-detached` | Start the VM in a detached screen session. |
| `make login` | Attach to the running VM console. |
| `make list-vms` | Show running Firecracker processes. |
| `make net-info` | Show host/VM network details. |
| `make snapshot` | Save a snapshot of the running VM. |
| `make restore SNAPSHOT=<name>` | Restore a saved snapshot. |
| `make down` | Stop VMs and remove runtime sockets. |

## VM Network

The default host interface is `tap0` at `192.168.1.1/24`; the expected VM
address is `192.168.1.2/24`. Rootfs images created by the included tooling are
configured for this layout.

For a custom rootfs, configure the guest network manually:

```bash
ip addr add 192.168.1.2/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.1.1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

## Console

`make login` attaches to the VM console. To detach without stopping the VM,
press `Ctrl+a`, then `d`.

## Notes

- `net-up` and `net-down` change host networking and require care.
- Some targets require `sudo`.
- Runtime files such as sockets and logs are cleaned by `make down`.

## License

MIT. See [LICENSE](LICENSE).
