# xdp_arp_filter

An XDP/eBPF program that filters ARP requests at the earliest possible point in the Linux network stack. Only ARP requests whose **source IP** appears in a configurable allowlist are passed through; all others are dropped with zero kernel overhead. ARP replies are always forwarded unconditionally.

## Project Structure

```
xdp_arp_filter/
├── README.md
├── allowed_ips.txt
├── docker/
│   ├── Dockerfile
│   └── docker-compose.yml
├── environments/
│   ├── netns_setup.sh
│   └── vrf_setup.sh
└── src/
    ├── Makefile
    ├── xdp-arp-filter.service
    ├── xdp_arp_filter_kern.c
    └── xdp_arp_filter_user.c
```

---

## How It Works

```
NIC → XDP hook → xdp_arp_filter_kern.c
                   ├── non-ARP packet   → XDP_PASS  (untouched)
                   ├── ARP reply        → XDP_PASS  (untouched)
                   ├── ARP request, src IP in allowed_ips map → XDP_PASS + stats[passed]++
                   └── ARP request, src IP not in map         → XDP_DROP + stats[dropped]++
```

Two BPF maps are used:

| Map | Type | Key | Value | Purpose |
|-----|------|-----|-------|---------|
| `allowed_ips` | `BPF_MAP_TYPE_HASH` | IPv4 (`__u32`, network byte order) | dummy `__u32` | Allowlist of permitted source IPs |
| `arp_stats` | `BPF_MAP_TYPE_ARRAY` | index 0 = passed, 1 = dropped | `__u64` counter | Per-direction packet counters |

The userspace loader (`xdp_arp_filter_user.c`) uses **libbpf skeletons** to load and manage the BPF program and maps, reads IP addresses from a plain-text file, and supports persistent pin mode so the filter survives process exit.

---

## Dependencies

### Required packages

| Package | Purpose |
|---------|---------|
| `clang >= 14` | Compile BPF C to BPF bytecode (`-target bpf`) |
| `llvm` | LLVM backend used by clang for BPF |
| `libbpf-dev >= 1.0` | BPF skeleton API, `bpf_xdp_attach/detach`, map helpers |
| `libelf-dev` | ELF parsing (required by libbpf) |
| `zlib1g-dev` | Compression support (required by libbpf) |
| `bpftool` | Generate BPF skeleton header and dump kernel BTF |
| `linux-headers` | Kernel headers required for BPF compilation |

### Install commands

**Ubuntu 24.04 (Noble) / Ubuntu 22.04 (Jammy):**
```bash
sudo apt install clang llvm libbpf-dev libelf-dev zlib1g-dev \
    linux-tools-common linux-tools-$(uname -r) \
    linux-headers-$(uname -r)
```

If `linux-tools-$(uname -r)` is unavailable for your kernel variant:
```bash
sudo apt install linux-tools-generic
```

If `bpftool` is not in `PATH` after install, create a symlink:
```bash
sudo ln -s /usr/lib/linux-tools/*/bpftool /usr/local/sbin/bpftool
```

**Fedora 39+ / RHEL 9+ / Rocky / AlmaLinux:**
```bash
sudo dnf install clang llvm libbpf-devel elfutils-libelf-devel \
    bpftool kernel-headers
```

### Runtime requirements

- Linux kernel **5.9+** (XDP native/SKB mode with `bpf_xdp_attach`)
- Root privileges (`CAP_NET_ADMIN`, `CAP_BPF`) to attach XDP programs
- `bpffs` mounted at `/sys/fs/bpf` (standard on systemd systems)

---

## Build

```bash
# Clone or enter the project directory
cd xdp_arp_filter

# Build everything (BPF object → skeleton header → userspace binary)
make -C src
```

The build process runs three steps automatically:

1. `clang -target bpf` compiles `src/xdp_arp_filter_kern.c` → `src/xdp_arp_filter_kern.bpf.o`
2. `bpftool gen skeleton` generates `src/xdp_arp_filter_kern.skel.h`
3. `gcc` compiles `src/xdp_arp_filter_user.c` (using the skeleton) → `src/xdp_arp_filter`

**Optional targets:**

```bash
make -C src vmlinux      # Generate vmlinux.h from running kernel BTF (if needed)
make -C src clean        # Remove all build artifacts
```

You can override the compiler and bpftool paths:
```bash
make -C src CLANG=/usr/bin/clang-16 BPFTOOL=/usr/sbin/bpftool
```

---

## Allowed IPs File

Create a plain-text file with one IPv4 address per line:

```
# Allowed source IPs for ARP requests
# Lines starting with # and empty lines are ignored

10.0.1.1
10.0.1.2
192.168.100.5
```

A sample file is provided at `allowed_ips.txt`.

---

## Usage

```
Usage: xdp_arp_filter [OPTIONS]

Attach mode:
  xdp_arp_filter -i <ifname> -f <file> [-m mode] [-p] [-s]

Reload mode (hot-update pinned map, no detach):
  xdp_arp_filter -r -f <file>

Detach mode:
  xdp_arp_filter -i <ifname> [-m mode] -D

Options:
  -i <ifname>   Network interface to attach XDP program
  -f <file>     Text file with allowed IP addresses, one per line
  -m <mode>     XDP attach mode: native, skb, hw  (default: skb)
  -p            Pin maps & program to bpffs; exit without detaching
  -r            Reload: flush pinned map and re-read IPs from file
  -s            Show live stats every second (interactive mode)
  -D            Detach XDP from interface and remove pinned maps
  -h            Show help
```

### XDP attach modes

| Mode | Flag | Notes |
|------|------|-------|
| `skb` | `XDP_FLAGS_SKB_MODE` | Works on any driver; lower performance. Default. |
| `native` | `XDP_FLAGS_DRV_MODE` | Requires driver support; best performance. |
| `hw` | `XDP_FLAGS_HW_MODE` | NIC offload; requires hardware support. |

---

## Operating Modes

### Interactive mode (auto-detach on exit)

Attach the filter and run in the foreground. Press `Ctrl+C` to detach and exit cleanly.

```bash
sudo ./src/xdp_arp_filter -i eth0 -f allowed_ips.txt -m native -s
```

The `-s` flag prints live ARP pass/drop counters every second.

### Persistent mode (survives process exit)

Attach the filter, pin maps and program to `/sys/fs/bpf/xdp_arp_filter`, then exit. The XDP program remains active in the kernel as long as the interface is up or until explicitly detached.

```bash
sudo ./src/xdp_arp_filter -i eth0 -f allowed_ips.txt -m native -p
```

Pinned paths:

```
/sys/fs/bpf/xdp_arp_filter/prog
/sys/fs/bpf/xdp_arp_filter/allowed_ips
/sys/fs/bpf/xdp_arp_filter/arp_stats
```

### Hot-reload (zero-downtime IP list update)

Edit `allowed_ips.txt`, then flush and repopulate the pinned map without detaching the XDP program:

```bash
sudo ./src/xdp_arp_filter -r -f allowed_ips.txt
```

Requires the program to be running in persistent mode (`-p`).

### Detach

Remove the XDP program from the interface and clean up pinned objects:

```bash
sudo ./src/xdp_arp_filter -i eth0 -m native -D
```

---

## Systemd Service

A service unit is provided in `src/xdp-arp-filter.service` for production use.

**Install:**
```bash
# Install the binary
sudo cp src/xdp_arp_filter /usr/local/bin/

# Install the IP allowlist
sudo mkdir -p /etc/xdp_arp_filter
sudo cp allowed_ips.txt /etc/xdp_arp_filter/

# Edit the service unit to set the correct interface and mode
# Default: -i eth0 -m native  — adjust as needed
sudo cp src/xdp-arp-filter.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now xdp-arp-filter
```

**Manage:**
```bash
sudo systemctl start   xdp-arp-filter
sudo systemctl stop    xdp-arp-filter   # calls -D to detach
sudo systemctl restart xdp-arp-filter
sudo systemctl status  xdp-arp-filter
```

**Hot-reload allowed IPs without restarting the service:**
```bash
sudo nano /etc/xdp_arp_filter/allowed_ips.txt
sudo /usr/local/bin/xdp_arp_filter -r -f /etc/xdp_arp_filter/allowed_ips.txt
```

---

## Test Environments

Two environment setup scripts are provided under `environments/` for local testing.

### Network Namespaces (`netns_setup.sh`)

Creates 3 Linux network namespaces connected via a shared bridge:

```
main (default netns)  10.0.1.254/24
       │ veth0-main
       │ veth0-br
       └── br-ns (L2 bridge)
            ├── veth1-br ── veth1-ns  ns1  10.0.1.1/24
            ├── veth2-br ── veth2-ns  ns2  10.0.1.2/24
            └── veth3-br ── veth3-ns  ns3  10.0.1.3/24
```

```bash
sudo ./environments/netns_setup.sh setup
sudo ./environments/netns_setup.sh status
sudo ./environments/netns_setup.sh teardown
```

Attach the XDP filter on the bridge uplink and test from inside the namespaces:
```bash
sudo ./src/xdp_arp_filter -i veth0-br -f allowed_ips.txt -m skb -s
sudo ip netns exec ns1 ping -c3 10.0.1.2   # ns1 → ns2 (ARP from 10.0.1.1 — allowed)
sudo ip netns exec ns3 ping -c3 10.0.1.2   # ns3 → ns2 (ARP from 10.0.1.3 — dropped)
```

### VRFs (`vrf_setup.sh`)

Creates 3 Linux VRFs (routing tables 10, 20, 30) connected via a shared bridge — same IP layout as the netns environment, but using VRF devices in a single namespace:

```
main table  10.0.1.254/24
       │ veth0-main
       └── br-vrf (L2 bridge)
            ├── veth1-br ── veth1-vrf  vrf1 (table 10)  10.0.1.1/24
            ├── veth2-br ── veth2-vrf  vrf2 (table 20)  10.0.1.2/24
            └── veth3-br ── veth3-vrf  vrf3 (table 30)  10.0.1.3/24
```

```bash
sudo ./environments/vrf_setup.sh setup
sudo ./environments/vrf_setup.sh status
sudo ./environments/vrf_setup.sh teardown
```

Cross-VRF ping test:
```bash
sudo ip vrf exec vrf1 ping -c3 10.0.1.2 -I 10.0.1.1   # vrf1 → vrf2
sudo ip vrf exec vrf3 ping -c3 10.0.1.2 -I 10.0.1.3   # vrf3 → vrf2 (ARP from .3 — dropped)
```

---

## Docker

### Docker dependencies

| Requirement | Minimum version | Notes |
|-------------|----------------|-------|
| Docker Engine | **20.10+** | First version with `CAP_BPF` support |
| Host kernel | **5.9+** | Same as bare-metal; XDP attaches to the host kernel |
| Host `bpffs` | mounted at `/sys/fs/bpf` | Required for pin mode; standard on systemd hosts |

> **Important constraints**
> XDP programs are loaded into the **host kernel**, not into the container's namespace. The container is only used to build or run the userspace loader binary. The following host-level permissions are therefore mandatory at runtime:
> - `--network host` — the loader must reference host interface names (e.g. `eth0`)
> - `CAP_NET_ADMIN` — required to call `bpf_xdp_attach`
> - `CAP_BPF` — required for all BPF syscalls (Docker 20.10+)
> - `CAP_SYS_ADMIN` — required for bpffs pin operations
> - `/sys/fs/bpf` bind-mounted from the host — so pinned maps persist outside the container lifetime
> - `/sys/kernel/btf/vmlinux` bind-mounted from the host (read-only) — needed only if you regenerate `vmlinux.h` at runtime

### Build the image

From the project root:
```bash
docker build -f docker/Dockerfile -t xdp_arp_filter:latest .
```

To verify the build artifacts without pushing:
```bash
docker run --rm xdp_arp_filter:latest -h
```

### Required runtime flags

| Flag | Why it is needed |
|------|-----------------|
| `--network host` | Loader references host interfaces by name |
| `--cap-add CAP_NET_ADMIN` | `bpf_xdp_attach` / `bpf_xdp_detach` |
| `--cap-add CAP_BPF` | All BPF syscalls |
| `--cap-add SYS_ADMIN` | bpffs pin/unpin operations |
| `-v /sys/fs/bpf:/sys/fs/bpf` | Persist pinned maps outside the container |
| `--pid host` | (optional) Allows `bpftool` inside the container to see host BPF objects |

Using `--privileged` is equivalent to all of the above and simplifies the command, but grants broader access. Prefer explicit `--cap-add` flags in production.

### Run: interactive mode

```bash
docker run --rm \
  --network host \
  --cap-add CAP_NET_ADMIN --cap-add CAP_BPF --cap-add SYS_ADMIN \
  -v /sys/fs/bpf:/sys/fs/bpf \
  -v $(pwd)/allowed_ips.txt:/etc/xdp_arp_filter/allowed_ips.txt:ro \
  xdp_arp_filter:latest \
  -i eth0 -f /etc/xdp_arp_filter/allowed_ips.txt -m skb -s
```

Press `Ctrl+C` to detach and exit. The XDP program is removed automatically.

### Run: persistent mode (survives container stop)

```bash
docker run --rm \
  --network host \
  --cap-add CAP_NET_ADMIN --cap-add CAP_BPF --cap-add SYS_ADMIN \
  -v /sys/fs/bpf:/sys/fs/bpf \
  -v $(pwd)/allowed_ips.txt:/etc/xdp_arp_filter/allowed_ips.txt:ro \
  xdp_arp_filter:latest \
  -i eth0 -f /etc/xdp_arp_filter/allowed_ips.txt -m skb -p
```

The container exits immediately after pinning. The XDP program keeps running in the host kernel. Pinned objects are visible on the host at `/sys/fs/bpf/xdp_arp_filter/`.

### Hot-reload allowed IPs

Edit `allowed_ips.txt` on the host, then run the reload container:

```bash
docker run --rm \
  --cap-add CAP_BPF --cap-add SYS_ADMIN \
  -v /sys/fs/bpf:/sys/fs/bpf \
  -v $(pwd)/allowed_ips.txt:/etc/xdp_arp_filter/allowed_ips.txt:ro \
  xdp_arp_filter:latest \
  -r -f /etc/xdp_arp_filter/allowed_ips.txt
```

`--network host` is not needed for reload; the loader only touches the pinned BPF map, not the interface.

### Detach

```bash
docker run --rm \
  --network host \
  --cap-add CAP_NET_ADMIN --cap-add CAP_BPF --cap-add SYS_ADMIN \
  -v /sys/fs/bpf:/sys/fs/bpf \
  xdp_arp_filter:latest \
  -i eth0 -m skb -D
```


```bash
docker-compose -f docker/docker-compose.yml up -d          # attach and pin (persistent)
docker-compose -f docker/docker-compose.yml down           # does NOT detach — run the detach container manually
```

> **Note:** `docker-compose down` stops and removes the container but does **not** detach the XDP program from the interface. Always run the detach command explicitly before `docker-compose down` if you want to clean up the XDP hook.

---

## Troubleshooting

**`bpftool: command not found`** — See the install section; create a symlink from `/usr/lib/linux-tools/*/bpftool`.

**`ERROR: Failed to attach XDP program ... Operation not permitted`** — Run with `sudo` or ensure `CAP_NET_ADMIN` and `CAP_BPF` are granted.

**`ERROR: Cannot open pinned map '/sys/fs/bpf/xdp_arp_filter/allowed_ips'`** on reload — The program must have been started with `-p` (pin mode) first.

**Native mode fails on a virtual interface** — Virtual interfaces (veth, tun, bridge ports) typically require `skb` mode. Use `-m skb`.

**Verify XDP is attached:**
```bash
ip link show eth0          # look for "xdp" in the output
bpftool net show dev eth0  # shows attached XDP program name
```

**Inspect live map contents:**
```bash
bpftool map show           # list all maps, find allowed_ips id
bpftool map dump id <id>   # dump all entries
```

**Docker: `operation not permitted` when attaching XDP** — Ensure `--cap-add CAP_NET_ADMIN --cap-add CAP_BPF --cap-add SYS_ADMIN` and `--network host` are all present, or use `--privileged`.

**Docker: pinned maps not visible after container exits** — The `/sys/fs/bpf` bind mount must be present (`-v /sys/fs/bpf:/sys/fs/bpf`). Without it, pins are created inside the container's mount namespace and are lost when the container exits.

**Docker: `libbpf1` not found in runtime image** — On Ubuntu 22.04 the package is named `libbpf0`; change the runtime `apt-get install` line accordingly.

---

## License

GPL-2.0 — see `SPDX-License-Identifier` headers in source files.
