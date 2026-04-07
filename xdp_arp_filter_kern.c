// SPDX-License-Identifier: GPL-2.0
// XDP eBPF program to filter ARP requests by source IP address
// Only ARP requests from IPs present in the allowed_ips hash map are passed through

// BPF programs must avoid userspace libc headers — they pull in glibc internals
// (sys/socket.h, gnu/stubs.h, etc.) that don't exist in the BPF compilation env.
// Use only linux/bpf.h, linux/if_ether.h and define ARP constants directly.

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// ARP constants (avoids including linux/if_arp.h which drags in libc headers)
#define ARPHRD_ETHER    1       // Ethernet hardware type
#define ARPOP_REQUEST   1       // ARP request opcode
#define ETH_P_IP        0x0800  // IPv4 EtherType
#define ETH_P_ARP       0x0806  // ARP EtherType

// ARP header structure (for Ethernet + IPv4)
struct arphdr_eth_ipv4 {
    __be16 ar_hrd;      // Hardware type (Ethernet = 1)
    __be16 ar_pro;      // Protocol type (IPv4 = 0x0800)
    __u8   ar_hln;      // Hardware address length (6 for MAC)
    __u8   ar_pln;      // Protocol address length (4 for IPv4)
    __be16 ar_op;        // ARP operation (1 = request, 2 = reply)
    __u8   ar_sha[6];   // Sender hardware address (MAC)
    __be32 ar_sip;      // Sender IP address
    __u8   ar_tha[6];   // Target hardware address (MAC)
    __be32 ar_tip;      // Target IP address
} __attribute__((packed));

// Hash map: key = IPv4 address (network byte order), value = dummy __u32
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, __u32);
    __uint(max_entries, 1024);
} allowed_ips SEC(".maps");

// Stats map: index 0 = passed, index 1 = dropped
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 2);
} arp_stats SEC(".maps");

static __always_inline void update_stats(__u32 index)
{
    __u64 *counter = bpf_map_lookup_elem(&arp_stats, &index);
    if (counter)
        __sync_fetch_and_add(counter, 1);
}

SEC("xdp")
int xdp_arp_filter(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // Parse Ethernet header
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // Only process ARP packets (EtherType 0x0806)
    if (eth->h_proto != bpf_htons(ETH_P_ARP))
        return XDP_PASS;

    // Parse ARP header
    struct arphdr_eth_ipv4 *arp = (void *)(eth + 1);
    if ((void *)(arp + 1) > data_end)
        return XDP_PASS;

    // Validate: Ethernet hardware type, IPv4 protocol, correct lengths
    if (arp->ar_hrd != bpf_htons(ARPHRD_ETHER) ||
        arp->ar_pro != bpf_htons(ETH_P_IP) ||
        arp->ar_hln != 6 ||
        arp->ar_pln != 4)
        return XDP_PASS;

    // Only filter ARP requests (opcode 1)
    // ARP replies are passed through unconditionally
    if (arp->ar_op != bpf_htons(ARPOP_REQUEST))
        return XDP_PASS;

    // Lookup sender IP in the allowed_ips map
    __u32 src_ip = arp->ar_sip;
    __u32 *allowed = bpf_map_lookup_elem(&allowed_ips, &src_ip);

    if (allowed) {
        // IP is in the whitelist — pass the ARP request
        update_stats(0);
        return XDP_PASS;
    }

    // IP not in whitelist — drop the ARP request
    update_stats(1);
    return XDP_DROP;
}

char _license[] SEC("license") = "GPL";
