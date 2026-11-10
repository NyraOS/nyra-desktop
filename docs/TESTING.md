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
| The boot screen shows | the test's add-on adds `splash plymouth.ignore-serial-consoles` to the command line (see "The boot screen" below); a screenshot, `boot-screen.png`, is taken by the first command (SDDM's start is held until then), and `tests/vm/screen-splash.py` fails the job unless the screen is the theme's dark background with the logo's white planet and the accent-coloured moon in the middle |
| The boot stays lean | the login screen's first window comes within 240 s of the kernel start (the time and `systemd-analyze blame` are printed), fewer than 250 units are active, the user `sddm` runs no PipeWire or WirePlumber, and no NetworkManager, ModemManager, Bluetooth or Avahi unit is loaded (`docs/IMAGE.md`, "Boot time") |
| A Plasma session starts | a test user (`nyratest`), logged in by SDDM's autologin, set for the test only in `/etc/sddm.conf.d`: a logind session of type `wayland`, active, with `plasmashell` and `kwin_wayland` |
| It stays up | the same `plasmashell` process and KWin after 90 s; a screenshot, `plasma-session.png` (with llvmpipe the first panel takes about a minute) |
| No crash | no KCrash, core dump or segfault in the journal |
| An SD card is mounted by itself | the VM has an SD card (a FAT image, label `NYRASD`) on an SDHCI controller; with Plasma's device automounter on for the test user, it is mounted at `/run/media/nyratest/NYRASD` (udisks2) with `noexec`, `nosuid` and `nodev` (the base's udev rule `90-nyra-udisks.rules` sets them; the test fails without them) and the user can write to it |
| A page printed arrives | cups makes a driverless (IPP Everywhere) queue for a virtual printer, `ippeveprinter` on the host, which the guest reaches at `10.0.2.2`; `lp` prints a text page, cups' filters make a raster of it, and the host finds the job's file; the queue shows the job as completed; cupsd listens on the local socket only (no TCP or UDP port 631) |
| Sound plays and records | the VM has an HDA sound card; PipeWire in the user's session has an `alsa_output` and an `alsa_input` node, `pw-play` plays a two-second tone while `pw-record` records the sink's monitor, and the recording must have a peak above -40 dB (silence fails); `pw-record` also records three seconds from the source |
| An H.264 video decodes | `ffmpeg` decodes the clip on the SD card (`tests/vm/fixtures/h264.mp4`, 10 frames of 128x96, High profile) with its native `h264` decoder; the SHA-256 of the raw frames is the one in `plasma.sh` |
| Languages are in the image | `tests/vm/fixtures/languages.sh`, run in the VM from the SD card: for English, Romanian, Japanese and Arabic, a UTF-8 locale whose weekday for 2 November 2026 is spelled as the language does (glibc's data, not a name in a list), the translation of a KDE application (Konsole's catalog) and of the login screen (SDDM), and a font with a letter of the script (U+0219, U+65E5, U+0639); a font for Hebrew, Devanagari, Bengali, Tamil, Thai, Hangul, Simplified Chinese, Greek and Cyrillic; a locale for each of twelve more languages; at least 300 UTF-8 locales in all; no `fcitx5` running. Any missing piece fails the test and names the language |
| Settings may change the language and the layout | `tests/vm/fixtures/languages.sh`: `pkttyagent` is given the password of two new users while `pkcheck -u` runs; a member of `sudo` is let through for `org.freedesktop.locale1.set-locale` and `set-keyboard`, a user who is not a member is refused, and `org.freedesktop.timedate1.set-timezone` still asks for root (the rule `48-nyra-desktop-locale.rules` names only the first two) |
| The login screen and the session follow the language | `tests/vm/fixtures/language-session.sh`, for Japanese (`jp`) and Arabic (`ara`, right to left): the script writes the files `localectl` would write (`/etc/locale.conf`, `/etc/vconsole.conf`, the X keyboard layout), as the installer does, because root on the serial console is no local session for polkit, and `localectl status` reads them back; SDDM restarts, and its greeter, then the Plasma session of the test user, must run with that `LANG`; a screenshot of each (`login-screen-ja.png`, `plasma-session-ja.png`, `login-screen-ar.png`, `plasma-session-ar.png`) |

### The boot screen

The splash is photographed with QMP's `screendump` (as the login screen is). Once plymouth shows its screen the
serial console prints nothing more, so no console line says when to photograph, and when plymouth quits it
lets go of the display, which goes blank in the VM. So the test passes `plymouth-quit.service` a drop-in as a
credential (test only): it prints a marker line to the serial port (plymouth redirects `/dev/console`), which triggers the screendump, then waits
4 s. What is photographed is plymouth's animated screen. A boot where plymouth showed text instead, crashed, or never started
leaves a screen that has no logo, and `screen-splash.py` fails. The shares it checks are of the screen's
shorter side, as the theme's are, so the VM's resolution does not matter.

The command line of the desktop image has no `splash` (nyra-base's change), without which plymouth does
not show its theme, and a serial console (which the test needs) makes plymouth fall back to its text theme.
The test's add-on, never the image, adds `splash plymouth.ignore-serial-consoles`. When nyra-base's
change is in, `splash` is no longer test only.

**The H.264 clip** (`tests/vm/fixtures/h264.mp4`, 3 KB) is our own: generated for this test, test only, never shipped (the
Containerfile copies only `image/files/usr`). The command, run with Debian testing's `ffmpeg` (libx264):

```bash
ffmpeg -v error -y -f lavfi -i testsrc=size=128x96:rate=10:duration=1 -c:v libx264 -profile:v high \
  -pix_fmt yuv420p -preset veryslow -crf 28 -bf 2 -g 10 -an -movflags +faststart h264.mp4
```

The hash in `plasma.sh` is the SHA-256 of its decoded frames (`ffmpeg -i h264.mp4 -map 0:v -c:v rawvideo
-pix_fmt yuv420p -f hash -hash sha256 -`); a new clip needs a new hash.

**What these four do not prove.** The sound card has no host backend (`-audiodev none`): the test shows
that PipeWire makes a sink and a source of it and that streams run, and that what is played reaches the
sink (its monitor hears the tone), not that sound comes out of a real card; the source's own recording is
silence, so only its size is checked. Video is decoded in software: hardware decoding (VA-API) needs a
GPU, which a CI VM does not have. SD cards on other controllers (Realtek card readers), exFAT and NTFS
cards, and a real printer or a driver the printer needs are not covered either. The printer's job is
checked by the file the virtual printer keeps, not by the paper. The test-only settings (the
automounter's file in the test user's home, the SD card, the printer queue) are made in the VM at run
time; the image has none.

The memory of SDDM and of its login screen and the services running at the login screen are printed in
the job summary. The screenshots and the serial log are the `desktop-boot` artifact. The login screen
is checked by its processes, not by its screenshot, and not by typing a password into it.

Running it on a machine with KVM, root and nyra-base checked out at the pinned commit (the build job's
`ci/build-image.sh` gives the image and `WORK/uki.crt`):

```bash
# also needs cups-ipp-utils, avahi-daemon (ippeveprinter registers with it) and dosfstools
tests/vm/plasma.sh ../nyra-base localhost/nyra-desktop:ci /var/tmp/build/uki.crt /var/tmp/vm /var/tmp/vm/logs /var/tmp/vm/summary.md
```

### Level 2 on aarch64

`tests/vm/plasma-arm64.sh`, the `boot-arm64` job of `.github/workflows/image.yml`, does the same on the
arm64 image (`docs/IMAGE.md`, "arm64"): nyra-base's VM tools install it to a disk and boot it in QEMU's
`virt` machine with edk2 (AAVMF), with Secure Boot: Debian's arm64 shim, then systemd-boot, then the
desktop's UKI, signed with the run's key and enrolled as a MOK. GitHub's arm64 runners have no KVM (October
2026), so the CPU is emulated (TCG, `vm-boot.py` picks it by itself), and the VM has 2 vCPUs and 2 GiB, as
on x86_64.

It checks Secure Boot, the sealed command line, a running system with no failed unit, the login screen by
its processes (the greeter and KWin as `sddm`), a Plasma session of the test user that stays up and no
crash, as in the table above. It also checks that its screenshots show UI: the greeter and the desktop, not
only the wallpaper (see below). It does not run the SD card, printing, sound and video tests: they would
add little to what the x86_64 test proves of the packages (the same package versions, the same
configuration) and a long wait each under emulation.

Emulated, the desktop takes minutes to start. `vm-boot.py` lets every guest command run for 300 s at most,
so a wait for the greeter or the session is a series of polls of 210 s (up to 10 of each; 2 with KVM) that
never fail, followed by the command that must succeed.

The screenshots do not wait for a quiet CPU: the emulated greeter and desktop keep both vCPUs busy for as
long as the test looks (see "The CPU use under emulation"), so there is no quiet moment to wait for.
Instead each screen is woken with QMP input events (a key press and release, a move of the `usb-tablet`;
emulated, the greeter showed only the wallpaper and a locked session only the lock screen without input) and photographed every 30 s, ten times
(`login-1.png` to `login-10.png`, `session-1.png` to `session-10.png`), with the CPU seconds of each 30 s
in the log. `tests/vm/screen-ui.py` counts the sharp colour edges in the bottom 7 % of each photograph
(the greeter's labels and Plasma's panel are there; the wallpaper and the lock screen's clock are not,
and the wallpaper's own edges are soft: 0 against about 1200 for the greeter and 800 for the panel),
copies the first photograph with at least 300 of them to `login-screen.png` (`plasma-session.png`), and
fails the job when none has, so a screen that stays on the wallpaper or the lock screen fails with
the list of photographs checked. The test user's screen never locks by idling
(`Autolock=false` in `kscreenlockerrc`), which would cover the desktop.

#### The CPU use under emulation

Emulated (TCG), the greeter and the desktop use both vCPUs for as long as anyone looked: in CI the greeter
used 40 to 60 s of CPU per 30 s, the desktop (`plasmashell` and KWin) the same, also with no input. The
log of the test lists the busiest threads of each 30 s. The cause is software rendering, not a loop in the
greeter: the CPU is in the `llvmpipe-0` and `llvmpipe-1` threads (Mesa's software rasteriser, which Qt
Quick and KWin use because the VM has no GPU) of `sddm-greeter-qt6` (about 22 s each per 30 s) and of
`kwin_wayland` (about 7 s each), while the greeter's own threads (`QSGRenderThread`, the main thread) are
nearly idle. The greeter draws a blurred full-screen wallpaper; what makes it repaint all the time (the clock and the
blinking cursor are the likely ones) was not isolated, but each repaint is rasterised on the CPU.

No x86_64 comparison under TCG was possible: on a CPU-only host, the x86_64 guest under emulation never
reached a login prompt in 40 minutes. The comparison below is therefore arm64 under TCG against x86_64 under
KVM, and the "about 15 times cheaper" figure mixes emulation and KVM speed. The x86_64 numbers come from a
one-off local run that used the same per-thread log, not from CI artifacts. Under KVM the same threads run
in the same proportions: the idle greeter used 2 to 7 s of CPU per 30 s in all (1 to 2 s in each `llvmpipe`
thread), and the desktop none after its first half minute. So the arm64 image does the same as the x86_64
image; emulation cannot keep up with the rasteriser. Nothing in the image is changed for this, and the test
sets no rendering option: the screenshots are taken of the rendering users get, and the test needs no quiet
CPU.

#### The login screen's journal, and the greeter that sometimes does not start

Both boot jobs keep the journal of the login screen's parts (SDDM, its helper, the greeter, KWin, plymouth,
logind and PAM; the last 600 lines) as `guest-journal.log` in the `desktop-boot` and `desktop-boot-arm64`
artifacts. The test console prints it after the wait for the greeter and again at the end (the commands run
whether or not the ones before them passed, so a failed run has it), and `tests/vm/extract-journal.sh`
copies it out of the serial log. The last line of each dump counts SDDM's `Auth: sddm-helper exited with` lines among the lines above it (the 255 ones included).

What the lines mean:

- `sddm-helper exited with 255`, with `Greeter stopped. HelperExitStatus(255)`: the greeter was stopped by a
  signal. The test does that itself each time it restarts `sddm.service` (the autologin, and on x86_64 the
  two language checks): once in the arm64 run, four times in the x86_64 run. It is not a failure.
- `sddm-helper exited with 2` (`HELPER_SESSION_ERROR`): SDDM's helper could not start the greeter's session.
  Here the journal shows `Wayland socket watcher timed out` 15 s after `Starting Wayland process
  "kwin_wayland ..."`: SDDM waits 15 s for KWin's socket (the time is fixed in SDDM, not a setting) and
  gives up, while KWin, still starting, opened `wayland-0` 1 s later. The next start of the greeter then
  finds that socket, but KWin was stopped, so the greeter gets `Connection refused`, ends, and SDDM does not
  start it again: the greeter never shows.

Measured on the arm64 job (emulated, GitHub's runners), 5 runs of each pin: the time from KWin's start to its
socket was 10.0 to 16.6 s with the 2026.11.764 base (13.3 on average) and 10.6 to 14.1 s with the base
before it (11.5 on average). One run in five on the new pin ended in `exited with 2` and a greeter that
never started; none of the five on the old pin did. The x86_64 job, under KVM, has KWin's socket 0.4 s after
its start on both pins. So the failure is a race between SDDM's 15 s and an emulated KWin; a base that is
about 2 s slower to start KWin under emulation (from 5 runs each, which is not enough to tell the kernel from
the other changed packages) makes it likelier. It needs a start more than 15 s slow to happen: on a machine
with a GPU or under KVM, KWin takes well under a second, so real hardware and x86_64 are not at risk unless
the machine is badly overloaded at the first start. Nothing in the image is changed for it; a red arm64 boot
job with `Wayland socket watcher timed out` in its journal is this race and is run again.

Is it the DRM device? The hypothesis was that KWin starts before the GPU's device nodes exist, and it is
not so. The journal dump now also holds the kernel's `drm` lines and the times of `/dev/dri`'s nodes. On
arm64 (emulated) `virtio_gpu` was initialised, with `card0` and `renderD128` created, 28.7 s after the
kernel started, and KWin started 208.8 s in: 180 s later. On x86_64 (KVM) it was 3.9 s against 16.3 s.
KWin's `kwin_core: Failed to open drm node` line, which looks like the cause in a failed run, is also in
every passing run, at the same place (just before the socket opens): it is KWin's look for a render node
of its software renderer (llvmpipe has none), not the GPU. Also, `dev-dri-card0.device` is never active
in the guest (`ActiveEnterTimestampMonotonic=0`), so a `Wants=` and `After=` on it would order nothing.
Waiting for the DRM device before SDDM would therefore change nothing, and the image is not changed.
What is left is the race itself: KWin needs 10 to 17 s to open its socket on a guest whose CPUs the
rest of the boot still keeps busy, against SDDM's fixed 15 s.

The limits are bounded: the guest's boot to its login prompt 1800 s, the job 120 minutes. The artifact is
`desktop-boot-arm64` (the screenshots, the serial log). Running it needs an arm64 machine (or the same
steps on another one with QEMU's `qemu-system-aarch64` and AAVMF), root and nyra-base at the commit of
`base/pin-arm64`:

```bash
tests/vm/plasma-arm64.sh ../nyra-base localhost/nyra-desktop:ci /var/tmp/build/uki.crt /var/tmp/vm /var/tmp/vm/logs /var/tmp/vm/summary.md
```
