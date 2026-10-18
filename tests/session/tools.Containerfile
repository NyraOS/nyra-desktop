# SPDX-License-Identifier: GPL-3.0-or-later
# The test tools of the session test (docs/TESTING.md): Python with pyatspi (AT-SPI over D-Bus) and
# Pillow (screenshot comparison). A separate image: nothing of it goes into the desktop image.
# Same base image and Debian snapshot as desktop.Containerfile.
FROM public.ecr.aws/docker/library/debian:testing-20261005@sha256:f35963177a0584848d5222b3d2b4f4ebcc6434d39db0a709c3088237ef619cbf
COPY apt-snapshot.sh /tmp/
RUN export DEBIAN_FRONTEND=noninteractive && /tmp/apt-snapshot.sh && \
    apt-get dist-upgrade -y -q && \
    apt-get install -y -q python3-pyatspi python3-pil && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/apt-snapshot.sh
