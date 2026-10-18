# SPDX-License-Identifier: Apache-2.0
#
# Ubuntu 26.04 LTS bootc + GNOME.
#
# Built on jmarrero/ubuntu-bootc (Apache-2.0) with the changes measured during the DeskOS spike.
# Each change below has a reason that was measured, not assumed:
#
#  - libclang-dev in the builder (the build was broken at HEAD)
#  - ubuntu-desktop-minimal + grim, with kdump-tools excluded (it broke the kernel configure step)
#  - stock 26.04 kernel, without the questing 6.17 pin (the fsverity fix already landed)
#  - locale generated in the image, plus timezone and keyboard
#  - first-login wizard suppressed
#  - the /var skeleton that `rm -rf /var` destroys is saved before the wipe and restored after
#
# Flatpak is deliberately absent, and this base carries no third-party apt source. 26.04 publishes
# flatpak 1.16.6 and `flatpak preinstall` only exists since 1.17; the only source of a newer one was
# the Flatpak team PPA, and a DeskOS base stays on its vendor's archive. A platform that wants a
# system Flatpak channel needs a base that carries one and says so, which is that platform's
# decision, not this base's.

FROM scratch AS ctx
COPY shared/ /shared

FROM docker.io/library/ubuntu:resolute AS base

# --- Stage 1: builder --------------------------------------------------------

FROM base AS builder

ARG DEBIAN_FRONTEND=noninteractive

# libclang-dev is required by bindgen (selinux-sys). Without it the build dies with
# "Unable to find libclang" while generating manpages.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt update -y && \
    apt install -y git curl make build-essential go-md2man libzstd-dev pkgconf libostree-dev ostree libclang-dev

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
WORKDIR /home/build
# shared/build.sh pins the bootc commit. Cloning HEAD unpinned is what broke this build once.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    sh -c ". ${RUSTUP_HOME}/env ; /ctx/shared/build.sh"

# --- Stage 2: system --------------------------------------------------------

FROM base AS system

ARG DEBIAN_FRONTEND=noninteractive

COPY --from=builder /output /

# kdump-tools is excluded on purpose: it is a Recommends of ubuntu-desktop-minimal and its postinst
# hook generates a crash-dump initramfs which dies inside a container build with
# "mkinitramfs: failed to determine device for /", failing the kernel's configure step.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot apt update -y && \
  apt install -y cloud-init nano snapd sudo openssh-server ubuntu-desktop-minimal grim kdump-tools- \
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
    btrfs-progs dosfstools e2fsprogs fdisk \
    linux-firmware linux-image-generic \
    podman skopeo systemd systemd-boot* xfsprogs ostree libostree-dev dracut whois bubblewrap && \
  cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz" && \
  apt clean -y

# Locales generated in the image: it cannot be done at runtime (/usr/lib/locale lives under a
# read-only /usr). The image defaults to en_US.UTF-8 and generates the ones a region may pick. The
# language, the timezone and the keyboard are chosen per user by GNOME Initial Setup at first
# boot, or by an organization's own layer; nothing else is pinned here.
RUN printf 'en_US.UTF-8 UTF-8\nes_EC.UTF-8 UTF-8\n' >> /etc/locale.gen && locale-gen && \
    printf 'LANG=en_US.UTF-8\n' > /etc/default/locale

# cloud-init: growpart on /sysroot, default home, networking left to systemd-networkd
RUN mkdir -p /etc/cloud/cloud.cfg.d && \
    printf "growpart:\n  mode: auto\n  devices: [\"/sysroot\"]\nresize_rootfs: false\nsystem_info:\n  default_user:\n    homedir: /var/home/ubuntu\nnetwork:\n  config: disabled\n" \
    > /etc/cloud/cloud.cfg.d/10_bootc.cfg

# base services
RUN ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service && \
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service && \
    ln -sf /usr/lib/systemd/system/systemd-resolved.service /usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service

# tmpfiles: resolv.conf and state directories.
RUN mkdir -p /usr/lib/tmpfiles.d && \
    printf "L+ /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n" > /usr/lib/tmpfiles.d/resolved-fix.conf && \
    printf "d /var/lib/snapd 0755 root root -\nd /var/cache/snapd 0755 root root -\nd /var/snap 0755 root root -\n" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

# DHCP for ethernet interfaces
RUN mkdir -p /etc/systemd/network/ && \
    printf '[Match]\nName=e*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/10-eth-dhcp.network

# initramfs with bootc's dracut module
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/initramfs.sh

# snap compatibility: real directories plus bind mount units
COPY usr/ usr/

# bootc-rootfs.sh runs `rm -rf /var`, and that takes with it the directory skeleton that packages
# install there (snapd: /var/lib/snapd/{void,apparmor/snap-confine,hostfs,...}; ubuntu-advantage:
# /var/lib/ubuntu-advantage). That broke `apparmor.service` on first boot and made
# `snap run firefox` fail with "cannot create void directory".
# Before the wipe the skeleton is saved (DIRECTORIES ONLY, with mode and owner) and restored after:
# the structure packages expect is preserved, not the state.
# Mind `void`: its mode is 0111 on purpose (it is a "void" used as a mount point).
#
# The PACKAGE DATABASE is the exception that is not just a skeleton. ADR 0015 requires the package
# database to be image content, not state: without it a derived image installs blindly. Measured on
# this base before the change, installing curl would install 35 packages of which 34 were already
# on disk, because dpkg knew nothing. So the database is copied into /usr before the wipe, and dpkg
# and apt are pointed at the copy. The RPM family does the same thing with /usr/lib/sysimage/rpm.
#
# General rule from the flatpak case: restoring directories only leaves half-initialized what a tool
# has to initialize coherently. With /var/lib/flatpak/repo present but its `config` file missing,
# flatpak fails with "opening repo: openat(config): No such file or directory"; with the directory
# absent it creates the whole thing. A directory a tool fails on with "no such file" over a config
# file inside it belongs in this list.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    install -d /usr/share/deskos-ubuntu-bootc && \
    find /var -type d -printf '%m %u %g %p\n' | sort > /usr/share/deskos-ubuntu-bootc/var-skeleton && \
    install -d /usr/lib/sysimage && cp -a /var/lib/dpkg /usr/lib/sysimage/dpkg && \
    mkdir -p /etc/dpkg/dpkg.cfg.d && \
    printf 'admindir=/usr/lib/sysimage/dpkg\n' > /etc/dpkg/dpkg.cfg.d/99-admindir && \
    mkdir -p /etc/apt/apt.conf.d && \
    printf 'Dir::State::status "/usr/lib/sysimage/dpkg/status";\n' > /etc/apt/apt.conf.d/99-admindir && \
    echo "HOME=/var/home" | tee -a "/etc/default/useradd" && \
    /ctx/shared/bootc-rootfs.sh && \
    while read -r m u g p; do install -d -m "$m" -o "$u" -g "$g" "$p"; done < /usr/share/deskos-ubuntu-bootc/var-skeleton && \
    rm -rf /var/lib/flatpak && \
    systemctl enable snap.mount home.mount root.mount opt.mount mnt.mount srv.mount

# The upstream image is a *container*, and it carries a uid-1000 `ubuntu` account for `podman exec`.
# This is a workstation base, and that account is not harmless: GDM starts GNOME Initial Setup only
# when no user exists, and asks AccountsService, which counts it. Measured on 2026-10-16: the user
# list AccountsService gave GDM was exactly `/org/freedesktop/Accounts/User1000`, so GDM drew its
# greeter and the wizard never ran, while the package, the helper, the session file and the shell
# mode were all present. Removing the account is what makes the wizard run, and what makes "this base
# carries no account" true instead of "the one it carries cannot log in".
RUN set -eux; \
    userdel ubuntu; \
    ! getent passwd ubuntu

# Desktop bootstrap: the graphical target and the display manager. No account is created and no
# session is automatic: GNOME Initial Setup creates the account and offers the language, the
# timezone and the keyboard at first boot, which is what makes those choices per user. An
# organization that provisions accounts itself suppresses the wizard in its own layer.
#
# Homes live under /home because snap requires it: /home is a bind mount of /var/home, so an
# account created with the default home path gets one snap can use.
RUN set -eux; \
    systemctl set-default graphical.target; \
    dm=""; \
    for u in gdm3 gdm lightdm; do \
        if [ -f "/usr/lib/systemd/system/$u.service" ]; then dm="$u"; break; fi; \
    done; \
    test -n "$dm"; \
    echo "display manager: $dm"; \
    systemctl enable "$dm"

LABEL containers.bootc 1

RUN bootc container lint
