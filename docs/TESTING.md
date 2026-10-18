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
- **The desktop image is a parameter** (`DESKTOP_IMAGE`). Until the real desktop image of this
  repository exists, `desktop.Containerfile` builds a throwaway one: Debian unstable at the
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
