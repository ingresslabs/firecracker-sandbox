# Firecracker Sandbox

Firecracker Sandbox is a small Makefile toolkit for building and running local Firecracker microVMs. It helps create kernel and rootfs artifacts, configure tap networking, start or stop VMs, attach to the console, inspect running processes, and save or restore snapshots.

Use it on a Linux host with KVM, Firecracker on PATH, sudo-capable networking tools, and a valid `vm-config.json`. Run `make build-all`, `make up-detached`, `make login`, and `make down` for the basic workflow.

MIT licensed.
