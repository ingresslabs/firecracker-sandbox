#!/usr/bin/env bash
set -euo pipefail

DEFAULT_LAB_DIR="/opt/firecracker-sandbox-lab"
DEFAULT_KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin"
DEFAULT_DEBIAN_SUITE="bookworm"
DEFAULT_DEBIAN_MIRROR="http://deb.debian.org/debian"
DEFAULT_ROOTFS_SIZE_MB="1536"
DEFAULT_TAP_IFACE="fclab0"
DEFAULT_VM_HOST_CIDR="192.168.127.1/24"
DEFAULT_VM_IP="192.168.127.2"
DEFAULT_VM_MAC="06:00:00:00:00:02"
DEFAULT_VM_VCPUS="1"
DEFAULT_VM_MEM_MIB="512"
DEFAULT_WG_IFACE="wg0"
DEFAULT_WG_PORT="51820"
DEFAULT_WG_NETWORK="10.77.0.0/24"
DEFAULT_WG_SERVER_CIDR="10.77.0.1/24"
DEFAULT_WG_CLIENT_IP="10.77.0.2"
DEFAULT_CLIENT_NS="fclab-client"
DEFAULT_CLIENT_WG_IFACE="fclabwg0"
DEFAULT_CLIENT_HOST_VETH="fclab-host"
DEFAULT_CLIENT_NS_VETH="fclab-ns"
DEFAULT_CLIENT_TRANSPORT_HOST="172.31.254.1"
DEFAULT_CLIENT_TRANSPORT_CLIENT="172.31.254.2"
DEFAULT_OUT_DIR="out"
DEFAULT_SSH_WAIT_SECONDS="180"

log() {
    printf '[lab] %s\n' "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

usage() {
    cat <<USAGE
Usage:
  tools/lab.sh up root@host
  tools/lab.sh down root@host
  REMOTE=root@host make lab-up
  REMOTE=root@host make lab-down

Required:
  REMOTE or positional root@host target.

Common overrides:
  LAB_SSH_PUBLIC_KEY_FILE  Public key to inject into the VM.
  LAB_REMOTE_DIR           Remote lab directory. Default: ${DEFAULT_LAB_DIR}
  LAB_OUT_DIR              Local directory for fetched client config. Default: ${DEFAULT_OUT_DIR}
  LAB_VM_HOST_CIDR         Host tap address. Default: ${DEFAULT_VM_HOST_CIDR}
  LAB_VM_IP                VM address. Default: ${DEFAULT_VM_IP}
  LAB_WG_SERVER_CIDR       WireGuard server address. Default: ${DEFAULT_WG_SERVER_CIDR}
  LAB_WG_CLIENT_IP         WireGuard client address. Default: ${DEFAULT_WG_CLIENT_IP}
  LAB_KERNEL_URL           Kernel image URL. Default: Firecracker quickstart kernel.
USAGE
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

first_existing_public_key() {
    local candidate
    for candidate in \
        "${HOME}/.ssh/id_ed25519.pub" \
        "${HOME}/.ssh/id_rsa.pub" \
        "${HOME}/.ssh/id_ecdsa.pub"; do
        if [[ -r "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

read_user_public_key() {
    if [[ -n "${LAB_SSH_PUBLIC_KEY:-}" ]]; then
        printf '%s\n' "$LAB_SSH_PUBLIC_KEY"
        return 0
    fi

    local key_file="${LAB_SSH_PUBLIC_KEY_FILE:-}"
    if [[ -z "$key_file" ]]; then
        key_file="$(first_existing_public_key || true)"
    fi
    [[ -n "$key_file" ]] || die "missing SSH public key; set LAB_SSH_PUBLIC_KEY_FILE"
    [[ -r "$key_file" ]] || die "cannot read SSH public key file: $key_file"
    sed -n '1p' "$key_file"
}

remote_target() {
    local remote="${1:-${REMOTE:-}}"
    [[ -n "$remote" ]] || die "missing remote target; pass root@host or set REMOTE"
    printf '%s\n' "$remote"
}

remote_endpoint() {
    local remote="$1"
    local endpoint="${LAB_ENDPOINT:-${remote##*@}}"
    printf '%s\n' "${endpoint%%:*}"
}

ssh_options() {
    printf '%s\n' \
        "-o" "BatchMode=yes" \
        "-o" "ConnectTimeout=10" \
        "-o" "StrictHostKeyChecking=accept-new"
}

run_remote() {
    local action="$1"
    local remote="$2"
    local endpoint="$3"
    local user_public_key="$4"
    local env_args

    env_args="LAB_REMOTE_EXEC=1"
    env_args+=" LAB_ACTION=$(shell_quote "$action")"
    env_args+=" LAB_ENDPOINT=$(shell_quote "$endpoint")"
    env_args+=" LAB_USER_PUBLIC_KEY=$(shell_quote "$user_public_key")"
    env_args+=" LAB_REMOTE_DIR=$(shell_quote "${LAB_REMOTE_DIR:-$DEFAULT_LAB_DIR}")"
    env_args+=" LAB_KERNEL_URL=$(shell_quote "${LAB_KERNEL_URL:-$DEFAULT_KERNEL_URL}")"
    env_args+=" LAB_DEBIAN_SUITE=$(shell_quote "${LAB_DEBIAN_SUITE:-$DEFAULT_DEBIAN_SUITE}")"
    env_args+=" LAB_DEBIAN_MIRROR=$(shell_quote "${LAB_DEBIAN_MIRROR:-$DEFAULT_DEBIAN_MIRROR}")"
    env_args+=" LAB_ROOTFS_SIZE_MB=$(shell_quote "${LAB_ROOTFS_SIZE_MB:-$DEFAULT_ROOTFS_SIZE_MB}")"
    env_args+=" LAB_TAP_IFACE=$(shell_quote "${LAB_TAP_IFACE:-$DEFAULT_TAP_IFACE}")"
    env_args+=" LAB_VM_HOST_CIDR=$(shell_quote "${LAB_VM_HOST_CIDR:-$DEFAULT_VM_HOST_CIDR}")"
    env_args+=" LAB_VM_IP=$(shell_quote "${LAB_VM_IP:-$DEFAULT_VM_IP}")"
    env_args+=" LAB_VM_MAC=$(shell_quote "${LAB_VM_MAC:-$DEFAULT_VM_MAC}")"
    env_args+=" LAB_VM_VCPUS=$(shell_quote "${LAB_VM_VCPUS:-$DEFAULT_VM_VCPUS}")"
    env_args+=" LAB_VM_MEM_MIB=$(shell_quote "${LAB_VM_MEM_MIB:-$DEFAULT_VM_MEM_MIB}")"
    env_args+=" LAB_WG_IFACE=$(shell_quote "${LAB_WG_IFACE:-$DEFAULT_WG_IFACE}")"
    env_args+=" LAB_WG_PORT=$(shell_quote "${LAB_WG_PORT:-$DEFAULT_WG_PORT}")"
    env_args+=" LAB_WG_NETWORK=$(shell_quote "${LAB_WG_NETWORK:-$DEFAULT_WG_NETWORK}")"
    env_args+=" LAB_WG_SERVER_CIDR=$(shell_quote "${LAB_WG_SERVER_CIDR:-$DEFAULT_WG_SERVER_CIDR}")"
    env_args+=" LAB_WG_CLIENT_IP=$(shell_quote "${LAB_WG_CLIENT_IP:-$DEFAULT_WG_CLIENT_IP}")"
    env_args+=" LAB_CLIENT_NS=$(shell_quote "${LAB_CLIENT_NS:-$DEFAULT_CLIENT_NS}")"
    env_args+=" LAB_CLIENT_WG_IFACE=$(shell_quote "${LAB_CLIENT_WG_IFACE:-$DEFAULT_CLIENT_WG_IFACE}")"
    env_args+=" LAB_CLIENT_HOST_VETH=$(shell_quote "${LAB_CLIENT_HOST_VETH:-$DEFAULT_CLIENT_HOST_VETH}")"
    env_args+=" LAB_CLIENT_NS_VETH=$(shell_quote "${LAB_CLIENT_NS_VETH:-$DEFAULT_CLIENT_NS_VETH}")"
    env_args+=" LAB_CLIENT_TRANSPORT_HOST=$(shell_quote "${LAB_CLIENT_TRANSPORT_HOST:-$DEFAULT_CLIENT_TRANSPORT_HOST}")"
    env_args+=" LAB_CLIENT_TRANSPORT_CLIENT=$(shell_quote "${LAB_CLIENT_TRANSPORT_CLIENT:-$DEFAULT_CLIENT_TRANSPORT_CLIENT}")"
    env_args+=" LAB_SSH_WAIT_SECONDS=$(shell_quote "${LAB_SSH_WAIT_SECONDS:-$DEFAULT_SSH_WAIT_SECONDS}")"

    ssh $(ssh_options) "$remote" "${env_args} bash -s" <"$0"
}

fetch_client_config() {
    local remote="$1"
    local remote_dir="${LAB_REMOTE_DIR:-$DEFAULT_LAB_DIR}"
    local out_dir="${LAB_OUT_DIR:-$DEFAULT_OUT_DIR}"

    mkdir -p "$out_dir"
    scp $(ssh_options) -q "${remote}:${remote_dir}/client.conf" "${out_dir}/client.conf"
    chmod 600 "${out_dir}/client.conf"
    log "wrote ${out_dir}/client.conf"
}

local_up() {
    local remote
    remote="$(remote_target "${1:-}")"
    local endpoint
    endpoint="$(remote_endpoint "$remote")"
    local user_public_key
    user_public_key="$(read_user_public_key)"

    log "configuring WireGuard on ${remote}"
    WG_ENDPOINT="$endpoint" \
    WG_IFACE="${LAB_WG_IFACE:-$DEFAULT_WG_IFACE}" \
    WG_PORT="${LAB_WG_PORT:-$DEFAULT_WG_PORT}" \
    WG_NETWORK="${LAB_WG_NETWORK:-$DEFAULT_WG_NETWORK}" \
    WG_SERVER_CIDR="${LAB_WG_SERVER_CIDR:-$DEFAULT_WG_SERVER_CIDR}" \
    WG_TEST_CLIENT_IP="${LAB_WG_CLIENT_IP:-$DEFAULT_WG_CLIENT_IP}" \
        tools/install_wireguard.sh "$remote"

    log "booting Firecracker lab on ${remote}"
    run_remote "up" "$remote" "$endpoint" "$user_public_key"
    fetch_client_config "$remote"
}

local_down() {
    local remote
    remote="$(remote_target "${1:-}")"
    local endpoint
    endpoint="$(remote_endpoint "$remote")"
    run_remote "down" "$remote" "$endpoint" ""
}

remote_defaults() {
    REMOTE_DIR="${LAB_REMOTE_DIR:-$DEFAULT_LAB_DIR}"
    KERNEL_URL="${LAB_KERNEL_URL:-$DEFAULT_KERNEL_URL}"
    DEBIAN_SUITE="${LAB_DEBIAN_SUITE:-$DEFAULT_DEBIAN_SUITE}"
    DEBIAN_MIRROR="${LAB_DEBIAN_MIRROR:-$DEFAULT_DEBIAN_MIRROR}"
    ROOTFS_SIZE_MB="${LAB_ROOTFS_SIZE_MB:-$DEFAULT_ROOTFS_SIZE_MB}"
    TAP_IFACE="${LAB_TAP_IFACE:-$DEFAULT_TAP_IFACE}"
    VM_HOST_CIDR="${LAB_VM_HOST_CIDR:-$DEFAULT_VM_HOST_CIDR}"
    VM_HOST_IP="${VM_HOST_CIDR%/*}"
    VM_PREFIX="${VM_HOST_CIDR#*/}"
    VM_IP="${LAB_VM_IP:-$DEFAULT_VM_IP}"
    VM_MAC="${LAB_VM_MAC:-$DEFAULT_VM_MAC}"
    VM_VCPUS="${LAB_VM_VCPUS:-$DEFAULT_VM_VCPUS}"
    VM_MEM_MIB="${LAB_VM_MEM_MIB:-$DEFAULT_VM_MEM_MIB}"
    WG_IFACE="${LAB_WG_IFACE:-$DEFAULT_WG_IFACE}"
    WG_PORT="${LAB_WG_PORT:-$DEFAULT_WG_PORT}"
    WG_NETWORK="${LAB_WG_NETWORK:-$DEFAULT_WG_NETWORK}"
    WG_SERVER_CIDR="${LAB_WG_SERVER_CIDR:-$DEFAULT_WG_SERVER_CIDR}"
    WG_SERVER_IP="${WG_SERVER_CIDR%/*}"
    WG_CLIENT_IP="${LAB_WG_CLIENT_IP:-$DEFAULT_WG_CLIENT_IP}"
    CLIENT_NS="${LAB_CLIENT_NS:-$DEFAULT_CLIENT_NS}"
    CLIENT_WG_IFACE="${LAB_CLIENT_WG_IFACE:-$DEFAULT_CLIENT_WG_IFACE}"
    CLIENT_HOST_VETH="${LAB_CLIENT_HOST_VETH:-$DEFAULT_CLIENT_HOST_VETH}"
    CLIENT_NS_VETH="${LAB_CLIENT_NS_VETH:-$DEFAULT_CLIENT_NS_VETH}"
    CLIENT_TRANSPORT_HOST="${LAB_CLIENT_TRANSPORT_HOST:-$DEFAULT_CLIENT_TRANSPORT_HOST}"
    CLIENT_TRANSPORT_CLIENT="${LAB_CLIENT_TRANSPORT_CLIENT:-$DEFAULT_CLIENT_TRANSPORT_CLIENT}"
    SSH_WAIT_SECONDS="${LAB_SSH_WAIT_SECONDS:-$DEFAULT_SSH_WAIT_SECONDS}"
    ENDPOINT="${LAB_ENDPOINT:-}"
    [[ -n "$ENDPOINT" ]] || die "LAB_ENDPOINT is required in remote mode"

    KERNEL_IMAGE="${REMOTE_DIR}/vmlinux.bin"
    ROOTFS_IMAGE="${REMOTE_DIR}/rootfs.ext4"
    ROOTFS_READY="${REMOTE_DIR}/rootfs.ready"
    MNT_DIR="${REMOTE_DIR}/mnt"
    API_SOCKET="${REMOTE_DIR}/firecracker.socket"
    CONFIG_FILE="${REMOTE_DIR}/vm.json"
    CONSOLE_LOG="${REMOTE_DIR}/console.log"
    FIRECRACKER_LOG="${REMOTE_DIR}/firecracker.log"
    PID_FILE="${REMOTE_DIR}/firecracker.pid"
    LAB_SSH_KEY="${REMOTE_DIR}/lab_ssh_key"
    CLIENT_CONFIG="${REMOTE_DIR}/client.conf"
}

require_remote_root() {
    [[ "$(id -u)" -eq 0 ]] || die "remote lab commands must run as root"
}

vm_network() {
    python3 - "$VM_HOST_CIDR" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

vm_netmask() {
    python3 - "$VM_PREFIX" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_network("0.0.0.0/" + sys.argv[1]).netmask)
PY
}

install_remote_deps() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        debootstrap \
        e2fsprogs \
        iproute2 \
        iptables \
        iputils-ping \
        openssh-client \
        python3
}

ensure_prereqs() {
    command -v apt-get >/dev/null 2>&1 || die "only apt-based Linux hosts are supported"
    [[ -e /dev/kvm ]] || die "/dev/kvm is missing; Firecracker requires KVM"
    command -v firecracker >/dev/null 2>&1 || die "firecracker is not installed on the remote host"
}

kill_firecracker() {
    if [[ -s "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
            kill "$pid" >/dev/null 2>&1 || true
            for _ in 1 2 3 4 5; do
                kill -0 "$pid" >/dev/null 2>&1 || break
                sleep 1
            done
            kill -9 "$pid" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$PID_FILE" "$API_SOCKET"
}

delete_iptables_rules() {
    local vm_net
    vm_net="$(vm_network)"
    while iptables -C FORWARD -i "$WG_IFACE" -o "$TAP_IFACE" -j ACCEPT >/dev/null 2>&1; do
        iptables -D FORWARD -i "$WG_IFACE" -o "$TAP_IFACE" -j ACCEPT || true
    done
    while iptables -C FORWARD -i "$TAP_IFACE" -o "$WG_IFACE" -j ACCEPT >/dev/null 2>&1; do
        iptables -D FORWARD -i "$TAP_IFACE" -o "$WG_IFACE" -j ACCEPT || true
    done
    while iptables -t nat -C POSTROUTING -s "$vm_net" -j MASQUERADE >/dev/null 2>&1; do
        iptables -t nat -D POSTROUTING -s "$vm_net" -j MASQUERADE || true
    done
}

remote_down() {
    remote_defaults
    require_remote_root
    log "stopping lab VM and removing lab network"
    kill_firecracker
    ip netns delete "$CLIENT_NS" >/dev/null 2>&1 || true
    ip link delete "$CLIENT_HOST_VETH" >/dev/null 2>&1 || true
    delete_iptables_rules || true
    ip link delete "$TAP_IFACE" >/dev/null 2>&1 || true
    log "lab-down complete"
}

ensure_lab_key() {
    mkdir -p "$REMOTE_DIR"
    if [[ ! -s "$LAB_SSH_KEY" ]]; then
        ssh-keygen -t ed25519 -N '' -f "$LAB_SSH_KEY" -C "firecracker-lab" >/dev/null
    fi
    chmod 600 "$LAB_SSH_KEY"
}

ensure_kernel() {
    mkdir -p "$REMOTE_DIR"
    if [[ ! -s "$KERNEL_IMAGE" ]]; then
        log "downloading kernel image"
        curl -fL "$KERNEL_URL" -o "$KERNEL_IMAGE"
    fi
}

mount_rootfs() {
    mkdir -p "$MNT_DIR"
    if ! findmnt -rn "$MNT_DIR" >/dev/null 2>&1; then
        mount -o loop "$ROOTFS_IMAGE" "$MNT_DIR"
    fi
}

unmount_rootfs() {
    if findmnt -rn "$MNT_DIR" >/dev/null 2>&1; then
        umount "$MNT_DIR"
    fi
}

configure_rootfs() {
    local netmask
    netmask="$(vm_netmask)"

    printf 'firecracker-lab\n' >"${MNT_DIR}/etc/hostname"
    cat >"${MNT_DIR}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 firecracker-lab
EOF

    cat >"${MNT_DIR}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${VM_IP}
    netmask ${netmask}
    gateway ${VM_HOST_IP}
EOF

    cat >"${MNT_DIR}/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    mkdir -p "${MNT_DIR}/etc/ssh/sshd_config.d"
    cat >"${MNT_DIR}/etc/ssh/sshd_config.d/99-firecracker-lab.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
UseDNS no
EOF

    mkdir -p "${MNT_DIR}/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/ssh.service "${MNT_DIR}/etc/systemd/system/multi-user.target.wants/ssh.service"

    ln -sf /dev/null "${MNT_DIR}/etc/systemd/system/serial-getty@ttyS0.service"
    ln -sf /dev/null "${MNT_DIR}/etc/systemd/system/systemd-random-seed.service"

    chroot "$MNT_DIR" ssh-keygen -A >/dev/null
}

inject_ssh_keys() {
    local key_dir="${MNT_DIR}/root/.ssh"
    mkdir -p "$key_dir"
    {
        cat "${LAB_SSH_KEY}.pub"
        if [[ -n "${LAB_USER_PUBLIC_KEY:-}" ]]; then
            printf '%s\n' "$LAB_USER_PUBLIC_KEY"
        fi
    } | awk 'NF && !seen[$0]++' >"${key_dir}/authorized_keys"
    chmod 700 "$key_dir"
    chmod 600 "${key_dir}/authorized_keys"
}

ensure_rootfs() {
    if [[ ! -s "$ROOTFS_IMAGE" || ! -f "$ROOTFS_READY" || "${LAB_REBUILD_ROOTFS:-0}" == "1" ]]; then
        log "creating Debian rootfs with SSH"
        rm -f "$ROOTFS_IMAGE" "$ROOTFS_READY"
        truncate -s "${ROOTFS_SIZE_MB}M" "$ROOTFS_IMAGE"
        mkfs.ext4 -F "$ROOTFS_IMAGE" >/dev/null
        mount_rootfs
        trap unmount_rootfs RETURN
        debootstrap \
            --arch=amd64 \
            --variant=minbase \
            --include=systemd-sysv,openssh-server,ifupdown,iproute2,iputils-ping,ca-certificates,curl,netbase \
            "$DEBIAN_SUITE" \
            "$MNT_DIR" \
            "$DEBIAN_MIRROR"
        configure_rootfs
        inject_ssh_keys
        unmount_rootfs
        trap - RETURN
        touch "$ROOTFS_READY"
    else
        mount_rootfs
        trap unmount_rootfs RETURN
        configure_rootfs
        inject_ssh_keys
        unmount_rootfs
        trap - RETURN
    fi
}

setup_tap_network() {
    local vm_net
    vm_net="$(vm_network)"

    ip link delete "$TAP_IFACE" >/dev/null 2>&1 || true
    ip tuntap add "$TAP_IFACE" mode tap
    ip addr add "$VM_HOST_CIDR" dev "$TAP_IFACE"
    ip link set "$TAP_IFACE" up
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    iptables -C FORWARD -i "$WG_IFACE" -o "$TAP_IFACE" -j ACCEPT >/dev/null 2>&1 || \
        iptables -A FORWARD -i "$WG_IFACE" -o "$TAP_IFACE" -j ACCEPT
    iptables -C FORWARD -i "$TAP_IFACE" -o "$WG_IFACE" -j ACCEPT >/dev/null 2>&1 || \
        iptables -A FORWARD -i "$TAP_IFACE" -o "$WG_IFACE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$vm_net" -j MASQUERADE >/dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$vm_net" -j MASQUERADE
}

write_firecracker_config() {
    cat >"$CONFIG_FILE" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${KERNEL_IMAGE}",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw random.trust_cpu=on systemd.mask=serial-getty@ttyS0.service systemd.mask=systemd-random-seed.service"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${ROOTFS_IMAGE}",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
  "machine-config": {
    "vcpu_count": ${VM_VCPUS},
    "mem_size_mib": ${VM_MEM_MIB}
  },
  "entropy": {},
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "host_dev_name": "${TAP_IFACE}",
      "guest_mac": "${VM_MAC}"
    }
  ],
  "logger": {
    "log_path": "${FIRECRACKER_LOG}",
    "level": "Info",
    "show_level": true,
    "show_log_origin": true
  }
}
EOF
}

start_firecracker() {
    rm -f "$API_SOCKET" "$CONSOLE_LOG" "$FIRECRACKER_LOG"
    setsid firecracker --api-sock "$API_SOCKET" --config-file "$CONFIG_FILE" >"$CONSOLE_LOG" 2>&1 &
    echo "$!" >"$PID_FILE"
    sleep 2
    if ! kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
        tail -80 "$CONSOLE_LOG" >&2 || true
        die "Firecracker exited during startup"
    fi
}

write_client_config() {
    local client_key="/etc/wireguard/${WG_IFACE}-e2e-client.key"
    local server_pub="/etc/wireguard/${WG_IFACE}.pub"
    [[ -s "$client_key" ]] || die "missing WireGuard client key: $client_key"
    [[ -s "$server_pub" ]] || die "missing WireGuard server public key: $server_pub"

    cat >"$CLIENT_CONFIG" <<EOF
[Interface]
Address = ${WG_CLIENT_IP}/32
PrivateKey = $(cat "$client_key")

[Peer]
PublicKey = $(cat "$server_pub")
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_SERVER_IP}/32, ${VM_IP}/32
PersistentKeepalive = 5
EOF
    chmod 600 "$CLIENT_CONFIG"
}

setup_client_namespace() {
    local client_key="/etc/wireguard/${WG_IFACE}-e2e-client.key"
    local server_pub="/etc/wireguard/${WG_IFACE}.pub"

    ip netns delete "$CLIENT_NS" >/dev/null 2>&1 || true
    ip link delete "$CLIENT_HOST_VETH" >/dev/null 2>&1 || true

    ip netns add "$CLIENT_NS"
    ip link add "$CLIENT_HOST_VETH" type veth peer name "$CLIENT_NS_VETH"
    ip addr add "${CLIENT_TRANSPORT_HOST}/30" dev "$CLIENT_HOST_VETH"
    ip link set "$CLIENT_HOST_VETH" up
    ip link set "$CLIENT_NS_VETH" netns "$CLIENT_NS"
    ip -n "$CLIENT_NS" addr add "${CLIENT_TRANSPORT_CLIENT}/30" dev "$CLIENT_NS_VETH"
    ip -n "$CLIENT_NS" link set lo up
    ip -n "$CLIENT_NS" link set "$CLIENT_NS_VETH" up
    ip -n "$CLIENT_NS" route add default via "$CLIENT_TRANSPORT_HOST"

    ip netns exec "$CLIENT_NS" ip link add "$CLIENT_WG_IFACE" type wireguard
    ip netns exec "$CLIENT_NS" wg set "$CLIENT_WG_IFACE" \
        private-key "$client_key" \
        peer "$(cat "$server_pub")" \
        allowed-ips "${WG_SERVER_IP}/32,${VM_IP}/32" \
        endpoint "${ENDPOINT}:${WG_PORT}" \
        persistent-keepalive 5
    ip -n "$CLIENT_NS" addr add "${WG_CLIENT_IP}/32" dev "$CLIENT_WG_IFACE"
    ip -n "$CLIENT_NS" link set "$CLIENT_WG_IFACE" up
    ip -n "$CLIENT_NS" route add "${WG_SERVER_IP}/32" dev "$CLIENT_WG_IFACE"
    ip -n "$CLIENT_NS" route add "${VM_IP}/32" dev "$CLIENT_WG_IFACE"
}

wait_for_vm_ssh() {
    local ssh_cmd=(
        ip netns exec "$CLIENT_NS"
        ssh
        -i "$LAB_SSH_KEY"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=5
        -o BatchMode=yes
        "root@${VM_IP}"
    )
    local deadline=$(( $(date +%s) + SSH_WAIT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if "${ssh_cmd[@]}" "test \"\$(id -u)\" = 0" >/dev/null 2>&1; then
            "${ssh_cmd[@]}" "set -e; hostname; ip -o -4 addr show eth0; ping -c 1 -W 2 ${VM_HOST_IP} >/dev/null; echo ssh=passed"
            return 0
        fi
        sleep 3
    done

    tail -120 "$CONSOLE_LOG" >&2 || true
    die "timed out waiting for SSH through WireGuard to ${VM_IP}"
}

remote_up() {
    remote_defaults
    require_remote_root
    ensure_prereqs
    install_remote_deps
    mkdir -p "$REMOTE_DIR"

    remote_down
    ensure_lab_key
    ensure_kernel
    ensure_rootfs
    setup_tap_network
    write_firecracker_config
    start_firecracker
    write_client_config
    setup_client_namespace
    wait_for_vm_ssh

    cat <<EOF
lab=up
remote_dir=${REMOTE_DIR}
wireguard=${WG_IFACE} ${WG_SERVER_CIDR}
vm=${VM_IP}
ssh=passed
client_config=${CLIENT_CONFIG}
console_log=${CONSOLE_LOG}
EOF
}

remote_main() {
    case "${LAB_ACTION:-}" in
        up)
            remote_up
            ;;
        down)
            remote_down
            ;;
        *)
            die "unknown remote action: ${LAB_ACTION:-}"
            ;;
    esac
}

local_main() {
    local action="${1:-}"
    case "$action" in
        up)
            local_up "${2:-}"
            ;;
        down)
            local_down "${2:-}"
            ;;
        -h|--help|help|'')
            usage
            ;;
        *)
            die "unknown action: $action"
            ;;
    esac
}

if [[ "${LAB_REMOTE_EXEC:-0}" == "1" ]]; then
    remote_main
else
    local_main "$@"
fi
