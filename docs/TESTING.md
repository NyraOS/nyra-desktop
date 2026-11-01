# Testing the desktop

## Level 1: the session test (every pull request, no VM)

`tests/session/` starts a KDE Plasma session in a container and checks it from another container,
over the session's own buses. It needs no VM and no KVM, so it runs on every pull request and on
every push to `main` (`.github/workflows/session.yml`).

**Not a required check yet.** It becomes one after 20 consecutive green runs on `main` and on pull
requests; until then a red run is looked at, not ignored, and a flaky one is a bug to fix.

### What it checks

| Check | How |
|---|---|
| The panel exists | AT-SPI: plasmashell shows the *Application Launcher* and *Digital Clock* buttons |
| The application launcher opens and lists Konsole and Dolphin | AT-SPI: *Press* on the launcher, then on *All Applications*; both entries are showing |
| Konsole started from the launcher shows a window | AT-SPI: *Press* on the Konsole entry; a `konsole` application with a showing frame appears |
| The desktop looks as expected | a screenshot of the whole screen through KWin's ScreenShot2, compared with `tests/session/reference.png`; the same comparison must fail on the reference with a panel icon painted over |
| Zero crashes | no core dump, no crash caught by KCrash in the session log, plasmashell keeps its process (KCrash would restart it) and the session runs until the end |
| The checks themselves ran | `test_session.py` finished without an error; an exception shows as a failed row with its message |

### How it runs

- **The desktop container** (`session.sh`, as uid 1000): `dbus-run-session`, then `kwin_wayland
  --virtual` at 1280×800 (in CI, `--drm` on vkms: see "The screenshot") and `plasmashell`. The session bus listens in `XDG_RUNTIME_DIR`.
  Settings that exist only for the test: `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`,
  `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1`, animations off (`AnimationDurationFactor=0`), a fixed
  number of llvmpipe threads (`LP_NUM_THREADS=2`), `KCRASH_DUMP_ONLY=1` (no crash dialog, a core
  dump instead), `TZ=UTC`, `LANG=C.UTF-8`, the hostname `nyra-test`. The wallpaper is set to a
  solid colour before the screenshot, so a wallpaper that changes with time or theme cannot change it.
- **The test container** (`test_session.py`, Python with pyatspi and Pillow, from
  `tools.Containerfile`) shares only `XDG_RUNTIME_DIR`: the session bus, the AT-SPI bus and the
  Wayland socket. Nothing of the test tools goes into the desktop image.
- Both containers are rootless podman; uid 1000 in both is the user who runs the test. The desktop
  container gets `CAP_SYS_NICE` in its bounding set: `kwin_wayland` carries that file capability,
  and the kernel refuses to run a file whose capabilities it cannot grant.
- **The desktop image is a parameter** (`DESKTOP_IMAGE`). The session test still runs on a throwaway
  one, which `desktop.Containerfile` builds (moving it to the real image, `docs/IMAGE.md`, is a change
  of its own): Debian unstable at the
  snapshot date of nyra-base (`apt-snapshot.sh`), with `plasma-desktop`, `plasma-workspace`,
  `kwin-wayland`, `konsole`, `dolphin`, `at-spi2-core`, a font and Mesa, without recommends. When the
  real image exists, CI passes it instead and `desktop.Containerfile` goes away. (A bootc image has
  an empty `/var`; whether the session needs anything there is to be checked then.)

### The screenshot

KWin takes screenshots only when it composites with OpenGL (llvmpipe here), and that needs a DRM
device. Its virtual backend takes only a render node or `vgem` (as in KWin's own CI), and the kernel
of the GitHub-hosted `ubuntu-24.04` runners (`linux-azure`) has neither: no `vgem`, and its only DRM
device, `hyperv_drm`, has no render node. Without a device, KWin composites in software and cancels
every screenshot.

**So CI runs KWin on its DRM backend instead of the virtual one (`kwin_wayland --drm`).** The job
installs the kernel's own signed `linux-modules-extra` and loads `vkms`, a virtual display; `run.sh`
gets its node in `SESSION_DRM_DEVICE` and `session.sh` starts KWin on it, with no logind (KWin opens
the device itself), software GBM, `KWIN_COMPOSE=O2` (KWin does not pick OpenGL for a software renderer
on its own) and a custom 1280×800 mode in `kwinoutputconfig.json` (vkms prefers 1024×768). Everything
else in the session is the same. Without `SESSION_DRM_DEVICE`, `session.sh` uses `--virtual`, which
also takes screenshots on a machine with a render node.

The comparison leaves out two areas (`MASKS` in `test_session.py`): the pointer, and the panel clock
together with the tray's "Show hidden icons" arrow to its left. The date in the clock is `d MM yyyy`,
7 px narrower on days 1 to 9, which narrows the clock and moves the arrow by 8 px; both positions are
inside the mask. A pixel counts as different when one of its channels differs by more than 24
(llvmpipe can round differently on different CPUs), and the check fails when more than 40 pixels
differ: runners have differed by 0 so far, a missing panel icon is several hundred. To keep that
threshold honest, the same comparison runs on the reference with the Dolphin panel icon painted over,
and must fail. The screenshot is taken once the desktop shows the test's wallpaper and two captures a
second apart are the same.

Every run uploads the `session` artifact: `screenshot.png`, `diff.png` (the reference dimmed,
differing pixels red, masked areas outlined in blue), `summary.md`, `session.log` and the output
configuration KWin ended up with (`home/.config/kwinoutputconfig.json`). The job summary
shows the table of checks.

**The reference changes only in the pull request that changes the look**: take `screenshot.png`
from that pull request's artifact, check it, and commit it as `tests/session/reference.png` with the
change. The reviewer compares the old and the new `reference.png` in the pull request's file view
(GitHub shows the two images side by side). Never update it to make an unrelated pull request green.
A change that moves the panel icons also moves `PANEL_ICON` and `PANEL_POINT` in `test_session.py`.

### Crashes

`kernel.core_pattern` is global to the machine, so the test cannot set it. CI sets it to
`/cores/core.%e.%p`, and `run.sh` mounts `OUT/cores` at `/cores` in the desktop container. Before the
checks, `run.sh` crashes a `sleep` in the session container on purpose and fails unless its core dump
shows up: the core dump check cannot pass by not looking. On a machine with another core pattern
that check fails and says why.

### Running it

```bash
# Rootless podman, a DRM device you can open (a render node, or a KMS device such as vkms in
# SESSION_DRM_DEVICE) and kernel.core_pattern=/cores/core.%e.%p.
PODMAN_STORE=/var/tmp/session-store tests/session/run.sh /var/tmp/session-out
# Another desktop image:
DESKTOP_IMAGE=oci-archive:/path/to/image.oci.tar tests/session/run.sh /var/tmp/session-out
```

`run.sh` builds the two images when they are missing; their tags are the hash of what they are built
from, so a change to a Containerfile or to `apt-snapshot.sh` rebuilds them. `PODMAN_STORE` keeps them
out of podman's default store.

### Time

Measured on GitHub-hosted `ubuntu-24.04` runners (x86_64): with the images in the Actions cache,
about 1.5 minutes for the whole job (90 to 102 s: installing `linux-modules-extra` about 30 s,
restoring the 650 MB cache and loading the images about 30 s, the test about 30 s). The cache key is
the hash of the Containerfiles and `apt-snapshot.sh`; when it changes or the cache is gone, the
images are built from snapshot.debian.org first, which took 9 to 12.5 minutes for the whole job
(the desktop packages alone 8 to 11 minutes, depending on the mirror's speed). **A cache miss can
therefore take the job past 10 minutes**; the next runs use the cache. The podman store is on `/mnt`,
the larger disk on some runner images.

## Level 2: the image boots (every pull request, in a VM)

`tests/vm/plasma.sh`, the `boot` job of `.github/workflows/image.yml`, installs the image that the
`build` job made (`docs/IMAGE.md`) to a disk with `bootc install to-disk`, as nyra-base's own tests do,
and boots it in QEMU with KVM, UEFI and Secure Boot: shim, then systemd-boot, then the desktop's UKI,
signed with the run's key, which the test enrolls as a MOK. It uses nyra-base's VM tools from the
checkout of the pinned base (`tools/vm/install-disk.sh`, `test-addon.sh`, `vm-boot.py`): a test console
on the serial port (a root shell from systemd credentials, through an add-on signed with a second key
of the run), commands run there, the serial log saved. The VM has a virtio GPU, a USB keyboard and
tablet, 2 vCPUs and 2 GiB.

| Check | How |
|---|---|
| Secure Boot is on | `mokutil --sb-state`, and the sealed command line with the composefs digest |
| The system is up | `systemctl is-system-running --wait` is `running`, no failed unit |
| The login screen shows | `sddm.service` active, its greeter and KWin running as the user `sddm`; a screenshot, `login-screen.png` |
| A Plasma session starts | a test user (`nyratest`), logged in by SDDM's autologin, set for the test only in `/etc/sddm.conf.d`: a logind session of type `wayland`, active, with `plasmashell` and `kwin_wayland` |
| It stays up | the same `plasmashell` process and KWin after 90 s; a screenshot, `plasma-session.png` (with llvmpipe the first panel takes about a minute) |
| No crash | no KCrash, core dump or segfault in the journal |
| An SD card is mounted by itself | the VM has an SD card (a FAT image, label `NYRASD`) on an SDHCI controller; with Plasma's device automounter on for the test user, it is mounted at `/run/media/nyratest/NYRASD` (udisks2) and the user can write to it |
| A page printed arrives | cups makes a driverless (IPP Everywhere) queue for a virtual printer, `ippeveprinter` on the host, which the guest reaches at `10.0.2.2`; `lp` prints a text page, cups' filters make a raster of it, and the host finds the job's file; the queue shows the job as completed |
| Sound plays and records | the VM has an HDA sound card; PipeWire in the user's session has an `alsa_output` and an `alsa_input` node, `pw-play` plays a two-second tone and `pw-record` records three seconds |
| An H.264 video decodes | `ffmpeg` decodes the clip on the SD card (`tests/vm/fixtures/h264.mp4`, 10 frames of 128x96, High profile) with its native `h264` decoder; the SHA-256 of the raw frames is the one in `plasma.sh` |

**What these four do not prove.** The sound card has no host backend (`-audiodev none`): the test shows
that PipeWire makes a sink and a source of it and that streams run, not that sound comes out of a real
card, and the recording is silence. Video is decoded in software: hardware decoding (VA-API) needs a
GPU, which a CI VM does not have. SD cards on other controllers (Realtek card readers), exFAT and NTFS
cards, and a real printer or a driver the printer needs are not covered either. The printer's job is
checked by the file the virtual printer keeps, not by the paper. The test-only settings (the
automounter's file in the test user's home, the SD card, the printer queue) are made in the VM at run
time; the image has none.

The memory of SDDM and of its login screen and the services running at the login screen are printed in
the job summary. The screenshots and the serial log are the `desktop-boot` artifact. The login screen
is checked by its processes and its screenshot, not by typing a password into it.

Running it on a machine with KVM, root and nyra-base checked out at the pinned commit (the build job's
`ci/build-image.sh` gives the image and `WORK/uki.crt`):

```bash
# also needs cups-ipp-utils, avahi-daemon (ippeveprinter registers with it) and dosfstools
tests/vm/plasma.sh ../nyra-base localhost/nyra-desktop:ci /var/tmp/build/uki.crt /var/tmp/vm /var/tmp/vm/logs /var/tmp/vm/summary.md
```
