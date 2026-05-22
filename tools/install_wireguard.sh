#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IFACE="wg0"
DEFAULT_PORT="51820"
DEFAULT_NETWORK="10.77.0.0/24"
DEFAULT_SERVER_CIDR="10.77.0.1/24"
DEFAULT_TEST_CLIENT_IP="10.77.0.2"

log() {
    printf '[wireguard] %s\n' "$*" >&2
}

die() {
    log "error: $*"
    exit 1
}

usage() {
    cat <<USAGE
Usage:
  tools/install_wireguard.sh [root@host]
  WG_REMOTE=root@host tools/install_wireguard.sh

Environment:
  WG_ENDPOINT          Public endpoint clients should use. Defaults to host from SSH target.
  WG_IFACE            WireGuard interface name. Default: ${DEFAULT_IFACE}
  WG_PORT             WireGuard UDP port. Default: ${DEFAULT_PORT}
  WG_NETWORK          Tunnel network for NAT rules. Default: ${DEFAULT_NETWORK}
  WG_SERVER_CIDR      Server tunnel address. Default: ${DEFAULT_SERVER_CIDR}
  WG_TEST_CLIENT_IP   Temporary e2e client tunnel IP. Default: ${DEFAULT_TEST_CLIENT_IP}

The script SSHes to the target, installs WireGuard, starts wg-quick, and runs
an end-to-end tunnel test with a temporary network namespace client.
USAGE
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

remote_main() {
    local iface="${WG_IFACE:-$DEFAULT_IFACE}"
    local port="${WG_PORT:-$DEFAULT_PORT}"
    local network="${WG_NETWORK:-$DEFAULT_NETWORK}"
    local server_cidr="${WG_SERVER_CIDR:-$DEFAULT_SERVER_CIDR}"
    local server_ip="${server_cidr%/*}"
    local client_ip="${WG_TEST_CLIENT_IP:-$DEFAULT_TEST_CLIENT_IP}"
    local endpoint="${WG_ENDPOINT:-}"
    local main_iface
    local server_key_file="/etc/wireguard/${iface}.key"
    local server_pub_file="/etc/wireguard/${iface}.pub"
    local client_key_file="/etc/wireguard/${iface}-e2e-client.key"
    local client_pub_file="/etc/wireguard/${iface}-e2e-client.pub"
    local config="/etc/wireguard/${iface}.conf"
    local client_config="/etc/wireguard/${iface}-e2e-client.conf"

    [[ "$(id -u)" -eq 0 ]] || die "remote setup must run as root"
    command -v apt-get >/dev/null 2>&1 || die "only apt-based Linux hosts are supported by this script"

    if [[ -z "$endpoint" ]]; then
        endpoint="$(ip -o -4 addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')"
    fi
    [[ -n "$endpoint" ]] || die "could not determine WireGuard endpoint"

    main_iface="${WG_UPLINK_IFACE:-$(ip -o -4 route show default | awk '{print $5; exit}')}"
    [[ -n "$main_iface" ]] || die "could not determine default uplink interface"

    log "installing WireGuard packages on $(hostname)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard iproute2 iptables iputils-ping

    install -d -m 700 /etc/wireguard
    umask 077

    if [[ ! -s "$server_key_file" ]]; then
        wg genkey >"$server_key_file"
    fi
    chmod 600 "$server_key_file"
    wg pubkey <"$server_key_file" >"$server_pub_file"

    if [[ ! -s "$client_key_file" ]]; then
        wg genkey >"$client_key_file"
    fi
    chmod 600 "$client_key_file"
    wg pubkey <"$client_key_file" >"$client_pub_file"

    local server_private server_public client_private client_public tmp_config tmp_client_config
    server_private="$(cat "$server_key_file")"
    server_public="$(cat "$server_pub_file")"
    client_private="$(cat "$client_key_file")"
    client_public="$(cat "$client_pub_file")"
    tmp_config="$(mktemp)"
    tmp_client_config="$(mktemp)"

    cat >"$tmp_config" <<EOF
[Interface]
Address = ${server_cidr}
ListenPort = ${port}
PrivateKey = ${server_private}
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s ${network} -o ${main_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${network} -o ${main_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${network} -o ${main_iface} -j MASQUERADE 2>/dev/null || true

[Peer]
# e2e test client managed by tools/install_wireguard.sh
PublicKey = ${client_public}
AllowedIPs = ${client_ip}/32
EOF

    if [[ -f "$config" ]] && ! cmp -s "$tmp_config" "$config"; then
        cp -a "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    install -m 600 "$tmp_config" "$config"
    rm -f "$tmp_config"

    cat >"$tmp_client_config" <<EOF
[Interface]
Address = ${client_ip}/32
PrivateKey = ${client_private}

[Peer]
PublicKey = ${server_public}
Endpoint = ${endpoint}:${port}
AllowedIPs = ${server_ip}/32
PersistentKeepalive = 5
EOF
    install -m 600 "$tmp_client_config" "$client_config"
    rm -f "$tmp_client_config"

    printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-wireguard-forwarding.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
        ufw allow "${port}/udp" >/dev/null
    fi

    log "starting wg-quick@${iface}"
    systemctl enable "wg-quick@${iface}" >/dev/null
    if ! systemctl restart "wg-quick@${iface}"; then
        wg-quick down "$iface" >/dev/null 2>&1 || true
        ip link delete "$iface" >/dev/null 2>&1 || true
        systemctl start "wg-quick@${iface}"
    fi
    systemctl is-active --quiet "wg-quick@${iface}"
    wg show "$iface" >/dev/null

    run_e2e_test "$iface" "$endpoint" "$port" "$server_ip" "$server_public" "$client_ip" "$client_public" "$client_key_file"

    cat <<EOF
interface=${iface}
endpoint=${endpoint}:${port}
server_address=${server_cidr}
server_public_key=${server_public}
client_config=${client_config}
test=passed
EOF
}

run_e2e_test() {
    local iface="$1"
    local endpoint="$2"
    local port="$3"
    local server_ip="$4"
    local server_public="$5"
    local client_ip="$6"
    local client_public="$7"
    local client_key_file="$8"
    local ns="${WG_TEST_NETNS:-wg-e2e-test}"
    local host_veth="${WG_TEST_HOST_VETH:-wge2e-host}"
    local ns_veth="${WG_TEST_NS_VETH:-wge2e-ns}"
    local test_iface="${WG_TEST_IFACE:-wge2e0}"
    local transport_host="${WG_TEST_TRANSPORT_HOST:-172.31.255.1}"
    local transport_client="${WG_TEST_TRANSPORT_CLIENT:-172.31.255.2}"
    local ok=0

    cleanup_e2e_test() {
        ip netns delete "$ns" >/dev/null 2>&1 || true
        ip link delete "$host_veth" >/dev/null 2>&1 || true
    }

    log "running WireGuard e2e test through temporary netns ${ns}"
    cleanup_e2e_test
    trap cleanup_e2e_test RETURN

    ip netns add "$ns"
    ip link add "$host_veth" type veth peer name "$ns_veth"
    ip addr add "${transport_host}/30" dev "$host_veth"
    ip link set "$host_veth" up
    ip link set "$ns_veth" netns "$ns"
    ip -n "$ns" addr add "${transport_client}/30" dev "$ns_veth"
    ip -n "$ns" link set lo up
    ip -n "$ns" link set "$ns_veth" up
    ip -n "$ns" route add default via "$transport_host"

    ip netns exec "$ns" ip link add "$test_iface" type wireguard
    ip netns exec "$ns" wg set "$test_iface" \
        private-key "$client_key_file" \
        peer "$server_public" \
        allowed-ips "${server_ip}/32" \
        endpoint "${endpoint}:${port}" \
        persistent-keepalive 5
    ip -n "$ns" addr add "${client_ip}/32" dev "$test_iface"
    ip -n "$ns" link set "$test_iface" up
    ip -n "$ns" route add "${server_ip}/32" dev "$test_iface"

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ip netns exec "$ns" ping -c 1 -W 2 "$server_ip" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    [[ "$ok" -eq 1 ]] || die "e2e ping through WireGuard failed"

    local handshake now
    handshake="$(wg show "$iface" latest-handshakes | awk -v pub="$client_public" '$1 == pub {print $2}')"
    now="$(date +%s)"
    [[ -n "$handshake" && "$handshake" != "0" ]] || die "server did not record a WireGuard handshake"
    (( now - handshake <= 120 )) || die "WireGuard handshake is stale"

    trap - RETURN
    cleanup_e2e_test
}

local_main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ "${1:-}" == "--local" ]]; then
        remote_main
        exit 0
    fi

    local remote="${1:-${WG_REMOTE:-}}"
    if [[ -z "$remote" ]]; then
        usage >&2
        die "missing remote target; pass root@host or set WG_REMOTE"
    fi

    local endpoint="${WG_ENDPOINT:-${remote##*@}}"
    endpoint="${endpoint%%:*}"

    local ssh_opts=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
    )
    local remote_env
    remote_env="WG_REMOTE_EXEC=1"
    remote_env+=" WG_ENDPOINT=$(shell_quote "$endpoint")"
    remote_env+=" WG_IFACE=$(shell_quote "${WG_IFACE:-$DEFAULT_IFACE}")"
    remote_env+=" WG_PORT=$(shell_quote "${WG_PORT:-$DEFAULT_PORT}")"
    remote_env+=" WG_NETWORK=$(shell_quote "${WG_NETWORK:-$DEFAULT_NETWORK}")"
    remote_env+=" WG_SERVER_CIDR=$(shell_quote "${WG_SERVER_CIDR:-$DEFAULT_SERVER_CIDR}")"
    remote_env+=" WG_TEST_CLIENT_IP=$(shell_quote "${WG_TEST_CLIENT_IP:-$DEFAULT_TEST_CLIENT_IP}")"

    log "configuring ${remote} with endpoint ${endpoint}"
    ssh "${ssh_opts[@]}" "$remote" "${remote_env} bash -s" <"$0"
}

if [[ "${WG_REMOTE_EXEC:-0}" == "1" ]]; then
    remote_main
else
    local_main "$@"
fi
