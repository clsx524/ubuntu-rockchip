# Building Ubuntu 26.04 (Resolute) for Turing RK1

This document describes how the four repositories in this project fit
together, the GitHub Actions pipeline that builds and publishes everything,
and how to reproduce a build locally.

The instructions below are written for the Turing RK1 / Ubuntu 26.04
(`resolute`) configuration. The same flow works for any other board / suite
in `config/boards/` and `config/suites/`.

---

## Repository map

```diagram
╭───────────────────────────────╮      ╭────────────────────────────────╮
│ linux-rockchip (fork)         │      │ ubuntu-rockchip-settings        │
│   Armbian rk-6.1-rkr*  +      │      │   • debian/ source for         │
│   `resolute` branch with      │      │     ubuntu-rockchip-settings,  │
│   Ubuntu changelog metadata.  │      │     ubuntu-{server,desktop}-    │
│   CI builds linux-image-*.deb │      │     rockchip, linux-rockchip   │
│   and publishes to apt repo.  │      │     meta-packages.             │
╰────────────┬──────────────────╯      │   • ships /etc/cloud and       │
             │                          │     /usr/lib/u-boot-menu       │
             │ kernel debs              │     defaults.                  │
             │                          ╰────────────┬───────────────────╯
             │                                        │ meta debs
             ▼                                        ▼
       ╭─────────────────────────────────────────────────────╮
       │ ubuntu-rockchip-apt                                  │
       │   GitHub Pages apt repo at                           │
       │   https://clsx524.github.io/ubuntu-rockchip-apt      │
       │   ingest.yml drops a deb into pool/+dists/,          │
       │   publish.yml signs Release with GPG, deploys Pages. │
       ╰────────────────────────┬────────────────────────────╯
                                │ apt-get install (during image build)
                                ▼
       ╭───────────────────────────────────────────────────╮
       │ ubuntu-rockchip (this repo)                       │
       │   build.sh orchestrates kernel+u-boot+rootfs+image │
       │   • kernel:    scripts/build-kernel.sh             │
       │   • u-boot:    scripts/build-u-boot.sh             │
       │   • rootfs:    scripts/build-rootfs.sh (live-build)│
       │   • image:     scripts/config-image.sh +           │
       │                scripts/build-image.sh              │
       │   Output:      images/*.img.xz                     │
       ╰───────────────────────────────────────────────────╯
```

The two reference repos in the workspace, `linux-rockchip-joshua` and
`ubuntu-rockchip-joshua`, are upstream snapshots from
@Joshua-Riek (24.10 / Oracular). They are kept for diff/comparison only and
are not part of the build.

---

## Build flow (what happens in either CI or local)

1. **Kernel** — `scripts/build-kernel.sh` clones `KERNEL_REPO` at
   `KERNEL_BRANCH` (defined in `config/suites/<suite>.sh`) and runs
   `fakeroot debian/rules clean binary-headers binary-rockchip` to produce:
   - `linux-image-<ver>-rockchip_*.deb`
   - `linux-headers-<ver>-rockchip_*.deb`
   - `linux-modules-<ver>-rockchip_*.deb`
   - `linux-buildinfo-<ver>-rockchip_*.deb`
   - `linux-rockchip-headers-<ver>_*.deb`

2. **U-Boot** — `scripts/build-u-boot.sh` builds the board-specific
   `u-boot-<board>` deb. For RK1 this is `u-boot-turing-rk3588`, target
   `turing-rk1-rk3588`. The deb installs `/usr/lib/u-boot/u-boot-rockchip.bin`
   into the chroot.

3. **Rootfs** — `scripts/build-rootfs.sh` runs `live-build`
   (`PROJECT=ubuntu-cpc`) inside a chroot to produce
   `build/ubuntu-26.04-preinstalled-{server,desktop}-arm64.rootfs.tar.xz`.
   For `resolute`/`questing` it adds the apt sources for our apt repo and
   armbian, plus pre-seed stubs to avoid germinate calls (which are unreliable
   for development releases).

4. **Image assembly** — `scripts/config-image.sh`:
   - extracts the rootfs tarball into `build/rootfs/`,
   - mounts dev/proc/sys for chroot operations,
   - imports the apt GPG keys and runs `apt-get update && apt-get -y dist-upgrade`
     (NOTE: `dist-upgrade`, not `upgrade`, otherwise apt holds back any package
     that would require pulling in new dependencies — which is exactly what
     happens when our meta-package adds a new `Depends: cloud-init`),
   - runs the board hook from `config/boards/<board>.sh` (writes the kernel
     command line — for RK1: `console=ttyS9,115200 earlycon=...0xfebc0000 ...`),
   - installs the local kernel and u-boot debs, runs `update-initramfs`,
   - marks `cloud-init`, `udisks2`, `fwupd`, `modemmanager`, `network-manager`
     and `openssh-server` as manually installed so `apt-get autoremove` (next
     line) does not strip them when the kernel meta-package changes,
   - tars the chroot back up to a `*.rootfs.tar`.

   Then `scripts/build-image.sh`:
   - creates a sparse `.img`, sets up a loopdev, partitions GPT
     (server: 4 MiB FAT `CIDATA` + ext4 rootfs; desktop: ext4 rootfs only),
   - extracts the rootfs tar into the rootfs partition, writes `/etc/fstab`,
   - dd's `u-boot-rockchip.bin` to sector 64 (or `idbloader.img` + `u-boot.itb`),
   - runs `chroot u-boot-update`, which generates
     `/boot/extlinux/extlinux.conf` from `/etc/kernel/cmdline` and `/etc/fstab`,
   - compresses to `images/*.img.xz` and writes a `.sha256`.

---

## CI/CD pipeline (zero-touch path)

```diagram
╭──────────────────────────╮      ╭────────────────────────────╮
│ ubuntu-rockchip-settings │      │ linux-rockchip             │
│  push to main triggers   │      │  push to a release tag     │
│  .github/workflows/      │      │  triggers the kernel build │
│   build.yml              │      │  and ingests debs into apt │
╰────────────┬─────────────╯      ╰─────────────┬──────────────╯
             │                                   │
             │ each .deb URL                     │ each .deb URL
             ▼                                   ▼
        ╭─────────────────────────────────────────────╮
        │ ubuntu-rockchip-apt                          │
        │   workflow: ingest.yml                       │
        │     • download deb                           │
        │     • drop into pool/<suite>/main/<x>/<pkg>/ │
        │     • drop into dists/<suite>/main/binary-*  │
        │     • commit + push (path filter triggers …) │
        │   workflow: publish.yml (auto on pool/**)    │
        │     • apt-ftparchive packages → Packages.gz  │
        │     • apt-ftparchive release  → Release      │
        │     • gpg sign Release / InRelease           │
        │     • deploy GitHub Pages                    │
        ╰─────────────────────┬───────────────────────╯
                              │ HTTPS apt source
                              ▼
        ╭─────────────────────────────────────────────╮
        │ ubuntu-rockchip                              │
        │   workflow: release-rk1-resolute.yml         │
        │   (manual: workflow_dispatch)                │
        │     job 1: rootfs (server, desktop matrix)   │
        │       sudo ./build.sh --rootfs-only          │
        │     job 2: build (server, desktop matrix)    │
        │       sudo ./build.sh -b turing-rk1 …        │
        │     uploads .img.xz as release artifact      │
        ╰─────────────────────────────────────────────╯
```

### Triggers

| Action | What you do | What runs |
|---|---|---|
| Bump `ubuntu-rockchip-settings/debian/changelog` and push | git push | `build.yml` → builds debs → creates GitHub release → fans out `ingest.yml` calls in apt repo → `publish.yml` republishes apt repo → GitHub Pages updates |
| Tag a kernel release in `linux-rockchip` | git tag + push | Kernel CI builds debs and ingests into apt repo |
| Build new images | "Run workflow" on `release-rk1-resolute.yml` in GitHub Actions UI | Builds rootfs + image, attaches `.img.xz` to a GitHub release |

### Versioning rule

Every meaningful change to `ubuntu-rockchip-settings` or `linux-rockchip`
must bump the changelog version (e.g. `2.1~resolute` → `2.1.1~resolute`)
because:

* `gh release create` in the workflow no-ops if the tag already exists,
* apt only sees an upgrade if the version is higher,
* image rebuilds will silently pull the previous version otherwise.

---

## Manual local build

The Docker path is recommended because it matches the CI environment exactly
and avoids polluting your host with build deps and chroot mount state.

### One-time

```bash
cd ubuntu-rockchip
docker build -t ubuntu-rockchip-builder .
```

This installs all the build tools listed in the `Dockerfile` into an
`ubuntu:24.04` image.

### Verify the apt repo is up to date

Before each build, confirm the published apt repo has the version you want
the image to install:

```bash
curl -s https://clsx524.github.io/ubuntu-rockchip-apt/dists/resolute/main/binary-arm64/Packages \
  | awk '/^Package: ubuntu-(rockchip-settings|server-rockchip|desktop-rockchip)$/{p=$2} p && /^Version:/{print p, $0; p=""}'
```

If the version printed is older than what you just pushed, wait for the
`publish.yml` workflow in `ubuntu-rockchip-apt` to finish, then continue.

### Wipe stale image build state on the host

What's safe to keep, what to wipe:

| Path | Keep | Notes |
|---|---|---|
| `build/linux-*.deb` | ✅ | Kernel debs, expensive to rebuild |
| `build/u-boot-turing-rk1_*.deb` | ✅ | U-boot deb, expensive to rebuild |
| `build/u-boot-turing-rk3588/` | ✅ | U-boot source tree |
| `build/linux-rockchip/` | ✅ | Kernel source tree |
| `build/ubuntu-26.04-preinstalled-{server,desktop}-arm64.rootfs.tar.xz` | ✅ | Live-build rootfs cache (pulled fresh ~30 min) |
| `build/live-build/chroot/` | ❌ wipe | Stale live-build state |
| `build/rootfs/` | ❌ wipe | Stale config-image chroot |
| `images/*.img.xz` | ❌ wipe | Old broken images (avoid confusion) |
| Stale loop devices on host | ❌ free | `sudo losetup -D` |

```bash
cd ubuntu-rockchip
sudo rm -rf build/rootfs build/live-build/chroot
sudo rm -f images/ubuntu-26.04-preinstalled-*-turing-rk1.img.xz*
sudo losetup -D
```

For a fully clean rebuild add `build/linux-*.deb`, `build/u-boot-*.deb`,
`build/*.rootfs.tar.xz` to the wipe list, or pass `--clean` to `build.sh`
which wipes the whole `build/` directory.

### Run the build

Server:

```bash
docker run --rm -it --privileged \
  -v /dev:/dev \
  -v "$PWD:/work" \
  -w /work \
  ubuntu-rockchip-builder \
  ./build.sh -b turing-rk1 -s resolute -f server
```

Desktop:

```bash
docker run --rm -it --privileged \
  -v /dev:/dev \
  -v "$PWD:/work" \
  -w /work \
  ubuntu-rockchip-builder \
  ./build.sh -b turing-rk1 -s resolute -f desktop
```

Why the docker flags:

* `--privileged` and `-v /dev:/dev` — required for `losetup -P`, `mkfs`,
  `parted`, qemu-binfmt and the chroot mounts used by live-build and
  `config-image.sh`.
* `-v "$PWD:/work"` — the build writes into `build/` and `images/` on the
  host so the artifacts persist after the container exits.

Output ends up at:

```
images/ubuntu-26.04-preinstalled-server-arm64-turing-rk1.img.xz
images/ubuntu-26.04-preinstalled-desktop-arm64-turing-rk1.img.xz
```

### Useful `build.sh` flags

| Flag | Effect |
|---|---|
| `-ko` / `--kernel-only` | Build only the kernel debs |
| `-uo` / `--uboot-only` | Build only the u-boot deb |
| `-ro` / `--rootfs-only` | Build only the live-build rootfs tarball |
| `-c`  / `--clean` | Wipe `build/` first |
| `-l`  / `--launchpad` | Pull u-boot/kernel from Launchpad PPA instead of building |
| `-v`  / `--verbose` | `set -x` |

### Verify the image before flashing

```bash
xz -dc images/ubuntu-26.04-preinstalled-server-arm64-turing-rk1.img.xz \
  | dd bs=512 skip=40960 count=8800000 of=/tmp/r.img status=none

# 1. Meta-package upgraded inside the image?
debugfs -R 'cat /var/lib/dpkg/status' /tmp/r.img 2>/dev/null \
  | awk '/^Package: ubuntu-(rockchip-settings|server-rockchip|desktop-rockchip)$/{p=$2} p && /^Version:/{print p, $0; p=""}'

# 2. Kernel command line correct?
debugfs -R 'cat /boot/extlinux/extlinux.conf' /tmp/r.img | grep append

# 3. NoCloud cloud-init pin file present?
debugfs -R 'ls /etc/cloud/cloud.cfg.d' /tmp/r.img

# 4. cloud-init actually installed?
debugfs -R 'stat /var/lib/dpkg/info/cloud-init.list' /tmp/r.img | head -1

rm /tmp/r.img
```

Expected:

```
ubuntu-rockchip-settings Version: 2.1~resolute
ubuntu-server-rockchip Version: 2.1~resolute
    append root=UUID=... console=ttyS9,115200 earlycon=uart8250,mmio32,0xfebc0000 ...
... 99-rockchip.cfg ...
Inode: <some-number>   Type: regular ...
```

If any of those fails, do not flash — fix the build first.

### Flash and capture serial

From the Turing Pi BMC:

```bash
tpi flash -n <node> -i ubuntu-26.04-preinstalled-server-arm64-turing-rk1.img.xz
tpi power on -n <node>
tpi uart -n <node> get   # repeat to follow the boot log
```

You should see the U-Boot banner → BL31 → kernel boot messages → cloud-init
creating the `ubuntu` user (default password `ubuntu`, forces a change on
first login).

---

## Common pitfalls

* **`apt-get upgrade` vs `dist-upgrade`** — `upgrade` will hold back any
  package whose new version requires installing additional dependencies.
  When `ubuntu-rockchip-settings` adds a new `Depends:` (e.g. `cloud-init`),
  the meta-package upgrade is silently held back. Use `dist-upgrade` (which
  this repo now does in `config-image.sh`).

* **`apt-get autoremove` after kernel install** — after `dpkg -i` of the
  rockchip kernel, packages originally pulled in as deps of the previous
  kernel meta become "auto-installed orphans". Without our `apt-mark manual`
  belt-and-suspenders block, autoremove will strip cloud-init, udisks2,
  modemmanager, fwupd, etc. — yielding a 429-package image with no default
  user instead of a 570-package one.

* **Wrong serial console** — RK1 wires UART9 (`febc0000`) to the BMC serial
  proxy. The kernel must use `console=ttyS9,115200`. If you see U-Boot output
  on `tpi uart get` but no kernel output, you almost certainly have
  `console=ttyS0,...` in `extlinux.conf`.

* **Forgetting to bump the version** — see "Versioning rule" above.

* **Stale loop devices** — if `build-image.sh` fails with
  `Failure to create /dev/loopXp1 in time`, run `sudo losetup -D` and retry.
