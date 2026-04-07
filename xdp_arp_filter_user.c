// SPDX-License-Identifier: GPL-2.0
// Userspace program to:
//   1. Load the XDP eBPF program and attach it to a network interface
//   2. Read IP addresses from a text file and populate the allowed_ips hash map
//   3. Optionally display stats and manage the map at runtime

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "xdp_arp_filter_kern.skel.h"

static volatile int running = 1;

// Forward declarations
static void dump_map(int map_fd);
static int load_ips_from_file(int map_fd, const char *filepath);

static void sig_handler(int sig)
{
    (void)sig;
    running = 0;
}

// BPF filesystem pin paths
#define PIN_BASE_DIR "/sys/fs/bpf/xdp_arp_filter"
#define PIN_PROG     PIN_BASE_DIR "/prog"
#define PIN_MAP_IPS  PIN_BASE_DIR "/allowed_ips"
#define PIN_MAP_STAT PIN_BASE_DIR "/arp_stats"

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "Attach mode:\n"
        "  %s -i <ifname> -f <file> [-m mode] [-p] [-s]\n"
        "\n"
        "Reload mode (hot-update pinned map, no detach):\n"
        "  %s -r -f <file>\n"
        "\n"
        "Detach mode:\n"
        "  %s -i <ifname> [-m mode] -D\n"
        "\n"
        "Options:\n"
        "  -i <ifname>     Network interface to attach XDP program (required for attach/detach)\n"
        "  -f <file>       Text file with allowed IP addresses, one per line\n"
        "  -m <mode>       XDP attach mode: native, skb, hw (default: skb)\n"
        "  -p              Pin maps & program to bpffs and exit (persistent mode)\n"
        "                  XDP stays attached after process exits; survives reboot\n"
        "                  with systemd service. Maps pinned at " PIN_BASE_DIR "\n"
        "  -r              Reload: flush pinned allowed_ips map and re-read from file.\n"
        "                  Requires -f. XDP program must be running with -p.\n"
        "                  Takes effect immediately — zero downtime.\n"
        "  -s              Show stats every second (poll mode, no -p)\n"
        "  -D              Detach XDP from interface and unpin maps, then exit\n"
        "  -h              Show this help message\n"
        "\n"
        "Examples:\n"
        "  # Interactive (Ctrl+C detaches):\n"
        "  %s -i eth0 -f allowed_ips.txt -m native -s\n"
        "\n"
        "  # Persistent (exit without detaching, pin maps):\n"
        "  %s -i eth0 -f allowed_ips.txt -m native -p\n"
        "\n"
        "  # Hot-reload allowed IPs (edit file, then reload):\n"
        "  %s -r -f allowed_ips.txt\n"
        "\n"
        "  # Detach persistent program:\n"
        "  %s -i eth0 -m native -D\n",
        prog, prog, prog, prog, prog, prog, prog, prog);
}

// Parse a single IP address line, skip comments and empty lines
// Returns 0 on success, -1 if line should be skipped
static int parse_ip_line(const char *line, struct in_addr *addr)
{
    char trimmed[256];
    int i = 0, j = 0;

    // Skip leading whitespace
    while (line[i] == ' ' || line[i] == '\t')
        i++;

    // Copy until comment char, newline, or end
    while (line[i] != '\0' && line[i] != '\n' && line[i] != '\r' &&
           line[i] != '#' && j < (int)sizeof(trimmed) - 1) {
        trimmed[j++] = line[i++];
    }
    trimmed[j] = '\0';

    // Trim trailing whitespace
    while (j > 0 && (trimmed[j - 1] == ' ' || trimmed[j - 1] == '\t'))
        trimmed[--j] = '\0';

    // Skip empty lines
    if (j == 0)
        return -1;

    if (inet_pton(AF_INET, trimmed, addr) != 1) {
        fprintf(stderr, "WARNING: Invalid IP address: '%s' (skipped)\n", trimmed);
        return -1;
    }

    return 0;
}

// Load IP addresses from file into the BPF hash map
static int load_ips_from_file(int map_fd, const char *filepath)
{
    FILE *fp = fopen(filepath, "r");
    if (!fp) {
        fprintf(stderr, "ERROR: Cannot open file '%s': %s\n",
                filepath, strerror(errno));
        return -1;
    }

    char line[256];
    int count = 0;
    int line_num = 0;

    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        struct in_addr addr;

        if (parse_ip_line(line, &addr) != 0)
            continue;

        __u32 ip_key = addr.s_addr;  // Already in network byte order
        __u32 value  = 1;            // Dummy value

        if (bpf_map_update_elem(map_fd, &ip_key, &value, BPF_ANY) != 0) {
            fprintf(stderr, "ERROR: Failed to add IP %s to map (line %d): %s\n",
                    inet_ntoa(addr), line_num, strerror(errno));
            continue;
        }

        printf("  Allowed: %s\n", inet_ntoa(addr));
        count++;
    }

    fclose(fp);
    printf("Loaded %d IP addresses into allowed_ips map\n", count);
    return count;
}

// Flush all entries from a BPF hash map
static int flush_map(int map_fd)
{
    __u32 key;
    int deleted = 0;

    // Iterate and delete — get_next_key(NULL) always returns first key
    while (bpf_map_get_next_key(map_fd, NULL, &key) == 0) {
        bpf_map_delete_elem(map_fd, &key);
        deleted++;
    }

    return deleted;
}

// Reload: open pinned map, flush old entries, load new ones from file
static int do_reload(const char *filepath)
{
    // Open the pinned allowed_ips map
    int map_fd = bpf_obj_get(PIN_MAP_IPS);
    if (map_fd < 0) {
        fprintf(stderr, "ERROR: Cannot open pinned map '%s': %s\n"
                "  Is the XDP program running with -p (pin mode)?\n",
                PIN_MAP_IPS, strerror(errno));
        return 1;
    }

    // Show current state
    printf("Current map state:\n");
    dump_map(map_fd);

    // Flush old entries
    int flushed = flush_map(map_fd);
    printf("\nFlushed %d old entries\n", flushed);

    // Load new entries from file
    printf("Loading new IPs from '%s':\n", filepath);
    int loaded = load_ips_from_file(map_fd, filepath);
    if (loaded < 0) {
        fprintf(stderr, "ERROR: Failed to reload IPs\n");
        close(map_fd);
        return 1;
    }

    // Show new state
    printf("\nNew map state:\n");
    dump_map(map_fd);

    printf("\nReload complete — filter updated immediately (no detach needed)\n");

    close(map_fd);
    return 0;
}

// Print current stats from the arp_stats array map
static void print_stats(int stats_fd)
{
    __u32 key;
    __u64 value;

    key = 0;
    value = 0;
    bpf_map_lookup_elem(stats_fd, &key, &value);
    __u64 passed = value;

    key = 1;
    value = 0;
    bpf_map_lookup_elem(stats_fd, &key, &value);
    __u64 dropped = value;

    printf("\r  ARP requests — passed: %llu  dropped: %llu",
           (unsigned long long)passed, (unsigned long long)dropped);
    fflush(stdout);
}

// Dump all entries currently in the allowed_ips map
static void dump_map(int map_fd)
{
    __u32 key, next_key;
    __u32 value;
    int count = 0;

    printf("\nCurrent allowed IPs in map:\n");

    if (bpf_map_get_next_key(map_fd, NULL, &key) != 0) {
        printf("  (empty)\n");
        return;
    }

    do {
        if (bpf_map_lookup_elem(map_fd, &key, &value) == 0) {
            struct in_addr addr;
            addr.s_addr = key;
            printf("  %s\n", inet_ntoa(addr));
            count++;
        }
    } while (bpf_map_get_next_key(map_fd, &key, &next_key) == 0 &&
             (key = next_key, 1));

    printf("Total: %d entries\n", count);
}

// Ensure pin directory exists
static int ensure_pin_dir(void)
{
    struct stat st;
    if (stat(PIN_BASE_DIR, &st) == 0)
        return 0;
    if (mkdir(PIN_BASE_DIR, 0700) != 0) {
        fprintf(stderr, "ERROR: Cannot create pin dir '%s': %s\n",
                PIN_BASE_DIR, strerror(errno));
        return -1;
    }
    return 0;
}

// Detach XDP from interface and remove pinned objects
static int do_detach(const char *ifname, __u32 xdp_flags)
{
    unsigned int ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        fprintf(stderr, "ERROR: Interface '%s' not found: %s\n",
                ifname, strerror(errno));
        return 1;
    }

    printf("Detaching XDP program from '%s'...\n", ifname);
    if (bpf_xdp_detach(ifindex, xdp_flags, NULL) < 0) {
        fprintf(stderr, "WARNING: Failed to detach XDP: %s\n", strerror(errno));
    } else {
        printf("XDP program detached\n");
    }

    // Remove pinned objects
    unlink(PIN_PROG);
    unlink(PIN_MAP_IPS);
    unlink(PIN_MAP_STAT);
    rmdir(PIN_BASE_DIR);
    printf("Pinned maps removed from %s\n", PIN_BASE_DIR);

    return 0;
}

int main(int argc, char **argv)
{
    const char *ifname   = NULL;
    const char *ip_file  = NULL;
    const char *mode_str = "skb";
    int show_stats       = 0;
    int pin_mode         = 0;
    int detach_mode      = 0;
    int reload_mode      = 0;
    int opt;

    while ((opt = getopt(argc, argv, "i:f:m:sprDh")) != -1) {
        switch (opt) {
        case 'i':
            ifname = optarg;
            break;
        case 'f':
            ip_file = optarg;
            break;
        case 'm':
            mode_str = optarg;
            break;
        case 's':
            show_stats = 1;
            break;
        case 'p':
            pin_mode = 1;
            break;
        case 'r':
            reload_mode = 1;
            break;
        case 'D':
            detach_mode = 1;
            break;
        case 'h':
        default:
            usage(argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }

    // Reload mode: doesn't need interface, just the file and pinned map
    if (reload_mode) {
        if (!ip_file) {
            fprintf(stderr, "ERROR: -r requires -f <file>\n\n");
            usage(argv[0]);
            return 1;
        }
        return do_reload(ip_file);
    }

    if (!ifname) {
        fprintf(stderr, "ERROR: -i <ifname> is required\n\n");
        usage(argv[0]);
        return 1;
    }

    // Resolve interface index
    unsigned int ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        fprintf(stderr, "ERROR: Interface '%s' not found: %s\n",
                ifname, strerror(errno));
        return 1;
    }

    // Determine XDP attach mode
    __u32 xdp_flags = 0;
    if (strcmp(mode_str, "native") == 0) {
        xdp_flags = XDP_FLAGS_DRV_MODE;
    } else if (strcmp(mode_str, "skb") == 0) {
        xdp_flags = XDP_FLAGS_SKB_MODE;
    } else if (strcmp(mode_str, "hw") == 0) {
        xdp_flags = XDP_FLAGS_HW_MODE;
    } else {
        fprintf(stderr, "ERROR: Unknown XDP mode '%s' (use: native, skb, hw)\n",
                mode_str);
        return 1;
    }

    // Handle detach mode
    if (detach_mode)
        return do_detach(ifname, xdp_flags);

    // Attach mode requires IP file
    if (!ip_file) {
        fprintf(stderr, "ERROR: -f <file> is required for attach mode\n\n");
        usage(argv[0]);
        return 1;
    }

    // Open and load BPF skeleton
    struct xdp_arp_filter_kern_bpf *skel = xdp_arp_filter_kern_bpf__open_and_load();
    if (!skel) {
        fprintf(stderr, "ERROR: Failed to open/load BPF skeleton: %s\n",
                strerror(errno));
        return 1;
    }

    printf("BPF program loaded successfully\n");

    // Get map file descriptors
    int map_fd   = bpf_map__fd(skel->maps.allowed_ips);
    int stats_fd = bpf_map__fd(skel->maps.arp_stats);

    // Load IPs from file
    printf("Loading allowed IPs from '%s':\n", ip_file);
    if (load_ips_from_file(map_fd, ip_file) < 0) {
        fprintf(stderr, "ERROR: Failed to load IPs\n");
        xdp_arp_filter_kern_bpf__destroy(skel);
        return 1;
    }

    // Dump map contents for verification
    dump_map(map_fd);

    // Attach XDP program to the interface
    int prog_fd = bpf_program__fd(skel->progs.xdp_arp_filter);
    if (bpf_xdp_attach(ifindex, prog_fd, xdp_flags, NULL) < 0) {
        fprintf(stderr, "ERROR: Failed to attach XDP program to %s: %s\n",
                ifname, strerror(errno));
        xdp_arp_filter_kern_bpf__destroy(skel);
        return 1;
    }

    printf("\nXDP program attached to interface '%s' (ifindex %u, mode: %s)\n",
           ifname, ifindex, mode_str);

    // Pin mode: pin maps and program to bpffs, then exit without detaching
    if (pin_mode) {
        if (ensure_pin_dir() < 0) {
            bpf_xdp_detach(ifindex, xdp_flags, NULL);
            xdp_arp_filter_kern_bpf__destroy(skel);
            return 1;
        }

        // Remove stale pins if they exist
        unlink(PIN_PROG);
        unlink(PIN_MAP_IPS);
        unlink(PIN_MAP_STAT);

        if (bpf_obj_pin(prog_fd, PIN_PROG) < 0) {
            fprintf(stderr, "ERROR: Failed to pin program: %s\n", strerror(errno));
            bpf_xdp_detach(ifindex, xdp_flags, NULL);
            xdp_arp_filter_kern_bpf__destroy(skel);
            return 1;
        }
        bpf_obj_pin(map_fd, PIN_MAP_IPS);
        bpf_obj_pin(stats_fd, PIN_MAP_STAT);

        printf("Program and maps pinned to %s\n", PIN_BASE_DIR);
        printf("XDP will remain attached after this process exits.\n");
        printf("To detach later:  %s -i %s -m %s -D\n", argv[0], ifname, mode_str);

        // Destroy skeleton (closes FDs) but XDP stays attached via kernel refcount
        xdp_arp_filter_kern_bpf__destroy(skel);
        return 0;
    }

    // Interactive mode
    printf("Filtering ARP requests — only allowing listed source IPs\n");
    printf("Press Ctrl+C to detach and exit\n\n");

    // Install signal handler for clean shutdown
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    // Main loop
    while (running) {
        if (show_stats)
            print_stats(stats_fd);
        sleep(1);
    }

    printf("\n\nDetaching XDP program from '%s'...\n", ifname);

    // Detach XDP program
    bpf_xdp_detach(ifindex, xdp_flags, NULL);

    // Print final stats
    printf("Final stats:\n");
    __u32 key = 0;
    __u64 value = 0;
    bpf_map_lookup_elem(stats_fd, &key, &value);
    printf("  ARP requests passed:  %llu\n", (unsigned long long)value);
    key = 1;
    value = 0;
    bpf_map_lookup_elem(stats_fd, &key, &value);
    printf("  ARP requests dropped: %llu\n", (unsigned long long)value);

    xdp_arp_filter_kern_bpf__destroy(skel);
    printf("Cleanup complete\n");

    return 0;
}
