#!/usr/bin/env bash
# =============================================================================
# vrf_setup.sh — 3 VRFs + Linux bridge + main-table uplink veth (IPv6 fully disabled)
#
# Topology:
#
#  main (table 0/254)
#  └─ veth0-main  ◄──────────────────────────── 10.0.1.254/24
#        │
#     veth0-br
#        │
#        ├────────────────────┬────────────────────┐
#     veth1-br            veth2-br            veth3-br
#        │                    │                    │
#     veth1-vrf           veth2-vrf           veth3-vrf
#   VRF1 (table 10)     VRF2 (table 20)     VRF3 (table 30)
#   10.0.1.1/24         10.0.1.2/24         10.0.1.3/24
#
# The veth0-main/veth0-br pair connects the main (default) routing table
# to the shared bridge, giving the host a gateway into all three VRFs.
#
# Usage:
#   sudo ./vrf_setup.sh [setup|teardown|status]
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BRIDGE="br-vrf"

VRFS=(vrf1   vrf2   vrf3  )
TABLES=(10   20     30    )
IPS=(10.0.1.1/24 10.0.1.2/24 10.0.1.3/24)

# Main-table uplink (veth0-main stays in the default/main namespace, no VRF)
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

    # Remove VRF veth pairs and VRF devices
    for i in 1 2 3; do
        if ip link show "veth${i}-vrf" &>/dev/null; then
            ip link del "veth${i}-vrf"
            log "  Removed veth pair: veth${i}-vrf <-> veth${i}-br"
        fi
        if ip link show "vrf${i}" &>/dev/null; then
            ip link del "vrf${i}"
            log "  Removed vrf${i}"
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
    # Pre-flight: check for existing interfaces
    local check_ifaces=( "$BRIDGE" "$MAIN_VETH_HOST" "$MAIN_VETH_BR" )
    for i in 1 2 3; do
        check_ifaces+=( "vrf${i}" "veth${i}-vrf" "veth${i}-br" )
    done
    for iface in "${check_ifaces[@]}"; do
        if ip link show "$iface" &>/dev/null; then
            err "Interface '$iface' already exists. Run: sudo $0 teardown"
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
    log "── main table uplink ────────────────────────────────────────"
    ip link add "$MAIN_VETH_HOST" type veth peer name "$MAIN_VETH_BR"
    log "  veth pair:  $MAIN_VETH_HOST <──> $MAIN_VETH_BR"

    # Disable IPv6 on both ends before bringing them up
    sysctl -qw "net.ipv6.conf.${MAIN_VETH_HOST}.disable_ipv6=1"
    sysctl -qw "net.ipv6.conf.${MAIN_VETH_BR}.disable_ipv6=1"

    # Host side: stays in main table (no master VRF), gets IP
    ip addr add "$MAIN_IP" dev "$MAIN_VETH_HOST"
    ip link set "$MAIN_VETH_HOST" up
    log "  Main side:  $MAIN_VETH_HOST   IP: $MAIN_IP  (main table, IPv6 disabled)"

    # Bridge side: enslaved to bridge
    ip link set "$MAIN_VETH_BR" master "$BRIDGE"
    ip link set "$MAIN_VETH_BR" up
    log "  Bridge side: $MAIN_VETH_BR → $BRIDGE  (IPv6 disabled)"

    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.forwarding=1"
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.rp_filter=0"
    # accept_local: allow receipt of packets whose src IP is assigned locally
    # (VRF reply packets arrive on veth0-main with src=10.0.1.x which is local)
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_HOST}.accept_local=1"
    sysctl -qw "net.ipv4.conf.${MAIN_VETH_BR}.rp_filter=0"

    # ── 3. VRF veth pairs ─────────────────────────────────────────────────────
    for idx in 0 1 2; do
        vrf="${VRFS[$idx]}"
        table="${TABLES[$idx]}"
        ip="${IPS[$idx]}"
        veth_vrf="veth$(( idx+1 ))-vrf"
        veth_br="veth$(( idx+1 ))-br"

        log ""
        log "── $vrf  (routing table $table) ─────────────────────────"

        ip link add "$vrf" type vrf table "$table"
        ip link set "$vrf" up
        log "  VRF:        $vrf  UP  (table $table)"

        ip link add "$veth_vrf" type veth peer name "$veth_br"
        log "  veth pair:  $veth_vrf <──> $veth_br"

        # Disable IPv6 on both veth ends before bringing them up
        sysctl -qw "net.ipv6.conf.${veth_vrf}.disable_ipv6=1"
        sysctl -qw "net.ipv6.conf.${veth_br}.disable_ipv6=1"

        ip link set "$veth_vrf" master "$vrf"
        ip addr add "$ip" dev "$veth_vrf"
        ip link set "$veth_vrf" up
        log "  Enslaved:   $veth_vrf → $vrf   IP: $ip  (IPv6 disabled)"

        ip link set "$veth_br" master "$BRIDGE"
        ip link set "$veth_br" up
        log "  Enslaved:   $veth_br  → $BRIDGE  (IPv6 disabled)"

        # accept_local: VRF replies arrive on veth-br with src=local-IP, must be accepted
        # rp_filter=0: disable strict reverse-path check across VRF/bridge boundary
        sysctl -qw "net.ipv4.conf.${veth_vrf}.forwarding=1"
        sysctl -qw "net.ipv4.conf.${veth_vrf}.accept_local=1"
        sysctl -qw "net.ipv4.conf.${veth_vrf}.rp_filter=0"
        sysctl -qw "net.ipv4.conf.${veth_br}.rp_filter=0"
    done

    # ── 4. Global forwarding & rp_filter ─────────────────────────────────────
    sysctl -qw net.ipv4.ip_forward=1
    # Disable rp_filter globally — bridge forwards between VRFs and main table
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
    echo  "│                      VRF Setup Status                         │"
    echo  "├──────────────────┬────────────┬───────────────┬───────────────┤"
    printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
           "Interface" "Table" "IP Address" "State"
    echo  "├──────────────────┼────────────┼───────────────┼───────────────┤"

    _row() {
        local iface="$1" table="$2"
        if ip link show "$iface" &>/dev/null; then
            local ip_addr state
            ip_addr=$(ip -br addr show "$iface" 2>/dev/null | awk '{print $3}')
            state=$(ip -br link show "$iface" | awk '{print $2}')
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$table" "${ip_addr:--}" "$state"
        else
            printf "│ %-16s │ %-10s │ %-13s │ %-13s │\n" \
                   "$iface" "$table" "N/A" "NOT FOUND"
        fi
    }

    # Main uplink
    _row "$MAIN_VETH_HOST" "main(0)"
    _row "$MAIN_VETH_BR"   "→ bridge"

    echo "$SEP"

    # VRF interfaces
    for idx in 0 1 2; do
        local num=$(( idx+1 ))
        _row "veth${num}-vrf" "${TABLES[$idx]}"
        _row "veth${num}-br"  "→ bridge"
        [[ $idx -lt 2 ]] && echo "$SEP"
    done

    echo  "├──────────────────┼────────────┼───────────────┼───────────────┤"
    _row "$BRIDGE" "L2 bridge"
    echo  "└──────────────────┴────────────┴───────────────┴───────────────┘"

    echo ""
    echo "  ── Connectivity tests ───────────────────────────────────────────"
    echo "  # Main table → VRFs  (direct, no vrf exec needed)"
    echo "    ping -c3 10.0.1.1 -I 10.0.1.254 # main → vrf1"
    echo "    ping -c3 10.0.1.2 -I 10.0.1.254 # main → vrf2"
    echo "    ping -c3 10.0.1.3 -I 10.0.1.254 # main → vrf3"
    echo ""
    echo "  # Cross-VRF (traffic traverses the bridge)"
    echo "    sudo ip vrf exec vrf1 ping -c3 10.0.1.2 -I 10.0.1.1 # vrf1 → vrf2"
    echo "    sudo ip vrf exec vrf1 ping -c3 10.0.1.3 -I 10.0.1.1 # vrf1 → vrf3"
    echo "    sudo ip vrf exec vrf2 ping -c3 10.0.1.3 -I 10.0.1.2 # vrf2 → vrf3"
    echo ""
    echo "  # VRF → main table"
    echo "    sudo ip vrf exec vrf1 ping -c3 10.0.1.254 -I 10.0.1.1 # vrf1 → main"
    echo ""
    echo "  ── Route inspection ─────────────────────────────────────────────"
    echo "    ip route                       # main table"
    echo "    sudo ip vrf exec vrf1 ip route      # vrf1 table"
    echo "    sudo ip vrf exec vrf2 ip route      # vrf2 table"
    echo "    sudo ip vrf exec vrf3 ip route      # vrf3 table"
}

# ── Entry point ───────────────────────────────────────────────────────────────
usage() {
    echo "Usage: sudo $0 [setup|teardown|status]"
    echo "  setup    — Build VRFs, veth pairs, main uplink, and bridge  (default)"
    echo "  teardown — Remove all created interfaces"
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