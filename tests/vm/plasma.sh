#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The desktop's smoke test in a VM (docs/TESTING.md, "Level 2"): the image, installed as nyra-base's
# tests install the base, boots with Secure Boot (shim -> systemd-boot -> the desktop's UKI, signed with
# the run's key, enrolled as a MOK) to SDDM's login screen, and SDDM starts a Plasma (Wayland) session
# for a test user, which stays up. Screenshots of both are left in LOGDIR.
#   tests/vm/plasma.sh BASE_SRC IMAGE UKI_CERT WORKDIR LOGDIR SUMMARY
# BASE_SRC is the nyra-base checkout of the pinned base (base/pin): its install script, test console
# add-on and VM runner (tools/vm), which the base's own tests use. The test console (a root shell on the
# serial console, from systemd credentials) needs an add-on that turns credential import back on: it is
# signed here with a key made for this run, enrolled as a MOK next to the UKI's, and deleted at the end
# with the other files of WORKDIR/secure-boot. Never use a real key here.
# The test user logs in through SDDM's autologin, set for the test only in /etc/sddm.conf.d: the login
# screen itself is checked by its greeter running and by its screenshot, not by typing a password.
# Then one test per category of the image's packages (docs/TESTING.md): an SD card that is mounted by
# itself, a page printed to a virtual IPP printer, sound played and recorded through PipeWire, and an
# H.264 video decoded. Last, the languages (docs/TESTING.md): fixtures/languages.sh checks the locales,
# translations and fonts of English, Romanian, Japanese and Arabic and the long list of locales, then
# fixtures/language-session.sh sets Japanese and Arabic with localectl, as the installer does, and checks
# the login screen and the Plasma session in each, with a screenshot of both.
# With every locale in the image, systemd-firstboot asks for one at the first boot and waits for an answer
# on the console; the installer answers it (nyra-first-admin), so the test does too, with a credential.
# The devices are the VM's (an SD card on an SDHCI controller, an HDA sound card
# without a host backend); the printer is ippeveprinter on the host, which the guest reaches at QEMU's
# 10.0.2.2. They need cups-ipp-utils and avahi-daemon (ippeveprinter registers with it), dosfstools
# and mount on the host. Everything these tests set is set in the VM at run time, never in the image.
set -euo pipefail

here="$(dirname "$(realpath "$0")")"
base_src="$(realpath "$1")" image="$2" uki_cert="$(realpath "$3")" work="$(realpath "$4")"
logs="$(realpath "$5")" summary="$(realpath -m "$6")"
sb="$work/secure-boot"
mnt="$sb/esp"
loop=""
mkdir -p "$mnt" "$logs"
ipp=""
trap 'sudo umount -q "$mnt" 2>/dev/null || true; [ -z "$loop" ] || sudo losetup -d "$loop" || true; [ -z "$ipp" ] || kill "$ipp" 2>/dev/null || true; rm -rf "$sb"' EXIT
# nyra-base's scripts call each other by paths relative to its checkout.
cd "$base_src"

tools/vm/install-disk.sh "$image" "$work"

openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Nyra Desktop CI add-on test key" \
  -keyout "$sb/local.key" -out "$sb/local.crt" 2>/dev/null
# Secure Boot on, with the Microsoft keys; the MOKs under shim's owner GUID.
virt-fw-vars --input /usr/share/OVMF/OVMF_VARS_4M.ms.fd --output "$sb/vars.fd" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$uki_cert" \
  --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$sb/local.crt"
# The add-on's command line is the test's own, never the image's: credential import for the test console,
# and what the boot screen needs to show in a VM (docs/TESTING.md, "The boot screen"). The sealed command
# line has no "splash", which plymouth shows its theme only with (nyra-base's change), and the serial
# console that the test needs makes plymouth fall back to its text theme unless it is told to ignore it.
tools/vm/test-addon.sh "$image" "$sb/console.addon.efi" "systemd.import_credentials=yes splash plymouth.ignore-serial-consoles" "$sb/local.key" "$sb/local.crt"

# The boot files as the installer places them (nyra-base docs/BOOT.md): shim on the removable-media
# path, systemd-boot under the name shim starts, MokManager; all from the image.
cid="$(sudo podman create -q "$image")"
for f in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/mmx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed; do
  sudo podman cp "$cid:$f" "$sb/"
done
sudo podman rm -f "$cid" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$sb"
loop="$(sudo losetup -P --show -f "$work/disk.raw")"
esp="$(tools/vm/esp-of.sh "$loop")"
sudo mount "$esp" "$mnt"
uki="$(sed -n 's/^uki[[:space:]]\+//p' "$mnt"/loader/entries/*.conf)"
sbverify --cert "$uki_cert" "$mnt$uki"
sudo cp "$sb/shimx64.efi.signed" "$mnt/EFI/BOOT/BOOTX64.EFI"
sudo cp "$sb/systemd-bootx64.efi.signed" "$mnt/EFI/BOOT/grubx64.efi"
sudo cp "$sb/mmx64.efi.signed" "$mnt/EFI/BOOT/mmx64.efi"
sudo mkdir -p "$mnt/loader/addons"
sudo cp "$sb/console.addon.efi" "$mnt/loader/addons/nyra-test-console.addon.efi"
sudo umount "$mnt"
sudo losetup -d "$loop"
loop=""

# The SD card: a FAT card with the label NYRASD and the test clip on it (copied through a loop mount,
# the same way the ESP is written above).
sd="$sb/sd.img"
truncate -s 64M "$sd"
mkfs.vfat -n NYRASD "$sd" >/dev/null
sudo mount -o loop,uid="$(id -u)" "$sd" "$mnt"
cp "$here/fixtures/h264.mp4" "$here/fixtures/languages.sh" "$here/fixtures/language-session.sh" "$mnt/"
sudo umount "$mnt"

# The virtual IPP printer: it keeps every document it gets in WORKDIR/printed (-k).
mkdir -p "$sb/printed"
ippeveprinter -d "$sb/printed" -k -p 8631 "Nyra test printer" >"$logs/ippeveprinter.log" 2>&1 &
ipp=$!

# Guest commands. wait_for CMD: up to 120 s for CMD to succeed.
wait_for='w() { for _ in $(seq 60); do if eval "$1"; then return 0; fi; sleep 2; done; eval "$1"; }; w'
# The greeter has made its window ("Adding view for <output>"); with llvmpipe it paints the theme some
# seconds later, hence the wait before the screenshot.
greeter='pgrep -u sddm -f "^/usr/bin/sddm-greeter-qt6 " >/dev/null && pgrep -u sddm -x kwin_wayland >/dev/null && journalctl -b -q -t sddm-greeter-qt6 | grep -q "Adding view for"'
session='s="$(loginctl show-user nyratest -p Display --value 2>/dev/null)" && [ -n "$s" ] && [ "$(loginctl show-session "$s" -p Type --value)" = wayland ] && [ "$(loginctl show-session "$s" -p Active --value)" = yes ] && pgrep -u nyratest -x plasmashell >/dev/null'
autologin='[Autologin]\nUser=nyratest\nSession=plasma.desktop\n'
# Plasma's device automounter (plasma-desktop), switched on for the test user only: it is off by default.
automount='[General]\nAutomountEnabled=true\nAutomountOnLogin=true\nAutomountOnPlugin=true\nAutomountUnknownDevices=true\n'
# A command as the test user, with the runtime directory of its session (PipeWire's socket is there).
u='runuser -u nyratest -- env XDG_RUNTIME_DIR=/run/user/$(id -u nyratest)'
card=/run/media/nyratest/NYRASD
# What ffmpeg's decoder must make of tests/vm/fixtures/h264.mp4: 10 frames of 128x96, and their SHA-256
# as raw yuv420p (the H.264 decoder is bit-exact, so it does not depend on the ffmpeg version).
clip_sha256=4726168e93980f0ae6a17bbc7f74817f23ecfb30d5da47f6a4346c29532c729f
# The journal of the login screen's parts, for the artifacts (tests/vm/extract-journal.sh): SDDM and its
# helper, the greeter, KWin, plymouth, logind and PAM, with the monotonic time; the last 600 lines, each cut
# to 300 characters, so that it fits the serial log. It succeeds always: the commands after the greeter's
# wait run whether or not the wait did, so the journal of a greeter that did not start is kept. The last
# line counts the helper's exits in the lines above it, the sign of a greeter that died or never came up.
journal='j() { echo "NYRA-JOURNAL-BE""GIN $1"; o="$(journalctl -b -o short-monotonic --no-pager | grep -Ei "sddm|kwin|plymouth|greeter|logind|pam_" | tail -n 600 | cut -c1-300)"; echo "$o"; echo "drm: kernel lines, then when systemd saw the device nodes (monotonic microseconds)"; journalctl -b -k -o short-monotonic --no-pager | grep -Ei "drm|virtio_gpu|virtio-gpu" | cut -c1-200; systemctl show dev-dri-card0.device dev-dri-renderD128.device -p Id -p ActiveEnterTimestampMonotonic | grep -v "^$"; ls -l --time=birth --time-style=full-iso /dev/dri/ 2>&1; echo "sddm-helper exited with: $(echo "$o" | grep -c "Auth: sddm-helper exited wit[h]") lines above"; echo "NYRA-JOURNAL-EN""D $1"; true; }; j'
shot() { echo "NYRA-SHOT-$1=>{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$logs/$1.png\",\"format\":\"png\"}}"; }
# The boot screen is photographed while plymouth shows it. The console prints nothing once plymouth is up,
# so plymouth-quit (test only: a drop-in passed as a credential) prints the marker the --qmp trigger waits
# for on the serial port itself (plymouth redirects /dev/console), then waits 4 s: once plymouth quits it lets go of the display, which goes blank. The getty and SDDM
# start after plymouth-quit, so they wait too.
hold_quit=$'[Service]\nExecStartPre=/bin/sh -c \'echo NYRA-SHOT-boot-screen >/dev/ttyS0; sleep 4\''

vm=0
python3 -B tools/vm/vm-boot.py --secure-boot "$sb/vars.fd" --disk "$work/disk.raw" --autologin --timeout 300 \
  --qemu=-device --qemu=virtio-vga --qemu=-device --qemu=qemu-xhci --qemu=-device --qemu=usb-kbd \
  --qemu=-device --qemu=usb-tablet \
  --qemu=-drive --qemu="if=none,id=sd0,format=raw,file=$sd" \
  --qemu=-device --qemu=sdhci-pci --qemu=-device --qemu=sd-card,drive=sd0 \
  --qemu=-audiodev --qemu=none,id=snd0 --qemu=-device --qemu=intel-hda --qemu=-device --qemu=hda-duplex,audiodev=snd0 \
  --smbios "io.systemd.stub.kernel-cmdline-extra=console=ttyS0" \
  --smbios "io.systemd.credential:firstboot.locale=en_US.UTF-8" \
  --qmp "$(shot boot-screen)" --credential "systemd.unit-dropin.plymouth-quit.service=$hold_quit" \
  --qmp "$(shot login-screen)" --qmp "$(shot plasma-session)" \
  --qmp "$(shot login-screen-ja)" --qmp "$(shot plasma-session-ja)" \
  --qmp "$(shot login-screen-ar)" --qmp "$(shot plasma-session-ar)" \
  --log "$logs/serial-plasma.log" --summary "$summary" \
  --title "Desktop: Secure Boot to the login screen, then a Plasma session" \
  --command 'mokutil --sb-state; mokutil --sb-state | grep -qx "SecureBoot enabled"' \
  --command 'cat /proc/cmdline; grep -Eq "(^| )composefs=[0-9a-f]{128}( |$)" /proc/cmdline' \
  --command 's="$(systemctl is-system-running --wait)"; echo "system: $s"; systemctl --no-pager --failed; test "$s" = running' \
  --command 's="$(systemctl show getty@tty1.service -p LoadState --value)"; echo "getty@tty1: $s"; test "$s" = masked' \
  --command "systemctl is-active sddm.service && $wait_for '$greeter' && ps -o user=,rss=,args= -u sddm && sleep 30 && echo NYRA-SHOT-''login-screen && sleep 3" \
  --command "$journal greeter" \
  --command 't="$(journalctl -b -o short-monotonic -t sddm-greeter-qt6 | sed -n "s/^\[ *\([0-9]*\)\..*Adding view for.*/\1/p" | head -1)"; n="$(systemctl list-units --all --state=active --no-legend --plain | wc -l)"; echo "boot time: the login screen at ${t}s after the kernel started; $n active units"; systemd-analyze time; systemd-analyze blame --no-pager | grep -v "\.device" | head -10; test -n "$t" && test "$t" -lt 240 && test "$n" -lt 250 && ! pgrep -u sddm -x "pipewire|wireplumber|pipewire-pulse" && ! systemctl list-units --all --no-legend --plain | awk '"'"'$2 == "loaded"'"'"' | grep -E "^(NetworkManager|ModemManager|bluetooth|avahi)"' \
  --command 'systemctl show sddm.service -p MemoryCurrent; systemctl show user-$(id -u sddm).slice -p MemoryCurrent; systemctl is-enabled accounts-daemon.service; systemctl --no-pager list-units --type=service --state=running --no-legend --plain | cut -d" " -f1' \
  --command "useradd -m -s /bin/bash nyratest && install -d -o nyratest -g nyratest ~nyratest/.config && printf '$automount' > ~nyratest/.config/kded_device_automounterrc && chown nyratest: ~nyratest/.config/kded_device_automounterrc && mkdir -p /etc/sddm.conf.d && printf '$autologin' > /etc/sddm.conf.d/99-nyra-test.conf && systemctl restart sddm.service && $wait_for '$session' && loginctl" \
  --command 'p="$(pgrep -u nyratest -x plasmashell)"; sleep 90; test "$(pgrep -u nyratest -x plasmashell)" = "$p" && pgrep -u nyratest -x kwin_wayland >/dev/null && echo "plasmashell $p and kwin_wayland run after 90 s" && ps -o rss=,args= -u nyratest | sort -rn | head -12 && echo NYRA-SHOT-"plasma-session" && sleep 3' \
  --command "ls -l /dev/mmcblk0 && $wait_for 'findmnt -n $card' && findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS $card && o=\",\$(findmnt -n -o OPTIONS $card),\" && echo \"\$o\" | grep -q ,noexec, && echo \"\$o\" | grep -q ,nosuid, && echo \"\$o\" | grep -q ,nodev, && ls -l $card && $u sh -c 'echo nyra > $card/written && sync' && grep -qx nyra $card/written" \
  --command "$wait_for 'ip route | grep -q ^default' && lpadmin -p virt -E -v ipp://10.0.2.2:8631/ipp/print -m everywhere && lpstat -p virt && ! awk '\$4==\"0A\" && \$2 ~ /:0277\$/ { f=1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 && ! awk '\$2 ~ /:0277\$/ { f=1 } END { exit !f }' /proc/net/udp /proc/net/udp6 && echo 'cupsd listens on no TCP or UDP port 631' && printf 'A page for the printer.\n' > /tmp/page.txt && lp -d virt /tmp/page.txt && $wait_for 'lpstat -W completed -o virt | grep -q virt-1' && lpstat -W completed -o virt" \
  --command "$wait_for '$u pw-cli ls Node | grep -q alsa_output && $u pw-cli ls Node | grep -q alsa_input' && $u wpctl status" \
  --command "$u ffmpeg -nostdin -v error -f lavfi -i sine=frequency=440:duration=2 -ar 48000 -ac 2 /tmp/tone.wav && { $u pw-record -P stream.capture.sink=true /tmp/monitor.wav & sleep 2; r=0; $u pw-play /tmp/tone.wav || r=1; sleep 1; pkill -INT -u nyratest -x pw-record; sleep 1; test \$r = 0; } && m=\"\$($u ffmpeg -nostdin -i /tmp/monitor.wav -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \\(-*[0-9.]*\\) dB.*/\\1/p')\" && echo \"the sink's monitor heard the tone, max_volume=\$m dB\" && awk -v m=\"\$m\" 'BEGIN { exit !(m != \"\" && m > -40) }' && { $u timeout -s INT 3 pw-record --rate 48000 /tmp/rec.wav; true; } && ls -l /tmp/rec.wav && test \"\$(stat -c %s /tmp/rec.wav)\" -gt 48000" \
  --command "v=\"\$($u ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,nb_frames -of csv=p=0 $card/h264.mp4)\"; echo \"\$v\"; test \"\$v\" = h264,10; h=\"\$($u ffmpeg -nostdin -v error -i $card/h264.mp4 -map 0:v -c:v rawvideo -pix_fmt yuv420p -f hash -hash sha256 -)\"; echo \"\$h\"; test \"\$h\" = SHA256=$clip_sha256" \
  --command "sh $card/languages.sh" \
  --command "sh $card/language-session.sh ja_JP.UTF-8 jp jp ja" \
  --command "sh $card/language-session.sh ar_SA.UTF-8 ara ara ar" \
  --command "$journal end" \
  --command 'journalctl -b --no-pager -p warning -u sddm.service | tail -20; ! journalctl -b --no-pager | grep -E "KCrash|dumped core|segfault"' || vm=$?

# The journal is kept whether or not the run passed; the failure ends the script after it.
"$here/extract-journal.sh" "$logs/serial-plasma.log" "$logs/guest-journal.log"
[ "$vm" = 0 ] || exit "$vm"

# The boot screen was on the screen when the console came up (the theme's background, the logo and its moon).
python3 -I "$here/screen-splash.py" "$logs/boot-screen.png"

# The page the guest printed reached the printer on the host: a file of the job, not empty.
{ echo; echo "Printed on the virtual printer (ippeveprinter):"; echo '```'; ls -l "$sb/printed"; echo '```'; } >> "$summary"
test -n "$(find "$sb/printed" -type f -size +0 -print -quit)"
