# SPDX-License-Identifier: GPL-3.0-or-later
# A throwaway desktop image for the session test (docs/TESTING.md) until the real desktop image
# exists: KDE Plasma from Debian unstable at the snapshot date of nyra-base, without recommends.
# Only what the session needs; the test tools live in tools.Containerfile, never here.
# Besides the packages the test names: fonts-noto-core (Plasma's default font, Noto Sans) and
# libgl1-mesa-dri + libegl-mesa0 (llvmpipe: there is no GPU in CI).
# The base image comes from Amazon ECR Public's copy of Docker Hub's official images (the same index
# digest as docker.io/library/debian:testing-20261005, the base of nyra-base's CI tools): Docker Hub
# limits unauthenticated pulls per runner IP. apt-snapshot.sh moves it to unstable.
FROM public.ecr.aws/docker/library/debian:testing-20261005@sha256:f35963177a0584848d5222b3d2b4f4ebcc6434d39db0a709c3088237ef619cbf
COPY apt-snapshot.sh /tmp/
RUN export DEBIAN_FRONTEND=noninteractive && /tmp/apt-snapshot.sh && \
    apt-get dist-upgrade -y -q && \
    apt-get install -y -q \
      plasma-desktop plasma-workspace kwin-wayland konsole dolphin at-spi2-core dbus-daemon \
      fonts-noto-core libgl1-mesa-dri libegl-mesa0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/apt-snapshot.sh
