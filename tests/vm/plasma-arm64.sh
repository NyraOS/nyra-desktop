#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The desktop's smoke test on aarch64 (docs/TESTING.md, "Level 2, aarch64"): the arm64 image, installed as
# nyra-base's tests install the base, boots with Secure Boot (Debian's arm64 shim -> systemd-boot -> the
# desktop's UKI, signed with the run's key, enrolled as a MOK) to SDDM's login screen, and SDDM starts a
# Plasma (Wayland) session for a test user, which stays up. Screenshots of both are left in LOGDIR.
#   tests/vm/plasma-arm64.sh BASE_SRC IMAGE UKI_CERT WORKDIR LOGDIR SUMMARY
# The same steps as tests/vm/plasma.sh, on QEMU's virt machine with edk2 (AAVMF), and only the login screen
# and the session: GitHub's arm64 runners have no KVM (October 2026), so the guest is emulated (TCG) and a
# desktop takes minutes to start. The SD card, printing, sound and video tests of the x86_64 test are not
# run here. Emulated, nothing fits the x86_64 waits: the guest's commands each wait up to 300 s (vm-boot.py),
# so a wait for the greeter or the session is a series of polls that end in one command that must succeed.
# BASE_SRC is the nyra-base checkout of the pinned arm64 base (base/pin-arm64): its install script, test
# console add-on and VM runner. The test console add-on is signed here with a key made for this run,
# enrolled as a MOK next to the UKI's, and deleted at the end with the other files of WORKDIR/secure-boot.
# Never use a real key here. The test user logs in through SDDM's autologin, set for the test only in
# /etc/sddm.conf.d: the login screen itself is checked by its greeter running and by its screenshot.
set -euo pipefail

base_src="$(realpath "$1")" image="$2" uki_cert="$(realpath "$3")" work="$(realpath "$4")"
logs="$(realpath "$5")" summary="$(realpath -m "$6")"
sb="$work/secure-boot"
mnt="$sb/esp"
loop=""
mkdir -p "$mnt" "$logs"
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; rm -rf "$sb"' EXIT
# nyra-base's scripts call each other by paths relative to its checkout.
cd "$base_src"

tools/vm/install-disk.sh "$image" "$work"

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra Desktop CI add-on test key" \
  -keyout "$sb/local.key" -out "$sb/local.crt" 2>/dev/null
# Secure Boot on, with the Microsoft keys; the MOKs under shim's owner GUID.
virt-fw-vars --input /usr/share/AAVMF/AAVMF_VARS.ms.fd --output "$sb/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb/local.crt"
tools/vm/test-addon.sh "$image" "$sb/console.addon.efi" systemd.import_credentials=yes "$sb/local.key" "$sb/local.crt"

# The boot files as the installer places them (nyra-base docs/BOOT.md): shim on the removable-media
# path, systemd-boot under the name shim starts, MokManager; all from the image.
cid="$(sudo podman create -q "$image")"
for f in /usr/lib/shim/shimaa64.efi.signed /usr/lib/shim/mmaa64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootaa64.efi.signed; do
  sudo podman cp "$cid:$f" "$sb/"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$sb"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
uki="$(sudo sed -n 's/^uki[[:space:]]\+//p' "$mnt"/loader/entries/*.conf)"
sudo sbverify --cert "$uki_cert" "$mnt$uki"
sudo cp "$sb/shimaa64.efi.signed" "$mnt/EFI/BOOT/BOOTAA64.EFI"
sudo cp "$sb/systemd-bootaa64.efi.signed" "$mnt/EFI/BOOT/grubaa64.efi"
sudo cp "$sb/mmaa64.efi.signed" "$mnt/EFI/BOOT/mmaa64.efi"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$sb/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""

# KVM when the runner has it (a Mac or another machine), emulated otherwise.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then boot_timeout=300 polls=2; else boot_timeout=1800 polls=10; fi
echo "boot timeout $boot_timeout s, up to $polls polls of 210 s per wait"

# Guest commands. poll CMD: for up to 210 s, until CMD succeeds; it always succeeds itself, so that
# a series of them can wait longer than one command may (300 s); the command after the series is the check.
poll='p() { end=$((SECONDS+210)); while [ $SECONDS -lt $end ]; do if eval "$1"; then echo "ready after $SECONDS s"; return 0; fi; sleep 3; done; echo "not ready after 210 s"; return 0; }; p'
# The greeter has made its window ("Adding view for <output>"); it paints the theme some time later,
# emulated much later, hence the wait before the screenshot.
greeter='pgrep -u sddm -f "^/usr/bin/sddm-greeter-qt6 " >/dev/null && pgrep -u sddm -x kwin_wayland >/dev/null && journalctl -b -q -t sddm-greeter-qt6 | grep -q "Adding view for"'
session='s="$(loginctl show-user nyratest -p Display --value 2>/dev/null)" && [ -n "$s" ] && [ "$(loginctl show-session "$s" -p Type --value)" = wayland ] && [ "$(loginctl show-session "$s" -p Active --value)" = yes ] && pgrep -u nyratest -x plasmashell >/dev/null'
autologin='[Autologin]\nUser=nyratest\nSession=plasma.desktop\n'
shot() { echo "NYRA-SHOT-$1=>{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$logs/$1.png\",\"format\":\"png\"}}"; }

args=()
for _ in $(seq "$polls"); do args+=(--command "$poll '$greeter'"); done
args+=(--command "$greeter && ps -o user=,rss=,args= -u sddm && sleep 120 && echo NYRA-SHOT-''login-screen && sleep 3")
args+=(--command "useradd -m -s /bin/bash nyratest && mkdir -p /etc/sddm.conf.d && printf '$autologin' > /etc/sddm.conf.d/99-nyra-test.conf && systemctl restart sddm.service")
for _ in $(seq "$polls"); do args+=(--command "$poll '$session'"); done
args+=(--command "$session && loginctl")
args+=(--command 'p="$(pgrep -u nyratest -x plasmashell)"; sleep 120; test "$(pgrep -u nyratest -x plasmashell)" = "$p" && pgrep -u nyratest -x kwin_wayland >/dev/null && echo "plasmashell $p and kwin_wayland run after 120 s" && ps -o rss=,args= -u nyratest | sort -rn | head -12 && sleep 180 && echo NYRA-SHOT-"plasma-session" && sleep 3')

python3 -B tools/vm/vm-boot.py --secure-boot "$sb/vars.fd" --disk "$work/disk.raw" --autologin --timeout "$boot_timeout" \
  --qemu=-device --qemu=virtio-gpu-pci --qemu=-device --qemu=qemu-xhci --qemu=-device --qemu=usb-kbd \
  --qemu=-device --qemu=usb-tablet \
  --qmp "$(shot login-screen)" --qmp "$(shot plasma-session)" \
  --log "$logs/serial-plasma-arm64.log" --summary "$summary" \
  --title "Desktop on aarch64: Secure Boot to the login screen, then a Plasma session" \
  --command 'uname -m; test "$(uname -m)" = aarch64' \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command 'cat /proc/cmdline; grep -Eq "(^| )composefs=[0-9a-f]{128}( |$)" /proc/cmdline' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  --command 's="$(systemctl show getty@tty1.service -p LoadState --value)"; echo "getty@tty1: $s"; test "$s" = masked' \
  --command 'systemctl is-active sddm.service' \
  "${args[@]}" \
  --command 'systemctl show sddm.service -p MemoryCurrent; systemctl show user-$(id -u sddm).slice -p MemoryCurrent; systemctl --no-pager list-units --type=service --state=running --no-legend --plain | cut -d" " -f1' \
  --command 'journalctl -b --no-pager -p warning -u sddm.service | tail -20; ! journalctl -b --no-pager | grep -E "KCrash|dumped core|segfault"'

# Both screenshots were taken, and are PNG files with some content in them (a blank screen compresses to
# a few hundred bytes).
for s in login-screen plasma-session; do
  test "$(stat -c %s "$logs/$s.png")" -gt 5000
  [ "$(head -c 4 "$logs/$s.png" | tail -c 3)" = PNG ]
done
