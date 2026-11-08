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
# /etc/sddm.conf.d.
# The screenshots are evidence too: the greeter and the desktop must show real UI. An emulated greeter
# or desktop stays on the wallpaper (the greeter) or the lock screen (the session) until it gets input and
# has had time to paint, so each is woken with QMP key and tablet events and then photographed every 30 s;
# tests/vm/screen-ui.py takes the first photograph that shows UI as login-screen.png (plasma-session.png)
# and fails the job when none does. Nothing waits for a quiet CPU: under emulation the greeter keeps both
# vCPUs busy (docs/TESTING.md), so the CPU use of each 30 s is only logged.
set -euo pipefail

here="$(dirname "$(realpath "$0")")"

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

# The test user's screen is never locked by idling: a locked session shows the lock screen, not the desktop.
nolock='[Daemon]\nAutolock=false\nLockOnResume=false\n'
# Input for the guest, a QMP event (a key press and release, a tablet move) that wakes the greeter and the
# desktop. The tablet is absolute: 0 to 32767 on both axes. Each wake has its own name, the marker the guest
# prints, because vm-boot.py sends a QMP command once.
wake() { echo "NYRA-WAKE-$1=>{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"shift\"}}},{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\"shift\"}}},{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$2}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$3}}]}}"; }
# series NAME WAKE FIRST LAST: wake the screen, then NAME-FIRST ... NAME-LAST, one every 30 s, each with the
# CPU seconds all processes used in that time (the guest has 2 vCPUs: 60 s is full load) and the five that
# used most. Under 300 s, what a guest command may take.
series='series() { echo NYRA-WAKE-$1-$2; for i in $(seq $3 $4); do ps -eo pid=,cputimes=,comm= > /tmp/c1; sleep 30; ps -eo pid=,cputimes=,comm= > /tmp/c2; echo "cpu in 30 s, all processes: $(awk "NR==FNR {a[\$1]=\$2; next} {s+=\$2-a[\$1]} END {print s+0}" /tmp/c1 /tmp/c2) s; the most:"; awk "NR==FNR {a[\$1]=\$2; next} \$2-a[\$1] > 0 {print \$2-a[\$1], \$1, \$3}" /tmp/c1 /tmp/c2 | sort -rn | head -5; echo NYRA-SHOT-$1-$i; sleep 3; done; }'
shots=5  # per command; two commands (and two wakes) for each of the screens
args=(--command "$series")
for _ in $(seq "$polls"); do args+=(--command "$poll '$greeter'"); done
args+=(--command "$greeter && ps -o user=,rss=,args= -u sddm")
args+=(--command "series login a 1 $shots")
args+=(--command "series login b $((shots+1)) $((2*shots))")
args+=(--command "useradd -m -s /bin/bash nyratest && install -d -o nyratest -g nyratest ~nyratest/.config && printf '$nolock' > ~nyratest/.config/kscreenlockerrc && chown nyratest: ~nyratest/.config/kscreenlockerrc && mkdir -p /etc/sddm.conf.d && printf '$autologin' > /etc/sddm.conf.d/99-nyra-test.conf && systemctl restart sddm.service")
for _ in $(seq "$polls"); do args+=(--command "$poll '$session'"); done
args+=(--command "$session && loginctl && pgrep -u nyratest -x plasmashell > /tmp/plasmashell.pid && sleep 60")
args+=(--command 'test "$(pgrep -u nyratest -x plasmashell)" = "$(cat /tmp/plasmashell.pid)" && pgrep -u nyratest -x kwin_wayland >/dev/null && echo "plasmashell $(cat /tmp/plasmashell.pid) and kwin_wayland still run" && ps -o rss=,args= -u nyratest | sort -rn | head -12')
args+=(--command "series session a 1 $shots")
args+=(--command "series session b $((shots+1)) $((2*shots)); test \"\$(pgrep -u nyratest -x plasmashell)\" = \"\$(cat /tmp/plasmashell.pid)\"")

shot_args=()
for s in login session; do
  for i in $(seq $((2*shots))); do shot_args+=(--qmp "$(shot "$s-$i")"); done
done

python3 -B tools/vm/vm-boot.py --secure-boot "$sb/vars.fd" --disk "$work/disk.raw" --autologin --timeout "$boot_timeout" \
  --qemu=-device --qemu=virtio-gpu-pci --qemu=-device --qemu=qemu-xhci --qemu=-device --qemu=usb-kbd \
  --qemu=-device --qemu=usb-tablet \
  --smbios "io.systemd.credential:firstboot.locale=en_US.UTF-8" \
  --qmp "$(wake login-a 16000 16000)" --qmp "$(wake login-b 20000 12000)" \
  --qmp "$(wake session-a 12000 20000)" --qmp "$(wake session-b 16000 16000)" "${shot_args[@]}" \
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

# The screenshots show UI: the greeter, then the desktop (the first of each series that does; the job fails
# when none does, after both are checked so that a log shows both).
rc=0
for s in login session; do
  files=(); for i in $(seq $((2*shots))); do files+=("$logs/$s-$i.png"); done
  out="$logs/login-screen.png"; [ "$s" = login ] || out="$logs/plasma-session.png"
  python3 -I "$here/screen-ui.py" 300 "$out" "${files[@]}" || rc=1
done
exit "$rc"
