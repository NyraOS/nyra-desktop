# SPDX-License-Identifier: GPL-3.0-or-later
# nyra-desktop: KDE Plasma and SDDM as one layer on the pinned nyra-base image (base/pin), with the
# desktop's own sealed UKI (docs/IMAGE.md). ci/build-image.sh runs it: the target "sealed", the UKI
# from that committed image, signed outside the build, then this file again with SEALED=<the
# committed image> and the signed UKI as the build context "uki", as nyra-base does.
#   BASE      the pinned nyra-base image, pulled and verified by ci/build-image.sh (an image ID)
#   SNAPSHOT  the Debian snapshot of that base (its mkosi.conf), which every package comes from
ARG BASE=localhost/nyra-base-pinned
ARG SEALED=sealed
FROM ${BASE} AS base

# The packages, resolved against what the base has and downloaded (image/fetch.sh), in a throwaway
# Debian at the same snapshot: the base itself has no apt. Pinned like the session test's images
# (tests/session/desktop.Containerfile), from Amazon ECR Public's copy of Docker Hub's official images.
FROM public.ecr.aws/docker/library/debian:testing-20261005@sha256:f35963177a0584848d5222b3d2b4f4ebcc6434d39db0a709c3088237ef619cbf AS fetch
ARG SNAPSHOT
RUN --mount=type=bind,from=base,target=/base \
    --mount=type=bind,source=tests/session/apt-snapshot.sh,target=/in/apt-snapshot.sh \
    --mount=type=bind,source=base/manifest.json,target=/in/manifest.json \
    --mount=type=bind,source=image/packages/desktop.list,target=/in/desktop.list \
    --mount=type=bind,source=image/fetch.sh,target=/in/fetch.sh \
    sh /in/fetch.sh "$SNAPSHOT"

FROM base AS sealed
# The base's UKI goes: the final image carries the desktop's, made for this root filesystem.
RUN rm -r /boot/EFI && test -z "$(ls -A /boot)"

# The packages, without network, with dpkg alone (image/install.sh). /var, /tmp and /run are empty
# tmpfs mounts, so the dpkg database and whatever the package scripts leave there stay out of the image,
# as in the base (bootc keeps state in /var; tmpfiles.d makes what the system needs there).
RUN --network=none --mount=type=bind,from=fetch,source=/out,target=/fetch \
    --mount=type=tmpfs,dst=/var --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/run \
    --mount=type=bind,source=image/install.sh,target=/install.sh \
    sh /install.sh

# Our files in /usr: SDDM's settings (the login screen on Wayland, Plasma's theme) and the presets
# that keep the units of image/units.list off at the first boot.
COPY image/files/usr/ /usr/

# Services (docs/IMAGE.md): the unit links the package scripts made in /etc go to /usr or go away, as
# image/units.list says. SDDM, the only service the desktop adds at boot, is then the display
# manager from /usr; graphical.target is already the base's default target.
# tty1 is SDDM's: the console login there (getty@tty1) is masked from /usr. sddm.service conflicts with
# it, as every display manager does, and in the boot transaction the base's nyra-tty-hangup@tty1 (part
# of getty@tty1, docs/IMAGE.md "Login screen") turns that conflict into dropping SDDM's start job.
# The other consoles (Ctrl+Alt+F2 and on) still get their login prompt when a user switches to them.
RUN --mount=type=bind,from=base,target=/base --mount=type=tmpfs,dst=/tmp \
    --mount=type=bind,source=image/units.list,target=/in/units.list \
    --mount=type=bind,source=image/units.sh,target=/in/units.sh \
    sh /in/units.sh && \
    test -f /usr/lib/systemd/system/getty@.service && ! test -e /usr/lib/systemd/system/getty@tty1.service && \
    ln -s /dev/null /usr/lib/systemd/system/getty@tty1.service && \
    test "$(readlink /usr/lib/systemd/system/display-manager.service)" = /usr/lib/systemd/system/sddm.service && \
    test "$(readlink /usr/lib/systemd/system/default.target)" = graphical.target && \
    test -f /usr/share/dbus-1/system-services/org.freedesktop.Accounts.service && \
    test -f /usr/share/wayland-sessions/plasma.desktop && test -f /usr/share/sddm/themes/breeze/metadata.desktop

# DrKonqi's root helper (docs/IMAGE.md, "Services"): its D-Bus service file starts a program as root on
# demand, for any local user who asks the system bus, to write a crash report's data, and crash reports
# are off. Its service file, bus policy, polkit action and program go; rm without -f, so the build also
# fails when a package update moves one of them. (ci/check-added.sh fails if the service comes back.)
RUN rm /usr/share/dbus-1/system-services/org.kde.drkonqi.service /usr/share/dbus-1/system.d/org.kde.drkonqi.conf \
      /usr/share/polkit-1/actions/org.kde.drkonqi.policy /usr/lib/x86_64-linux-gnu/libexec/kf6/drkonqi-polkit-helper

# Accounts (docs/IMAGE.md): a system user or group that a package made must also be in
# /usr/lib/sysusers.d, so systemd-sysusers makes it on a machine whose /etc is older than the image
# (an update keeps the machine's /etc/passwd) or empty (settings reset). SDDM's state directory comes
# from its tmpfiles.d line: /var is empty in the image.
RUN --mount=type=bind,from=base,target=/base \
    for db in passwd group; do \
      for n in $(cut -d: -f1 "/etc/$db"); do \
        grep -q "^$n:" "/base/etc/$db" && continue; \
        grep -Eqs "^[ug][[:space:]]+$n[[:space:]]" /usr/lib/sysusers.d/*.conf || { echo "$db $n: not in sysusers.d"; exit 1; }; \
      done; \
    done && \
    grep -Eq '^d[[:space:]]+/var/lib/sddm[[:space:]]' /usr/lib/tmpfiles.d/sddm.conf

# AppArmor: the base loads the copy in /usr when /etc/apparmor.d is gone, so it must stay the image's
# /etc/apparmor.d, file for file (checked in the last stage): copied again when a package changed it.
RUN diff -rq --no-dereference /etc/apparmor.d /usr/lib/nyra/apparmor.d || \
    { rm -r /usr/lib/nyra/apparmor.d && cp -a /etc/apparmor.d /usr/lib/nyra/apparmor.d; }

# The kernel and initramfs for the desktop's UKI: the base's, from its UKI (image/kernel.py).
FROM sealed AS kernel
RUN --mount=type=bind,from=base,target=/base --mount=type=bind,source=image/kernel.py,target=/kernel.py \
    python3 -I /kernel.py /base/boot/EFI/Linux /usr/lib/modules /kernel

# The final image: the sealed root filesystem plus the signed UKI. bootc installs and updates only
# the UKI, never a kernel and initramfs of its own.
FROM ${SEALED}
COPY --from=uki . /boot/EFI/Linux/
RUN diff -r --no-dereference /etc/apparmor.d /usr/lib/nyra/apparmor.d && bootc container lint --fatal-warnings
