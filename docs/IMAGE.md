# The desktop image

The desktop image is the pinned [nyra-base](https://github.com/NyraOS/nyra-base) image plus one layer:
a minimal KDE Plasma session and SDDM, installed from the same Debian snapshot as the base, with the
desktop's own sealed UKI. Nothing is compiled, and nothing is installed on the user's machine: the
image is the product. CI builds it on every pull request and push to `main`
(`.github/workflows/image.yml`) and boots it (`docs/TESTING.md`, "Level 2").

This first step signs the UKI only with keys made for the CI run. Release signing, publishing and
everything else of a desktop release are later steps.

## The pinned base

`base/pin` names the base: exactly the four lines of nyra-base's release file (`version=`, `digest=`,
`commit=`, `architecture=amd64`). `base/manifest.json` is that build's package list (the
`nyra-base.manifest.json` of its `nyra-base-sbom` artifact), which the base image does not carry: mkosi
removes the dpkg database.

`ci/pull-base.sh` pulls it with nyra-base's own `tools/install/verified-pull.sh`, from a checkout of
the pinned commit (the installer's verified pull): the image must carry nyra-base's keyless release
signature under the signature policy and trust roots of that commit, have the pinned manifest digest,
and have the pinned version and commit in its labels. It must also have been built at that commit's
`Snapshot=` (its creation time), the snapshot the desktop's packages come from. The same checkout
provides the UKI and signing scripts, the VM test tools and the SBOM scanner, so the desktop always
uses the tools of the base it is built on.

**Moving to a newer base** is a pull request that changes both files: the four lines from the
release run of nyra-base (the version is `year.month.run`, the digest is in the run's summary and
`verify-published` job), and the manifest from the same run's `nyra-base-sbom` artifact
(`gh run download <run> -R NyraOS/nyra-base -n nyra-base-sbom`). A manifest from another build fails
the build (see "Packages").

## Packages

`image/packages/desktop.list` lists the packages the desktop adds, each with the reason it is there.
The build (`Containerfile`) installs them in two steps, since the base has no apt:

`ci/check-package-reasons.sh` fails the build job on a package without a reason, or listed twice.

1. **fetch** (`image/fetch.sh`), in a throwaway Debian container at the base's snapshot: a dpkg status
   file that lists the base's packages as installed (their records from the snapshot's index), then apt
   resolves the list against it without recommends and downloads what is missing; apt checks every
   package against the snapshot's signed index. The build fails if apt would remove or change a base
   package, or if a new package would write a file the base already has: dpkg cannot see the base's
   files, so it would silently replace them (the base's own zlib or `su`, for example). A wrong
   `base/manifest.json` shows up here: a base package missing from it is fetched again and clashes.
2. **install** (`image/install.sh`), in the stage `FROM` the base, without network: Debian's dpkg (which
   the base keeps at `/usr/lib/nyra/dpkg`) unpacks and configures the packages in apt's order. `/var`
   is a tmpfs during this step, so the dpkg database and whatever package scripts leave in `/var` stay
   out of the image, as in the base.

Debian's `sudo` comes only as a dependency of KDE's kdesu library; its files are removed, as the base
removes sudo-rs's: the base has no sudo on purpose, and polkit is the one way to approve an action.
`sddm` depends on an X server, so Xorg is in the image, unused: the login screen runs on Wayland.

## Services

Every service the desktop adds starts on demand, or is listed here with its cost:

| Service | Starts | Cost, measured in the VM test |
|---|---|---|
| `sddm.service` (display manager) | at boot, in `graphical.target` | the daemon about 9 MB; the login screen (KWin and the greeter, as the user `sddm`) about 650 MB with software rendering (llvmpipe; cgroup memory, page cache included), in the job summary of every run |
| `accounts-daemon.service` | through D-Bus, when a program asks (the user list on the login screen) | only while used |
| `cups.socket`, `cups.path` (printing) | the socket at boot, `cups.service` itself on the first connection or queued job | the socket and a path watcher only; the daemon while printing |
| `pipewire.service`, `wireplumber.service`, `pipewire-pulse.service` (sound) | in every user session, from `default.target` | per logged-in user; their memory is in the job summary, in the process list of the session |
| `udisks2.service` | through D-Bus, when a program asks (Plasma's device notifier, the automounter) | only while used |

Debian's package scripts enable units through `/etc/systemd`, where the image configures nothing (`/etc`
is the user's and kept across updates). `image/units.list` names every link they make and what happens
to it: moved to `/usr/lib/systemd` (SDDM as `display-manager.service`, the Plasma session's user units)
or removed, with our presets (`/usr/lib/systemd/*-preset/80-nyra-desktop.preset`) disabling the unit so
that the first boot does not enable it again. Off: accounts-daemon at boot, and DrKonqi's crash report
units (they need systemd-coredump, which the base does not have, and they send reports to KDE, which
needs a decision first). The build fails on a link the list does not name.

## Login screen

SDDM's settings are `/usr/lib/sddm/sddm.conf.d/10-nyra.conf`: the login screen on KWin (Wayland, no X
server) and Plasma's Breeze theme. Settings in `/etc/sddm.conf.d` still win.

tty1 is SDDM's: `getty@tty1.service` is masked from `/usr`. `sddm.service` conflicts with it, as every
display manager's unit does, and the base's `nyra-tty-hangup@tty1.service` (part of `getty@tty1`, so
that a shutdown hangs the console up first) turns that conflict into dropping SDDM's start job from the
boot transaction: without the mask SDDM does not start at boot. The other consoles still get a login
prompt when a user switches to them.

## UKI

`ci/build-image.sh` makes the desktop's UKI the way nyra-base makes its own on a pull request, with
nyra-base's scripts from the pinned commit:

- the kernel and initramfs are the base's, taken from its UKI (`image/kernel.py`): the desktop
  changes neither, and the base keeps them nowhere else;
- `ci/ukify.sh` builds the UKI from the committed desktop root filesystem, so its command line pins the
  desktop's composefs digest, with the base's recovery and reset profiles and SBAT lines;
- the PCR 11 policy and the Secure Boot signature come from two keys made for the run and deleted
  right after signing (`pcr-policy.py`, `sign-uki.sh`, after `uki-check.py`); only the certificate
  and the policy's public key stay, for the VM test.

The base's UKI is removed from the layer, so the image has exactly one, and the last stage runs `bootc
container lint --fatal-warnings`.

## Checks

Besides the steps above, the build fails when:

- a package added a setuid, setgid or capability file that `image/privileged.txt` does not list
  (`ci/check-privileged.sh`; today only `kwin_wayland`, `cap_sys_nice`);
- a user or group a package made is not in `/usr/lib/sysusers.d` (an updated machine keeps its
  `/etc/passwd`, so systemd-sysusers must make it);
- the copy of the AppArmor profiles in `/usr` is not the image's `/etc/apparmor.d`;
- the image has an SSH host key in any layer (nyra-base's `ci/no-host-keys.py`).

## SBOM

`ci/sbom.sh` writes the image's SBOM (CycloneDX 1.6) and vulnerability report with nyra-base's scanner
(`tools/sbom/sbom.py` of the pinned commit), for the whole image: the base's packages and the
desktop's, and the crates of the base's Rust programs. The exceptions are the desktop's own
(`sbom/mitigations.toml`, empty for now): the base's rest on the base's configuration, which a desktop
changes. The scan is in report mode, as in the base's builds; it is the last step of the build job, and
the SBOM, the report and the package list are the `nyra-desktop-sbom` artifact.
