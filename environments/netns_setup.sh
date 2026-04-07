#!/usr/bin/env bash
# =============================================================================
# ns_setup.sh — 3 Network Namespaces + Linux bridge + main-table uplink veth
#               (IPv6 fully disabled)
#
# Topology:
#
#  main (default netns)
#  └─ veth0-main  ◄──────────────────────────── 10.0.1.254/24
#        │
#     veth0-br
#        │
#        ├────────────────────┬────────────────────┐
#     veth1-br            veth2-br            veth3-br
#        │                    │                    │
#     veth1-ns            veth2-ns            veth3-ns
#   ns1                  ns2                  ns3
#   10.0.1.1/24         10.0.1.2/24         10.0.1.3/24
#
# The veth0-main/veth0-br pair connects the main (default) namespace
# to the shared bridge, giving the host a gateway into all three namespaces.
#
# Usage:
#   sudo ./ns_setup.sh [setup|teardown|status]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BRIDGE="br-ns"

NAMESPACES=(ns1    ns2    ns3   )
IPS=(10.0.1.1/24  10.0.1.2/24  10.0.1.3/24)

# Main-table uplink (veth0-main stays in the default namespace)
MAIN_VETH_HOST="veth0-main"
MAIN_VETH_BR="veth0-br"
MAIN_IP="10.0.1.254/24"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\e[32m[+]\e[0m %s\n' "$*"; }
err()  { printf '\e[31m[!]\e[0m %s\n' "$*" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }
}

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown() {
    log "Starting teardown..."

    # Remove main-table uplink veth pair
    if ip link show "$MAIN_VETH_HOST" &>/dev/null; then
        ip link del "$MAIN_VETH_HOST"
        log "  Removed veth pair: $MAIN_VETH_HOST <-> $MAIN_VETH_BR"
    fi

    # Remove namespace veth pairs (bridge-side ends) and namespaces
    for i in 1 2 3; do
        # The bridge-side veth still lives in the default namespace
        if ip link show "veth${i}-br" &>/dev/null; then
            ip link del "veth${i}-br"
            log "  Removed veth pair: veth${i}-ns <-> veth${i}-br"
        fi
        if ip netns list 2>/dev/null | grep -qw "ns${i}"; then
            ip netns del "ns${i}"
            log "  Removed namespace ns${i}"
        fi
    done

    # Remove bridge
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link del "$BRIDGE"
        log "  Removed bridge $BRIDGE"
    fi

    log "Teardown complete."
}

# ── Setup ─────────────────────────────────────────────────────────────────────
setup() {
    # Pre-flight: check for existing interfaces / namespaces
    local check_ifaces=( "$BRIDGE" "$MAIN_VETH_HOST" "$MAIN_VETH_BR" )
    for i in 1 2 3; do
        check_ifaces+=( "veth${i}-ns" "veth${i}-br" )
    done
    for iface in "${check_ifaces[@]}"; do
        if ip link show "$iface" &>/dev/null; then
            err "Interface '$iface' already exists. Run: sudo $0 teardown"
            exit 1
        fi
    done
    for ns in "${NAMESPACES[@]}"; do
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            err "Namespace '$ns' already exists. Run: sudo $0 teardown"
            exit 1
        fi
    done

    # ── 1. Bridge ─────────────────────────────────────────────────────────────
    log "Creating bridge: $BRIDGE"
    ip link add name "$BRIDGE" type bridge stp_state 0 forward_delay 0
    # Disable IPv6 on the bridge before bringing it up so no LL address is assigned
    sysctl -qw "net.ipv6.conf.${BRIDGE}.disable_ipv6=1"
    # Disable ARP on the bridge — it operates as a pure L2 fabric
    ip link set "$BRIDGE" arp off
    ip link set "$BRIDGE" up
    log "  $BRIDGE  UP  (IPv6 disabled, ARP disabled)"

    # ── 2. Main-table uplink veth ─────────────────────────────────────────────
    log ""
    log "── main namespace uplink ────────────────────────────────────"
    ip link add "$MAIN_VETH_HOST" type veth peer name "$MAIN_VETH_BR"
    log "  veth pair:  $MAIN_VETH_HOST <──> $MAIN_VETH_BR"

    # Disable IPv6 on both ends before bringing them up
    sysctl -qw "net.ipv6.conf.${MAIN_VETH_HOST}.disable_ipv6=1"
    sysctl -qw "net.ipv6.conf.${MAIN_VETH_BR}.disable_ipv6=1"

    # Host side: stays in default namespace, gets IP
    ip addr add "$MAIN_IP" dev "$MAIN_VETH_HOST"
    ip link set "$MAIN_VETH_HOST" up
    log "  Main side:  $MAIN_VETH_HOST   IP: $MAIN_IP  (default netns, IPv6 disabled)"

    # Bridge side: enslaved to bridge
    ip link set "$MAIN_VETH_BR" master "$BRIDGE"
    ip link set "$MAIN_VETH_BR" up
    log "  Bridge side: $MAIN_VETH_BR → $BRIDGE  (IPv6 disabled)"

    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.forwarding=1"
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.rp_filter=0"
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.accept_local=1"
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_BR}.rp_filter=0"

    # ── 3. Namespace veth pairs ───────────────────────────────────────────────
    for idx in 0 1 2; do
        ns="${NAMESPACES[$idx]}"
        ip_addr="${IPS[$idx]}"
        num=$(( idx+1 ))
        veth_ns="veth${num}-ns"
        veth_br="veth${num}-br"

        log ""
        log "── $ns ──────────────────────────────────────────────────"

        # Create namespace
        ip netns add "$ns"
        log "  Namespace:  $ns  created"

        # Bring up loopback inside the namespace
        ip netns exec "$ns" ip link set lo up

        # Create veth pair in default namespace
        ip link add "$veth_ns" type veth peer name "$veth_br"
        log "  veth pair:  $veth_ns <──> $veth_br"

        # Disable IPv6 on bridge side before bringing up
        sysctl -qw "net.ipv6.conf.${veth_br}.disable_ipv6=1"

        # Move namespace-side veth into the namespace
        ip link set "$veth_ns" netns "$ns"
        log "  Moved:      $veth_ns → netns $ns"

        # Configure inside the namespace
        ip netns exec "$ns" sysctl -qw "net.ipv6.conf.${veth_ns}.disable_ipv6=1"
        ip netns exec "$ns" ip addr add "$ip_addr" dev "$veth_ns"
        ip netns exec "$ns" ip link set "$veth_ns" up
        log "  Inside $ns: $veth_ns   IP: $ip_addr  (IPv6 disabled)"

        # Add default route inside namespace pointing to the main uplink
        ip netns exec "$ns" ip route add default via 10.0.1.254

        # Enslave bridge side
        ip link set "$veth_br" master "$BRIDGE"
        ip link set "$veth_br" up
        log "  Enslaved:   $veth_br  → $BRIDGE  (IPv6 disabled)"

        # Enable forwarding inside the namespace
        ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1
        ip netns exec "$ns" sysctl -qw "net.ipv4.conf.${veth_ns}.forwarding=1"
        ip netns exec "$ns" sysctl -qw "net.ipv4.conf.${veth_ns}.rp_filter=0"

        # rp_filter on bridge-side (lives in default namespace)
        sysctl -qw "net.ipv4.conf.${veth_br}.rp_filter=0"
    done

    # ── 4. Global forwarding & rp_filter ─────────────────────────────────────
    sysctl -qw net.ipv4.ip_forward=1
    sysctl -qw "net.ipv4.conf.${BRIDGE}.rp_filter=0"
    sysctl -qw "net.ipv4.conf.all.rp_filter=0"
    log ""
    log "Global IPv4 forwarding enabled."

    log ""
    log "Setup complete!"
    echo ""
    show_status
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
    local SEP="├──────────────────┼────────────┬───────────────┼───────────────┤"
    echo  "┌───────────────────────────────────────────────────────────────┐"
    echo  "│                  Namespace Setup Status                       │"
    echo  "├──────────────────┬────────────┬───────────────┬───────────────┤"
    printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
           "Interface" "Namespace" "IP Address" "State"
    echo  "├──────────────────┼────────────┼───────────────┼───────────────┤"

    # Row for interfaces in the default namespace
    _row() {
        local iface="$1" ns_label="$2"
        if ip link show "$iface" &>/dev/null; then
            local ip_addr state
            ip_addr=$(ip -br addr show "$iface" 2>/dev/null | awk '{print $3}')
            state=$(ip -br link show "$iface" | awk '{print $2}')
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$ns_label" "${ip_addr:--}" "$state"
        else
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$ns_label" "N/A" "NOT FOUND"
        fi
    }

    # Row for interfaces inside a namespace
    _row_ns() {
        local iface="$1" ns="$2"
        if ip netns list 2>/dev/null | grep -qw "$ns"; then
            local ip_addr state
            ip_addr=$(ip netns exec "$ns" ip -br addr show "$iface" 2>/dev/null | awk '{print $3}')
            state=$(ip netns exec "$ns" ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$ns" "${ip_addr:--}" "${state:-NOT FOUND}"
        else
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$ns" "N/A" "NS MISSING"
        fi
    }

    # Main uplink
    _row "$MAIN_VETH_HOST" "default"
    _row "$MAIN_VETH_BR"   "→ bridge"

    echo "$SEP"

    # Namespace interfaces
    for idx in 0 1 2; do
        local num=$(( idx+1 ))
        local ns="${NAMESPACES[$idx]}"
        _row_ns "veth${num}-ns" "$ns"
        _row    "veth${num}-br" "→ bridge"
        [[ $idx -lt 2 ]] && echo "$SEP"
    done

    echo  "├──────────────────┼────────────┼───────────────┼───────────────┤"
    _row "$BRIDGE" "L2 bridge"
    echo  "└──────────────────┴────────────┴───────────────┴───────────────┘"

    echo ""
    echo "  ── Connectivity tests ───────────────────────────────────────────"
    echo "  # Main namespace → Namespaces (direct from default netns)"
    echo "    ping -c3 10.0.1.1 -I 10.0.1.254   # main → ns1"
    echo "    ping -c3 10.0.1.2 -I 10.0.1.254   # main → ns2"
    echo "    ping -c3 10.0.1.3 -I 10.0.1.254   # main → ns3"
    echo ""
    echo "  # Cross-namespace (traffic traverses the bridge)"
    echo "    sudo ip netns exec ns1 ping -c3 10.0.1.2   # ns1 → ns2"
    echo "    sudo ip netns exec ns1 ping -c3 10.0.1.3   # ns1 → ns3"
    echo "    sudo ip netns exec ns2 ping -c3 10.0.1.3   # ns2 → ns3"
    echo ""
    echo "  # Namespace → main"
    echo "    sudo ip netns exec ns1 ping -c3 10.0.1.254 # ns1 → main"
    echo ""
    echo "  ── Route inspection ─────────────────────────────────────────────"
    echo "    ip route                                # default namespace"
    echo "    sudo ip netns exec ns1 ip route         # ns1"
    echo "    sudo ip netns exec ns2 ip route         # ns2"
    echo "    sudo ip netns exec ns3 ip route         # ns3"
    echo ""
    echo "  ── Run commands inside a namespace ──────────────────────────────"
    echo "    sudo ip netns exec ns1 bash             # shell inside ns1"
    echo "    sudo ip netns exec ns1 ss -tlnp         # listening sockets in ns1"
}

# ── Entry point ───────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 [setup|teardown|status]"
    echo "  setup    — Build namespaces, veth pairs, main uplink, and bridge  (default)"
    echo "  teardown — Remove all created interfaces and namespaces"
    echo "  status   — Show current interface state and test commands"
    exit 1
}

require_root

case "${1:-setup}" in
    setup)          setup    ;;
    teardown)       teardown ;;
    status)         show_status ;;
    -h|--help|help) usage ;;
    *) err "Unknown command: ${1}"; usage ;;
esac