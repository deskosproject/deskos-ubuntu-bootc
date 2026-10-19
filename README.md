# deskos-ubuntu-bootc

**Ubuntu 26.04 LTS as a bootc base image with GNOME**, maintained by the DeskOS
project — because Canonical publishes no bootc base of its own.

You almost certainly do not want this image directly: it is the **base** a DeskOS
workstation compiles onto. Install the workstation, not the base:

```bash
sudo bootc switch quay.io/deskos/deskos-ubuntu:26.04
```

The workstation image is built in
[`deskos-ubuntu`](https://github.com/deskosproject/deskos-ubuntu), and it starts
`FROM` this base pinned by digest. Use this repository when you need to change
the base itself — a new Ubuntu point release, a kernel, a bootc fix — or when you
are auditing what the base is.

**Owner: the Project DeskOS. Support tier: `organization`.** Canonical publishes no Ubuntu bootc base,
so DeskOS maintains this one — and *organization* is exactly what that tier means: nothing here is
backed by the operating system's vendor, and the Project DeskOS is the named owner accountable for
this base, its fixes and its updates. (The other tier is `vendor`, for a base the vendor itself
publishes and supports, as Red Hat does for RHEL 10.) Fixes and updates are proposed as pull requests
here and reviewed by the project, and the base is consumed by digest. The `Platform` resource that points
here lives in [`deskos-ubuntu`](https://github.com/deskosproject/deskos-ubuntu) and declares the
same owner and tier (ADR 0014). See "Provenance" and "Verified
status" to know what was tested and what was not.

This repository is **not DeskOS Core**. It is the *base* DeskOS compiles onto: the Ubuntu bootc
engineering (kernel, ostree/composefs, snapd, desktop) that someone has to maintain precisely
because **Canonical publishes no official bootc base**.

## Provenance and license

Fork of [`jmarrero/ubuntu-bootc`](https://github.com/jmarrero/ubuntu-bootc), taken at commit
`7dd974209f2278307e13be4dc9e449020802ae64`. **Apache-2.0** license (see `LICENSE`, from upstream).

The scripts under `shared/` share lineage with [`bootcrew/mono`](https://github.com/bootcrew/mono)
(bootcrew's Ubuntu recipe), also Apache-2.0.

Thanks to Joseph Marrero (Red Hat) for the original recipe, and to bootcrew for the bootc
integration work on Ubuntu.

## What we changed from upstream, and why

Everything below is **measured** (the recipe was built, installed to disk and booted):

1. **`libclang-dev` in the builder stage.** The build was broken at HEAD: `selinux-sys` uses
   bindgen and without libclang it fails with `Unable to find libclang` while generating manpages.
   It was made worse by `shared/build.sh` cloning `bootc` from **HEAD with no pin**: a floating
   dependency broke a build that used to be green. **Now pinned** to a `bootc` commit
   (`1a04bf23b438ec476c1cec31adf0d56312e5be5b`). Note: release `v1.17.1` **does not compile** in this
   environment (`make bin` fails with exit 101) while that commit does; that is why a commit is
   pinned rather than a tag.
2. **`kdump-tools` excluded** (`kdump-tools-`). It is a *Recommends* of `ubuntu-desktop-minimal`
   and its postinst hook generates a crash-dump initramfs which, inside a container build, dies
   with `mkinitramfs: failed to determine device for /`, breaking the kernel's configure step.
3. **Stock 26.04 kernel, without the questing 6.17 pin.** The upstream workaround targeted the
   Linux 7.0 fsverity regression; Ubuntu already merged stable v7.0.7 into `7.0.0-38.38`
   (`ovl: fix verity lazy-load guard broken by fsverity_active()`), and booting with the stock
   kernel was verified: composefs with `verity=require` boots fine.
4. **Flatpak is not in the image, and the base carries no third-party apt source.** Measured: the
   base's only apt sources are `archive.ubuntu.com` and `security.ubuntu.com`, with Ubuntu's own
   keyrings. The 26.04 archive publishes Flatpak **1.16.6**, and no suite of 26.04 carries a newer
   one (backports included), while `flatpak preinstall` — the mechanism a system `FlatpakSet` needs
   — only exists since 1.17. The spike got a newer one from the Flatpak team PPA, which is not
   Canonical's archive; carrying a moving third-party PPA inside a base is a supply-chain decision
   this project declined (ADR 0010). A platform that wants a system Flatpak channel needs a base
   that carries one and says so, and the `Platform` resource in `deskos-ubuntu` declares that Ubuntu offers none.
5. **Locales generated in the image** (`en_US.UTF-8` and `es_EC.UTF-8`), defaulting to
   `en_US.UTF-8`. It cannot be done at runtime: `/usr/lib/locale` lives under a read-only `/usr`.
   The timezone and the keyboard are **not** pinned: GNOME Initial Setup chooses them per user at
   first boot.
6. **No account, no autologin, and GNOME Initial Setup that runs.** The base creates no user: the
   uid-1000 `ubuntu` account the upstream *container* image ships is removed (`userdel`, asserted at
   build time). That was not cosmetic. GDM starts GNOME Initial Setup only when **no user exists**,
   and it asks AccountsService, which counted that account — so the wizard never ran. Measured on
   2026-10-16 by `tests/vm/firstbootcheck.py`, vendored from `deskos-core`, which asks the guest instead of reading
   a screenshot: with the account gone, the wizard is the session that comes up, and no account can
   log in. An organization that provisions accounts itself suppresses the wizard in its own layer.
7. **`/var` skeleton that `rm -rf /var` destroys.** Packages install directories under `/var`
   (snapd: `apparmor/snap-confine`, `void`, `hostfs`, `firstboot`, ...; ubuntu-advantage:
   `/var/lib/ubuntu-advantage`) and the recipe used to delete them. Measured effects:
   `apparmor.service` failed on first boot, and **`snap run firefox` died** with `cannot create
   void directory: /var/lib/snapd/void: Permission denied`. They are restored in the image,
   respecting the **0111** mode of `void` (it is a "void" used as a mount point, on purpose). With
   that: `apparmor` active on first boot and **snap Firefox running**. The mechanism is general:
   before the wipe the `/var` skeleton is saved (directories only, with mode and owner) and
   restored afterwards.
8. **`/var/lib/flatpak` stays excluded from that restore, as the standing example of a general
   rule.** Restoring directories only leaves half-initialized what a tool has to initialize
   coherently: with `/var/lib/flatpak/repo` present but its `config` file missing, flatpak fails with
   `opening repo: openat(config): No such file or directory`, while with the directory absent it
   creates the whole thing. Flatpak itself is no longer in the image (item 4); the rule stays for the
   next tool that behaves this way, and the general form is: a `/var` directory a tool fails on with
   "no such file" over a config file inside it belongs in this list.
9. **The package database is image content, not state** (ADR 0015). `rm -rf /var` took
   `/var/lib/dpkg` with it, so a derived image installed blindly: installing `curl` pulled **35
   packages, 34 of them already on disk**, because dpkg knew nothing. The database is now copied into
   `/usr/lib/sysimage/dpkg` before the wipe (the RPM family keeps its own at
   `/usr/lib/sysimage/rpm`), with `admindir=` in `/etc/dpkg/dpkg.cfg.d/` and `Dir::State::status` in
   `/etc/apt/apt.conf.d/`. **Measured on an earlier build (it still carried Flatpak, hence 1519 rather
   than the 1509 of the 2026-10-16 rebuild below): `dpkg -l` reports 1519 packages,
   `curl` resolves to 1 package, `jq` to 0, and a derived `FROM` this base
   installing `jq` reports "already the newest version".**
   The database lives in `/usr`, so on a booted machine it is readable but not writable: `apt` is a
   build-time tool here, not a way to change a running workstation.

## Verified status

| what | result |
|---|---|
| Build | OK (with the libclang fix). Rebuilt 2026-10-16 with no Flatpak and no third-party apt source |
| `bootc container lint` | 11 checks passed, 1 skipped, 3 warnings — the same lint set as before, on the 2026-10-16 rebuild |
| Install to disk (`--composefs-backend`) | OK — 2026-10-16 rebuild, installed out of a compressed OCI layout |
| Boot from digest-verified ComposeFS | OK — the 2026-10-16 rebuild's ESP entry asks for it (`composefs.digest=…`); the mount flags seen inside the guest were measured on an earlier build, so `verity=require` as such is not re-asserted here |
| Boot to GNOME Initial Setup | OK — 2026-10-16 rebuild: the wizard is the session that comes up, asserted by asking the guest (`tests/vm/firstbootcheck.py`, vendored from `deskos-core`). It did **not** run before this base removed the inherited `ubuntu` account: GDM counts users through AccountsService, and that uid-1000 account suppressed it. A screendump could not tell the two apart, because GDM's greeter draws a Username field too |
| No usable account | OK — the image carries no account at all: the upstream container image's `ubuntu` account is removed at build time |
| Flatpak | **not in the image** (item 4): 26.04 has no `flatpak preinstall`, and carrying the PPA that would provide one is declined. Earlier runs, still with that PPA, measured Flatpak 1.18.4 running apps (bwrap under the `unpriv_bwrap` profile) and installing one at first boot; that is no longer this base's state |
| GNOME + autologin | OK, measured **before** the autologin was removed; not re-measured since |
| `bootc switch` / `rollback` | OK, measured on an earlier build. Note: rollback **needs two reboots** (the operation runs at the end of boot; the next boot uses the previous image). `/var` and `/etc` persist in both directions. |
| snap: trivial apps (`hello-world`) | OK, measured on an earlier build |
| **snap: Firefox** | **OK**, measured on an earlier build — `/snap/firefox/9057/usr/lib/firefox/firefox` running, 18 AppArmor profiles, UI in Spanish |
| `apparmor.service` on first boot | OK, measured on an earlier build |
| **Package database** | `dpkg -l` reports **1509** packages from `/usr/lib/sysimage/dpkg` on the 2026-10-16 rebuild; the incremental-install measurement (`curl`: 1 package, `jq`: 0) is from an earlier build |
| Secure boot | not verified (the kernel is signed, `systemd-boot` is not) |
| Intune / CrowdStrike / VPN | **not verifiable outside a real corporate environment** |

Rows marked "earlier build" were measured on builds of this recipe that still carried
Flatpak. The 2026-10-16 rebuild changed which packages are installed (item 4) and
nothing about those rows, but until they are re-run they are history, not status.

## Known blockers

- **Home outside `/home`.** Snap requires the home under `/home`, and the bootc/ostree layout uses
  `/var/home`. The recipe keeps `/home` as a bind mount of `/var/home`, so an account created with
  the default home path (`/home/<user>`) gets one snap can use, and no files are moved.
- **Secure boot**: the stock kernel is signed, but the install uses `systemd-boot`, which is not.
  It requires a signed shim+grub chain or custom keys.
- **The ESP is not where `bootctl` looks for it.** At boot we see
  `bootctl: Couldn't find EFI system partition, skipping.`, so bootc cannot manage the EFI boot
  entries. Boot order still works (through bootc's own mechanism), but this deserves investigation:
  on real hardware with secure boot it matters.
- **This recipe's own tmpfiles lines**: the `/var` skeleton is written by two `printf`s that did not end
  in a newline, so the last line of the first one and the first line of the next were concatenated in
  the image: `d /var/snap 0755 root root -d /var/lib/snapd/snap 0755 root root -`, which systemd
  reports as `Invalid age '-d'` on every boot. The age field `-` is fine (it means "do not clean up");
  the missing newline was the bug. Fixed 2026-10-16 by ending both `printf`s in `\n`.

## Operational note (for whoever builds this)

- **Compiling `bootc` from scratch is heavy.** With 3 VMs running, `rustc` died with a **SIGSEGV**
  during LTO; with the VMs shut down it compiled fine. Free memory before building.
- **It consumes tens of GB.** The lab reached 100% disk with accumulated images and test disks;
  clean up (`podman rmi`, test disks) before each cycle.
- Changing the `bootc` pin (or any builder input) invalidates the cache: expect a long build.
- **Publishing takes OCI and an explicit tag.** `podman push --format=oci` (the same
  compression constraint as the install), and move `:latest` with an explicit `podman tag`: a
  local `latest` does not follow a new build. Push from the same storage the build used.

## Build and test

Everything below works in the same podman storage. A build and an install that do
not share storage do not see the same images: build with `sudo` too, or carry the
image across with `podman save | sudo podman load`.

    sudo podman build -f Containerfile -t localhost/ubuntu-bootc:local .

    # `podman build` leaves layers uncompressed
    # (`application/vnd.oci.image.layer.v1.tar`) and the composefs import rejects
    # them with "Invalid splitstream content type". Recompress into an OCI layout,
    # which is also what the install mounts as its source:
    sudo skopeo copy containers-storage:localhost/ubuntu-bootc:local oci:/var/tmp/ubuntu-oci:local
    sudo skopeo inspect --raw oci:/var/tmp/ubuntu-oci:local | python3 -c \
      "import json,sys;from collections import Counter;print(Counter(l['mediaType'] for l in json.load(sys.stdin)['layers']))"

    truncate -s 30G disk.raw
    # `--source-imgref` is where the install reads the image from; `--target-imgref`
    # is where the installed system will look for its updates. The two are different
    # questions, and the target here is this base's own reference because this
    # command installs the base. Someone installing a *derived* image must point the
    # target at that derivative's published reference: pointing it at the base would
    # make the next update replace the derivative with the base. Leaving the target
    # unset records the source (a lab path) as the update source, and then
    # `bootc upgrade` and the image update timer have nothing valid to stage.
    sudo podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
      -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
      -v /var/tmp/ubuntu-oci:/src-oci:ro -v $PWD:/output \
      localhost/ubuntu-bootc:local bootc install to-disk --via-loopback /output/disk.raw \
      --source-imgref oci:/src-oci:local \
      --target-imgref quay.io/deskos/deskos-ubuntu-bootc:26.04 \
      --composefs-backend --bootloader systemd --wipe --filesystem ext4 --allow-missing-verity

    # boot with a virtual GPU: without it there is no compositor. The firmware's
    # variable store must be a writable copy of the file shipped by edk2, never that
    # read-only file itself.
    cp /usr/share/edk2/ovmf/OVMF_VARS.fd .
    qemu-kvm -machine q35,accel=kvm -cpu host -m 6G -smp 4 \
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=OVMF_VARS.fd \
      -drive file=disk.raw,format=raw,if=virtio \
      -vga none -device virtio-vga -vnc 127.0.0.1:5 \
      -monitor unix:mon.sock,server,nowait

    # That smoke test boots without a NIC, which is all it needs. A guest that has to
    # reach the network — cloud-init, a user provisioning the machine — also needs
    # one: add `-netdev user,id=n0 -device virtio-net-pci,netdev=n0`, which the
    # image's `Name=e*` DHCP profile covers. That networked path was not measured here.

## Context

This base exists because DeskOS compiles artifacts onto each platform's bootc base, and Ubuntu has
no official one. What was verified, with what evidence, and what is still pending, is in "Verified
status" and "Known blockers" above.
