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
| The desktop looks as expected | a screenshot of the whole screen through KWin's ScreenShot2, compared with `tests/session/reference.png` |
| Zero crashes | no core dump, no crash caught by KCrash in the session log, plasmashell keeps its process (KCrash would restart it) and the session runs until the end |

### How it runs

- **The desktop container** (`session.sh`, as uid 1000): `dbus-run-session`, then `kwin_wayland
  --virtual` at 1280×800 and `plasmashell`. The session bus listens in `XDG_RUNTIME_DIR`.
  Settings that exist only for the test: `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`,
  `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1`, animations off (`AnimationDurationFactor=0`), a fixed
  number of llvmpipe threads (`LP_NUM_THREADS=2`), `KCRASH_DUMP_ONLY=1` (no crash dialog, a core
  dump instead), `TZ=UTC`, `LANG=C.UTF-8`, the hostname `nyra-test`. The wallpaper is set to a
  solid colour before the screenshot, so a wallpaper that changes with time or theme cannot change it.
- **The test container** (`test_session.py`, Python with pyatspi and Pillow, from
  `tools.Containerfile`) shares only `XDG_RUNTIME_DIR`: the session bus, the AT-SPI bus and the
  Wayland socket. Nothing of the test tools goes into the desktop image.
- Both containers are rootless podman; uid 1000 in both is the user who runs the test.
- **The desktop image is a parameter** (`DESKTOP_IMAGE`). Until the real desktop image of this
  repository exists, `desktop.Containerfile` builds a throwaway one: Debian unstable at the
  snapshot date of nyra-base (`apt-snapshot.sh`), with `plasma-desktop`, `plasma-workspace`,
  `kwin-wayland`, `konsole`, `dolphin`, `at-spi2-core`, a font and Mesa, without recommends. When the
  real image exists, CI passes it instead and `desktop.Containerfile` goes away.

### The screenshot

KWin takes screenshots only when it composites with OpenGL, and on its virtual backend it does that
only with a DRM render device (KWin's own CI loads `vgem`, a virtual GPU memory device without a
display; Mesa then renders with llvmpipe). Without a device in `/dev/dri`, KWin composites in software
and cancels every screenshot, and the screenshot check fails.

**Open point:** the kernel of the GitHub-hosted `ubuntu-24.04` runners (`linux-azure`) has no `vgem`,
not even in `linux-modules-extra`, so in CI the screenshot check fails today. The ways out (building
`vgem` for the runner kernel in the job, or taking the screenshot in the level 2 test, in a VM with the
image's own kernel) are a decision still to be taken.

The comparison leaves out two areas (`MASKS` in `test_session.py`): the panel clock and the
pointer. A pixel counts as different when one of its channels differs by more than 24 (llvmpipe
can round differently on different CPUs); the check fails when more than 0.1% of the compared
pixels differ. The screenshot is taken once the screen stops changing (two captures a second apart
are the same).

Every run uploads the `session` artifact: `screenshot.png`, `diff.png` (the reference dimmed,
differing pixels red, masked areas outlined in blue), `summary.md` and `session.log`. The job summary
shows the table of checks.

**The reference changes only in the pull request that changes the look**: take `screenshot.png`
from that pull request's artifact, check it, and commit it as `tests/session/reference.png` with the
change. Never update it to make an unrelated pull request green.

### Crashes

`kernel.core_pattern` is global to the machine, so the test cannot set it. CI sets it to
`/cores/core.%e.%p`, and `run.sh` mounts `OUT/cores` at `/cores` in the desktop container. Before the
checks, `run.sh` crashes a `sleep` in the session container on purpose and fails unless its core dump
shows up: the core dump check cannot pass by not looking. On a machine with another core pattern
that check fails and says why.

### Running it

```bash
# Rootless podman, a device in /dev/dri you can open, and kernel.core_pattern=/cores/core.%e.%p.
PODMAN_STORE=/var/tmp/session-store tests/session/run.sh /var/tmp/session-out
# Another desktop image:
DESKTOP_IMAGE=oci-archive:/path/to/image.oci.tar tests/session/run.sh /var/tmp/session-out
```

`run.sh` builds the two images when they are missing; their tags are the hash of what they are built
from, so a change to a Containerfile or to `apt-snapshot.sh` rebuilds them. `PODMAN_STORE` keeps them
out of podman's default store.

### Time

On a GitHub-hosted `ubuntu-24.04` runner (x86_64), with the images in the Actions cache: TIME_WARM.
The cache key is the hash of the Containerfiles and `apt-snapshot.sh`; when it changes, the images are
built from snapshot.debian.org first (TIME_COLD) and cached for the next runs. The podman store is on
`/mnt`, which has more free space than `/`.
