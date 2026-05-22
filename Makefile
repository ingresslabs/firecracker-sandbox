.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo "  activate    - Create and activate the Firecracker API socket at /tmp/firecracker.socket."
	@echo "                This is required before starting the MicroVM."
	@echo "  deactivate  - Deactivate and clean up the Firecracker API socket."
	@echo "                Removes the socket file from /tmp."
	@echo "  net-up      - Set up networking for Firecracker MicroVM."
	@echo "                Creates a tap0 device, assigns an IP, enables IP forwarding, and sets up NAT."
	@echo "  net-down    - Clean up networking resources."
	@echo "                Removes the tap0 device and clears Firecracker-specific iptables rules."
	@echo "  up          - Start the Firecracker MicroVM using the configuration in config.json."
	@echo "  up-detached - Start the Firecracker MicroVM in the background (detached mode)."
	@echo "                Allows you to login separately using 'make login'."
	@echo "  down        - Stop all Firecracker instances and clean up resources."
	@echo "                Includes stopping the VM, cleaning up networking, and deactivating the API socket."
	@echo "  build-kernel - Download and build the latest stable Linux kernel for Firecracker."
	@echo "  build-rootfs - Create a Debian rootfs that matches the latest kernel."
	@echo "  build-all    - Build both the kernel and rootfs for Firecracker."
	@echo "  wireguard-e2e - Install WireGuard on WG_REMOTE and run an end-to-end tunnel test."
	@echo "  lab-up      - Provision WireGuard, boot a Firecracker VM, and SSH-test it."
	@echo "  lab-down    - Stop the remote Firecracker lab VM and remove lab networking."
	@echo "  login       - Attempt to log into the running MicroVM via vsock socket."
	@echo "  list-vms    - List all running Firecracker MicroVMs with their details."
	@echo "  net-info    - Display network information for running MicroVMs."
	@echo "  snapshot    - Create a snapshot of the running MicroVM."
	@echo "  restore     - Restore a MicroVM from a snapshot."
	@echo "  help        - Show this help message."

.PHONY: activate
activate:
	@echo "Creating and activating the Firecracker API socket..."
	@rm -f /tmp/firecracker.socket
	@mkfifo /tmp/firecracker.socket
	@chmod 660 /tmp/firecracker.socket
	@echo "Firecracker API socket activated at /tmp/firecracker.socket"

.PHONY: deactivate
deactivate:
	@echo "Deactivating and cleaning up the Firecracker API socket..."
	@rm -f /tmp/firecracker.socket
	@echo "Firecracker API socket deactivated and cleaned up."

.PHONY: net-up
net-up:
	@echo "Setting up networking for Firecracker MicroVM..."
	@echo "Creating tap0 device..."
	@sudo ip tuntap add tap0 mode tap || true
	@sudo ip link set tap0 up
	@echo "Assigning IP address to tap0..."
	@sudo ip addr add 192.168.1.1/24 dev tap0 || true
	@echo "Enabling IP forwarding..."
	@sudo sysctl -w net.ipv4.ip_forward=1
	@echo "Setting up NAT with iptables..."
	@sudo iptables -t nat -N FIRECRACKER-NAT || true
	@sudo iptables -t nat -A FIRECRACKER-NAT -o $(shell ip route | grep default | awk '{print $$5}') -j MASQUERADE
	@sudo iptables -t nat -A POSTROUTING -j FIRECRACKER-NAT
	@sudo iptables -N FIRECRACKER-FORWARD || true
	@sudo iptables -A FIRECRACKER-FORWARD -i tap0 -j ACCEPT
	@sudo iptables -A FIRECRACKER-FORWARD -o tap0 -j ACCEPT
	@sudo iptables -A FORWARD -j FIRECRACKER-FORWARD
	@echo "Networking setup complete. Firecracker is ready to use the tap0 device."

.PHONY: net-down
net-down:
	@echo "Cleaning up networking..."
	# Remove the tap0 device
	@sudo ip link delete tap0 || true
	# Remove Firecracker-specific iptables rules
	@echo "Removing Firecracker-specific iptables rules..."
	@sudo iptables -t nat -D POSTROUTING -j FIRECRACKER-NAT || true
	@sudo iptables -t nat -F FIRECRACKER-NAT || true
	@sudo iptables -t nat -X FIRECRACKER-NAT || true
	@sudo iptables -D FORWARD -j FIRECRACKER-FORWARD || true
	@sudo iptables -F FIRECRACKER-FORWARD || true
	@sudo iptables -X FIRECRACKER-FORWARD || true
	@echo "Networking cleanup complete."
	
.PHONY: up
up: down net-down net-up
	@echo "Starting Firecracker MicroVM..."
	@echo "Ensuring log directory exists..."
	@touch ./firecracker.log
	@echo "Cleaning up vsock socket file..."
	@rm -f ./vsock.sock
	@echo "Launching Firecracker..."
	@firecracker --api-sock /tmp/firecracker.socket --config-file vm-config.json

.PHONY: up-detached
up-detached: down net-down net-up
	@echo "Starting Firecracker MicroVM in detached mode..."
	@echo "Ensuring log directory exists..."
	@touch ./firecracker.log
	@echo "Cleaning up vsock socket file..."
	@rm -f ./vsock.sock
	@echo "Launching Firecracker in a screen session..."
	@screen -L -Logfile firecracker-console.log -dmS firecracker-vm firecracker --api-sock /tmp/firecracker.socket --config-file vm-config.json
	@sleep 2
	@if pgrep -f "^firecracker" > /dev/null; then \
		echo "Firecracker MicroVM started in background."; \
		echo "Console output is being logged to firecracker-console.log"; \
		echo "Use 'make login' to connect to the VM."; \
	else \
		echo "Failed to start Firecracker. Check logs for details."; \
	fi

.PHONY: down
down:
	@echo "Stopping all Firecracker instances..."
	@ps aux | grep -E '[f]irecracker|[F]irecracker' | awk '{print $$2}' | xargs -r kill -9 || true
	@sleep 1
	@echo "Cleaning up socket files..."
	@rm -f /tmp/firecracker.socket
	@rm -f ./vsock.sock
	@echo "Firecracker cleanup complete."

.PHONY: login
login:
	@echo "Attempting to log into the running MicroVM..."
	@if ! pgrep -f "^firecracker" > /dev/null; then \
		echo "Error: Firecracker is not running. Start the VM first with 'make up' or 'make up-detached'."; \
		exit 1; \
	fi
	
	@# Try to connect to screen session first (most reliable)
	@if screen -list | grep -q "firecracker-vm"; then \
		echo "Found firecracker-vm screen session, attaching..."; \
		echo "To exit without shutting down the VM, press Ctrl+a followed by d"; \
		sudo screen -d -r firecracker-vm; \
		exit 0; \
	fi
	
	@# Try to connect via process TTY
	@fc_pid=$$(pgrep -f "^firecracker" | head -1); \
	pts_num=$$(ps -o tty= -p $$fc_pid | sed 's/pts\///'); \
	if [ -n "$$pts_num" ] && [ -e "/dev/pts/$$pts_num" ]; then \
		echo "Found console at /dev/pts/$$pts_num"; \
		echo "To exit without shutting down the VM, press Ctrl+a followed by d"; \
		sudo screen /dev/pts/$$pts_num; \
		exit 0; \
	fi
	
	@# Try vsock.sock
	@if [ -e ./vsock.sock ]; then \
		echo "Trying vsock.sock connection..."; \
		echo "To exit without shutting down the VM, press Ctrl+a followed by d"; \
		sudo screen ./vsock.sock; \
		exit 0; \
	fi
	
	@echo "All connection attempts failed. Try running 'make up-detached' again."

.PHONY: list-vms
list-vms:
	@echo "=== RUNNING FIRECRACKER MICROVMS ==="
	@if pgrep -f "^firecracker" > /dev/null; then \
		echo "PID    COMMAND                           UPTIME    CPU%  MEM%  SOCKET                  VSOCK"; \
		echo "-----------------------------------------------------------------------------------------"; \
		for pid in $$(pgrep -f "^firecracker"); do \
			cmd=$$(ps -p $$pid -o cmd= | sed 's/\(.\{33\}\).*/\1/'); \
			uptime=$$(ps -p $$pid -o etime= | xargs); \
			cpu=$$(ps -p $$pid -o %cpu= | xargs); \
			mem=$$(ps -p $$pid -o %mem= | xargs); \
			socket=$$(find /tmp -name "firecracker*.socket" 2>/dev/null | head -1); \
			vsock=$$(find . -name "*.sock" 2>/dev/null | head -1); \
			printf "%-6s %-33s %-9s %-5s %-5s %-24s %s\n" "$$pid" "$$cmd" "$$uptime" "$$cpu" "$$mem" "$$socket" "$$vsock"; \
		done; \
	else \
		echo "No Firecracker MicroVMs are currently running."; \
	fi

.PHONY: net-info
net-info:
	@echo "=== NETWORK INFORMATION FOR MICROVMS ==="
	@if ip link show tap0 > /dev/null 2>&1; then \
		echo "HOST NETWORK CONFIGURATION:"; \
		echo "--------------------------"; \
		echo "Host TAP Interface: tap0"; \
		echo "Host IP Address:    $$(ip -br addr show tap0 | awk '{print $$3}')"; \
		echo ""; \
		echo "VM IP ADDRESSES:"; \
		echo "---------------"; \
		echo "Expected VM IP:   192.168.1.2/24"; \
		echo "VM MAC Address:   $$(grep -o '"guest_mac": "[^"]*"' vm-config.json | cut -d'"' -f4)"; \
		echo ""; \
		echo "DETECTED VMs (from ARP table):"; \
		ip neigh show dev tap0 | awk '{printf "IP: %-15s MAC: %s\n", $$1, $$5}' || echo "No VMs detected in ARP table"; \
		echo ""; \
		echo "ROUTING INFORMATION:"; \
		echo "-------------------"; \
		ip route | grep tap0; \
		echo ""; \
		echo "IPTABLES NAT RULES:"; \
		echo "------------------"; \
		sudo iptables -t nat -L FIRECRACKER-NAT -n --line-numbers 2>/dev/null || echo "No FIRECRACKER-NAT chain found"; \
		echo ""; \
		echo "IPTABLES FORWARD RULES:"; \
		echo "----------------------"; \
		sudo iptables -L FIRECRACKER-FORWARD -n --line-numbers 2>/dev/null || echo "No FIRECRACKER-FORWARD chain found"; \
		echo ""; \
		echo "ACTIVE CONNECTIONS:"; \
		echo "------------------"; \
		sudo ss -tuanp | grep tap0 || echo "No active connections for tap0"; \
	else \
		echo "No tap0 device found. Run 'make net-up' to create the network."; \
	fi

.PHONY: snapshot
snapshot:
	@echo "Creating snapshot of the running MicroVM..."
	@if ! ps aux | grep '[f]irecracker' > /dev/null; then \
		echo "Error: No Firecracker MicroVM is running. Start a VM first."; \
		exit 1; \
	fi
	@mkdir -p snapshots
	@timestamp=$$(date +%Y%m%d_%H%M%S); \
	echo "Creating snapshot directory: snapshots/$$timestamp"; \
	mkdir -p snapshots/$$timestamp; \
	echo "Creating memory snapshot..."; \
	curl --unix-socket /tmp/firecracker.socket \
		-i \
		-X PATCH "http://localhost/vm" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d '{"state": "Paused"}' && \
	curl --unix-socket /tmp/firecracker.socket \
		-i \
		-X PUT "http://localhost/snapshot/create" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d '{"mem_file_path": "'$$(pwd)'/snapshots/'$$timestamp'/memory", "snapshot_path": "'$$(pwd)'/snapshots/'$$timestamp'/mem_dump"}' && \
	curl --unix-socket /tmp/firecracker.socket \
		-i \
		-X PATCH "http://localhost/vm" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-d '{"state": "Resumed"}' || { echo "Failed to create snapshot"; exit 1; }; \
	echo "Copying VM configuration..."; \
	cp vm-config.json snapshots/$$timestamp/; \
	echo "Copying rootfs..."; \
	cp firecracker-rootfs.ext4 snapshots/$$timestamp/; \
	echo "Copying kernel..."; \
	cp vmlinux snapshots/$$timestamp/; \
	echo "Creating snapshot metadata..."; \
	echo "Snapshot created on $$(date)" > snapshots/$$timestamp/metadata.txt; \
	echo "Firecracker PID: $$(pgrep -f '^firecracker')" >> snapshots/$$timestamp/metadata.txt; \
	echo "Snapshot complete. Saved to snapshots/$$timestamp/"

.PHONY: restore
restore:
	@echo "Restoring MicroVM from snapshot..."
	@if [ -z "$(SNAPSHOT)" ]; then \
		echo "Error: No snapshot specified. Use 'make restore SNAPSHOT=<snapshot_dir>'"; \
		echo "Available snapshots:"; \
		ls -1 snapshots/; \
		exit 1; \
	fi
	@if [ ! -d "snapshots/$(SNAPSHOT)" ]; then \
		echo "Error: Snapshot directory 'snapshots/$(SNAPSHOT)' not found."; \
		echo "Available snapshots:"; \
		ls -1 snapshots/; \
		exit 1; \
	fi
	@echo "Stopping any running Firecracker instances..."
	@make down
	@echo "Setting up networking..."
	@make net-up
	@echo "Activating API socket..."
	@make activate
	@echo "Preparing to restore from snapshot 'snapshots/$(SNAPSHOT)'..."
	@echo "Starting Firecracker in snapshot restore mode..."
	@nohup firecracker --api-sock /tmp/firecracker.socket \
		--config-file $$(pwd)/snapshots/$(SNAPSHOT)/vm-config.json \
		--no-api > firecracker.out 2>&1 &
	@sleep 3
	@if pgrep -f "^firecracker" > /dev/null; then \
		echo "Firecracker MicroVM restored from snapshot. Use 'make login' to connect to it."; \
	else \
		echo "Failed to restore MicroVM. Check firecracker.out for details."; \
		cat firecracker.out; \
	fi

.PHONY: build-kernel
build-kernel:
	@echo "Building the latest stable Linux kernel for Firecracker..."
	@bash tools/build-latest-kernel.sh

.PHONY: build-rootfs
build-rootfs:
	@echo "Creating a Debian rootfs that matches the latest kernel..."
	@sudo bash tools/create-matching-rootfs.sh

.PHONY: build-simple-rootfs
build-simple-rootfs:
	@echo "Creating a simple rootfs for Firecracker..."
	@sudo rm -f firecracker-rootfs.ext4
	@sudo dd if=/dev/zero of=firecracker-rootfs.ext4 bs=1M count=1024
	@sudo mkfs.ext4 firecracker-rootfs.ext4
	@sudo mkdir -p mnt
	@sudo mount firecracker-rootfs.ext4 mnt
	@echo "Installing Debian with systemd..."
	@sudo apt-get update
	@sudo apt-get install -y debootstrap
	@sudo debootstrap --variant=minbase --include=systemd,systemd-sysv,udev,dbus,kmod,util-linux,iproute2,iputils-ping,net-tools,procps,vim,less,fuse --arch=amd64 bullseye mnt http://deb.debian.org/debian/
	@echo "Configuring systemd services..."
	@sudo mkdir -p mnt/etc/systemd/system/getty@ttyS0.service.d
	@echo '[Service]' | sudo tee mnt/etc/systemd/system/getty@ttyS0.service.d/override.conf > /dev/null
	@echo 'ExecStart=' | sudo tee -a mnt/etc/systemd/system/getty@ttyS0.service.d/override.conf > /dev/null
	@echo 'ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM' | sudo tee -a mnt/etc/systemd/system/getty@ttyS0.service.d/override.conf > /dev/null
	@sudo mkdir -p mnt/etc/systemd/system/getty.target.wants
	@sudo ln -sf /lib/systemd/system/getty@.service mnt/etc/systemd/system/getty.target.wants/getty@ttyS0.service
	@echo "Setting up network..."
	@echo 'auto eth0' | sudo tee mnt/etc/network/interfaces > /dev/null
	@echo 'iface eth0 inet static' | sudo tee -a mnt/etc/network/interfaces > /dev/null
	@echo '    address 192.168.1.2' | sudo tee -a mnt/etc/network/interfaces > /dev/null
	@echo '    netmask 255.255.255.0' | sudo tee -a mnt/etc/network/interfaces > /dev/null
	@echo '    gateway 192.168.1.1' | sudo tee -a mnt/etc/network/interfaces > /dev/null
	@echo 'nameserver 8.8.8.8' | sudo tee mnt/etc/resolv.conf > /dev/null
	@echo "Setting up shared directory mount..."
	@sudo mkdir -p mnt/mnt/shared
	@echo 'shared /mnt/shared virtiofs defaults 0 0' | sudo tee -a mnt/etc/fstab > /dev/null
	@echo "Setting root password..."
	@echo 'root:root' | sudo chroot mnt chpasswd
	@echo "Welcome to Firecracker MicroVM with systemd" | sudo tee mnt/etc/issue > /dev/null
	@sudo umount mnt
	@sudo rmdir mnt

.PHONY: build-all
build-all: build-kernel build-simple-rootfs
	@echo "Build complete. Kernel and rootfs are ready for Firecracker."

.PHONY: wireguard-e2e
wireguard-e2e:
	@if [ -z "$(WG_REMOTE)" ]; then \
		echo "Usage: make wireguard-e2e WG_REMOTE=root@host"; \
		exit 2; \
	fi
	@tools/install_wireguard.sh "$(WG_REMOTE)"

.PHONY: lab-up
lab-up:
	@if [ -z "$(REMOTE)" ]; then \
		echo "Usage: make lab-up REMOTE=root@host"; \
		exit 2; \
	fi
	@tools/lab.sh up "$(REMOTE)"

.PHONY: lab-down
lab-down:
	@if [ -z "$(REMOTE)" ]; then \
		echo "Usage: make lab-down REMOTE=root@host"; \
		exit 2; \
	fi
	@tools/lab.sh down "$(REMOTE)"

.PHONY: console-log
console-log:
	@if [ -f firecracker-console.log ]; then \
		echo "=== FIRECRACKER CONSOLE LOG ==="; \
		cat firecracker-console.log; \
	else \
		echo "No console log found. Run 'make up-detached' first."; \
	fi

.PHONY: install-init-script
install-init-script:
	@echo "Installing fallback init script..."
	@sudo mkdir -p mnt
	@sudo mount -o loop firecracker-rootfs.ext4 mnt
	@sudo cp init.sh mnt/sbin/init
	@sudo chmod +x mnt/sbin/init
	@sudo umount mnt
	@sudo rmdir mnt
