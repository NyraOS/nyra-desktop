#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The kernel and initramfs of the desktop's UKI, taken from the pinned base's UKI (docs/IMAGE.md).

usage: kernel.py BASE_UKI_DIR MODULES_DIR OUT
  BASE_UKI_DIR  the base image's /boot/EFI/Linux, which holds its one UKI, <kernel version>.efi
  MODULES_DIR   the image's /usr/lib/modules, which must have exactly that kernel version
  OUT           gets <kernel version>/vmlinuz and <kernel version>/initramfs.img, the layout
                `bootc container ukify --kernel-dir` reads

The base keeps no kernel or initramfs in /usr: both are only in its UKI (bootc container
split-kernel-and-rootfs). The desktop changes neither, so it takes them as they are: the .linux and
.initrd sections, each exactly once in the file (the base's profiles share them), each cut to its
real size (the raw data is padded to the file alignment).
"""
import os
import sys

import pefile


def main():
    uki_dir, modules, out = sys.argv[1:]
    ukis = os.listdir(uki_dir)
    if len(ukis) != 1 or not ukis[0].endswith(".efi"):
        sys.exit(f"kernel.py: {uki_dir} must hold exactly one UKI, not {ukis}")
    kver = ukis[0][: -len(".efi")]
    if os.listdir(modules) != [kver]:
        sys.exit(f"kernel.py: the base's UKI is for {kver}, the image's modules are {os.listdir(modules)}")
    found = {}
    for s in pefile.PE(os.path.join(uki_dir, ukis[0])).sections:
        name = s.Name.rstrip(b"\0").decode()
        if name not in (".linux", ".initrd"):
            continue
        if name in found:
            sys.exit(f"kernel.py: {name} is in the base's UKI more than once")
        found[name] = s.get_data()[: s.Misc_VirtualSize]
    if sorted(found) != [".initrd", ".linux"]:
        sys.exit(f"kernel.py: the base's UKI has {sorted(found)}, not .linux and .initrd")
    os.makedirs(os.path.join(out, kver))
    for name, file in ((".linux", "vmlinuz"), (".initrd", "initramfs.img")):
        with open(os.path.join(out, kver, file), "wb") as f:
            f.write(found[name])
    print(f"kernel.py: {kver}, kernel {len(found['.linux'])} bytes, initramfs {len(found['.initrd'])} bytes")


if __name__ == "__main__":
    main()
