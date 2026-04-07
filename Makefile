# SPDX-License-Identifier: GPL-2.0
# Makefile for XDP ARP Filter
#
# Prerequisites:
#   - clang >= 14 (for BPF target)
#   - libbpf-dev >= 1.0
#   - bpftool
#   - linux-headers for your kernel
#
# On Ubuntu 24.04 (Noble):
#   sudo apt install clang llvm libbpf-dev libelf-dev zlib1g-dev \
#       linux-tools-common linux-tools-$(uname -r) \
#       linux-headers-$(uname -r)
#
#   If 'linux-tools-$(uname -r)' is unavailable for your kernel, use:
#   sudo apt install linux-tools-generic
#
#   bpftool ships inside linux-tools-common on 24.04.
#   If 'which bpftool' returns nothing, symlink it:
#     sudo ln -s /usr/lib/linux-tools/*/bpftool /usr/local/sbin/bpftool
#
# On Ubuntu 22.04 (Jammy):
#   sudo apt install clang llvm libbpf-dev libelf-dev zlib1g-dev \
#       linux-tools-common linux-tools-$(uname -r) \
#       linux-headers-$(uname -r)
#
# On Fedora 39+ / RHEL 9+:
#   sudo dnf install clang llvm libbpf-devel elfutils-libelf-devel \
#       bpftool kernel-headers

CLANG      ?= clang
CC         ?= gcc

# Auto-detect bpftool:
#   1) Check PATH
#   2) Ubuntu fallback: /usr/lib/linux-tools/<kver>/bpftool
#   3) Ubuntu generic:  /usr/lib/linux-tools/*/bpftool (glob picks latest)
BPFTOOL    ?= $(shell which bpftool 2>/dev/null || \
               ([ -x /usr/lib/linux-tools/$$(uname -r)/bpftool ] && \
                echo /usr/lib/linux-tools/$$(uname -r)/bpftool) || \
               ls /usr/lib/linux-tools/*/bpftool 2>/dev/null | tail -1)

# Detect target arch for BPF
ARCH       := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

# Resolve arch-specific include path (asm/types.h, asm/byteorder.h, etc.)
# clang -target bpf doesn't search these automatically
HOST_ARCH  := $(shell uname -m)
ARCH_INCLUDES := -I/usr/include/$(HOST_ARCH)-linux-gnu

# BPF compile flags
BPF_CFLAGS := -O2 -g -target bpf -D__TARGET_ARCH_$(ARCH) $(ARCH_INCLUDES)

# Userspace compile flags
CFLAGS     := -O2 -g -Wall -Wextra
LDFLAGS    := -lbpf -lelf -lz

# Auto-detect vmlinux.h include path
VMLINUX_H := vmlinux.h

.PHONY: all clean vmlinux

all: xdp_arp_filter

# Generate vmlinux.h from running kernel BTF (if not already present)
$(VMLINUX_H):
	$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@

# Compile BPF object
xdp_arp_filter_kern.bpf.o: xdp_arp_filter_kern.c
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# Generate BPF skeleton header from the compiled BPF object
xdp_arp_filter_kern.skel.h: xdp_arp_filter_kern.bpf.o
	$(BPFTOOL) gen skeleton $< > $@

# Compile userspace loader (depends on skeleton header)
xdp_arp_filter: xdp_arp_filter_user.c xdp_arp_filter_kern.skel.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f xdp_arp_filter_kern.bpf.o xdp_arp_filter_kern.skel.h
	rm -f xdp_arp_filter
	rm -f $(VMLINUX_H)
