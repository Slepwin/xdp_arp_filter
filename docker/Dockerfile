# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang llvm \
    libbpf-dev libelf-dev zlib1g-dev \
    linux-tools-common linux-tools-generic \
    linux-headers-generic \
    make gcc \
 && rm -rf /var/lib/apt/lists/*

# Symlink bpftool in case it landed in a versioned path
RUN bpftool --version 2>/dev/null || \
    ln -s /usr/lib/linux-tools/*/bpftool /usr/local/sbin/bpftool

WORKDIR /build
COPY xdp_arp_filter_kern.c \
     xdp_arp_filter_user.c \
     Makefile ./

RUN make

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libbpf1 libelf1 zlib1g \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/xdp_arp_filter /usr/local/bin/xdp_arp_filter

# Default allowlist location inside the container
RUN mkdir -p /etc/xdp_arp_filter
COPY allowed_ips.txt /etc/xdp_arp_filter/allowed_ips.txt

ENTRYPOINT ["/usr/local/bin/xdp_arp_filter"]
CMD ["-h"]