#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The checks of the session test (docs/TESTING.md), run by run.sh in the tools container.

They talk to the session only over its buses: AT-SPI for what is on screen, KWin's ScreenShot2 for
the screenshot and plasmashell's scripting interface for the wallpaper.

    test_session.py REFERENCE OUT

Writes screenshot.png, diff.png and summary.md to OUT. Exits 1 when a check fails.
"""

import os
import sys
import time

import pyatspi
from gi.repository import Gio, GLib
from PIL import Image, ImageChops, ImageDraw

WIDTH, HEIGHT = 1280, 800
# A solid colour: the image's own wallpaper may change with time or theme, and the test is about the
# shell, not the wallpaper.
WALLPAPER = "#1d2b38"
# Left out of the comparison, as (left, top, right, bottom): the panel clock (time and date) and the
# pointer (KWin leaves it out of the capture, but where it rests depends on the backend).
MASKS = {
    "clock": (1150, 750, 1240, 800),
    "cursor": (608, 368, 672, 432),
}
# A pixel differs when one of its channels differs by more than this: llvmpipe's rounding can depend
# on the CPU's vector instructions, and runners have different CPUs.
PIXEL_TOLERANCE = 24
# The comparison fails when more than this share of the compared pixels differ.
MAX_DIFFERENT = 0.001

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}: {name}{': ' + detail if detail else ''}", flush=True)
    return ok


def wait_for(fn, timeout=60):
    """fn() until it returns something true, or None after timeout seconds. AT-SPI objects can vanish
    while they are read; that counts as not yet."""
    end = time.monotonic() + timeout
    while True:
        try:
            found = fn()
            if found:
                return found
        except GLib.Error:
            pass
        if time.monotonic() > end:
            return None
        time.sleep(0.5)


def application(name):
    desktop = pyatspi.Registry.getDesktop(0)
    for i in range(desktop.childCount):
        app = desktop[i]
        if app is not None and app.name == name:
            return app
    return None


def showing(acc):
    return acc.getState().contains(pyatspi.STATE_SHOWING)


def find_showing(root, role, name):
    def match(acc):
        try:
            return acc.getRoleName() == role and acc.name == name and showing(acc)
        except GLib.Error:
            return False
    return pyatspi.findDescendant(root, match) if root is not None else None


def press(acc):
    action = acc.queryAction()
    for i in range(action.nActions):
        if action.getName(i) == "Press":
            return action.doAction(i)
    raise RuntimeError(f"{acc.name} has no Press action")


def call(bus, name, path, interface, method, args, reply, fds=None):
    return bus.call_with_unix_fd_list_sync(name, path, interface, method, args, GLib.VariantType(reply),
                                           Gio.DBusCallFlags.NONE, 30000, fds, None)[0].unpack()


def capture(bus):
    """The whole 1280x800 screen through KWin's ScreenShot2, without the pointer, as an RGB image."""
    read_end, write_end = os.pipe()
    fds = Gio.UnixFDList.new_from_array([write_end])  # takes the write end, closed with fds
    meta = call(bus, "org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2",
                "CaptureWorkspace", GLib.Variant("(a{sv}h)", ({"include-cursor": GLib.Variant("b", False)}, 0)),
                "(a{sv})", fds)[0]
    del fds
    size = meta["stride"] * meta["height"]
    data = bytearray()
    with os.fdopen(read_end, "rb") as pipe:
        while len(data) < size:
            chunk = pipe.read(size - len(data))
            if not chunk:
                raise RuntimeError(f"screenshot ended after {len(data)} of {size} bytes")
            data += chunk
    # QImage's 32-bit formats are B, G, R, A in memory on little-endian machines.
    image = Image.frombuffer("RGBA", (meta["width"], meta["height"]), bytes(data), "raw", "BGRA", meta["stride"], 1)
    return image.convert("RGB")


def masked(image):
    image = image.copy()
    draw = ImageDraw.Draw(image)
    for box in MASKS.values():
        draw.rectangle(box, fill=(0, 0, 0))
    return image


def different_pixels(a, b):
    """The mask (mode L, 255 where they differ) of the pixels of a and b that differ beyond the
    tolerance, outside MASKS, and how many there are."""
    channels = ImageChops.difference(masked(a), masked(b)).split()
    most = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    differ = most.point(lambda v: 255 if v > PIXEL_TOLERANCE else 0)
    return differ, differ.histogram()[255]


def stable_screenshot(bus):
    """A screenshot that matches the one taken a second earlier: the desktop finished drawing."""
    previous = capture(bus)
    for _ in range(30):
        time.sleep(1)
        current = capture(bus)
        if different_pixels(previous, current)[1] == 0:
            return current
        previous = current
    return None


def compare(shot, reference_path, out):
    shot.save(os.path.join(out, "screenshot.png"))
    if not os.path.exists(reference_path):
        return check("screenshot matches the reference", False, f"no reference {reference_path}")
    reference = Image.open(reference_path).convert("RGB")
    if reference.size != shot.size:
        return check("screenshot matches the reference", False, f"size {shot.size}, reference {reference.size}")
    differ, count = different_pixels(shot, reference)
    # The diff image: the reference dimmed, differing pixels red, masked areas outlined in blue.
    diff = Image.blend(reference, Image.new("RGB", reference.size), 0.6)
    diff.paste((255, 0, 0), mask=differ)
    draw = ImageDraw.Draw(diff)
    for box in MASKS.values():
        draw.rectangle(box, outline=(0, 128, 255))
    diff.save(os.path.join(out, "diff.png"))
    compared = WIDTH * HEIGHT - sum((r - l + 1) * (b - t + 1) for l, t, r, b in MASKS.values())
    share = count / compared
    return check("screenshot matches the reference", share <= MAX_DIFFERENT,
                 f"{count} of {compared} pixels differ ({share:.4%}, at most {MAX_DIFFERENT:.2%} allowed)")


def write_summary(out):
    lines = ["| Check | Result | Detail |", "|---|---|---|"]
    for name, ok, detail in results:
        lines.append(f"| {name} | {'pass' if ok else '**FAIL**'} | {detail} |")
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def main(reference_path, out):
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    # The first AT-SPI client starts the accessibility bus; Qt programs register on it right after.
    shell = wait_for(lambda: application("plasmashell"))
    panel_launcher = wait_for(lambda: find_showing(shell, "button", "Application Launcher"))
    panel_clock = wait_for(lambda: find_showing(shell, "button", "Digital Clock"), timeout=5)
    if not check("the panel shows the application launcher and the clock",
                 panel_launcher is not None and panel_clock is not None):
        return
    shell_pid = shell.get_process_id()

    call(bus, "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", GLib.Variant(
        "(s)", ('desktops().forEach(function (d) { d.wallpaperPlugin = "org.kde.color";'
                ' d.currentConfigGroup = ["Wallpaper", "org.kde.color", "General"];'
                f' d.writeConfig("Color", "{WALLPAPER}"); }})',)), "(s)")
    try:
        shot = stable_screenshot(bus)
    except GLib.Error as e:
        # KWin cancels every screenshot without OpenGL compositing, which needs a DRM device.
        check("screenshot through KWin's ScreenShot2", False, f"{e.message} (is there a device in /dev/dri?)")
    else:
        if check("screenshot through KWin's ScreenShot2", shot is not None and shot.size == (WIDTH, HEIGHT),
                 "the screen did not settle within 30 s" if shot is None else f"{shot.size[0]}x{shot.size[1]}"):
            compare(shot, reference_path, out)

    press(panel_launcher)
    all_apps = wait_for(lambda: find_showing(shell, "list item", "All Applications"), timeout=20)
    if not check("the application launcher opens", all_apps is not None):
        return
    press(all_apps)
    konsole_item = wait_for(lambda: find_showing(shell, "list item", "Konsole"), timeout=20)
    dolphin_item = wait_for(lambda: find_showing(shell, "list item", "Dolphin"), timeout=5)
    if not check("the launcher lists Konsole and Dolphin", konsole_item is not None and dolphin_item is not None,
                 f"Konsole {'found' if konsole_item else 'missing'}, Dolphin {'found' if dolphin_item else 'missing'}"):
        return

    press(konsole_item)
    window = wait_for(lambda: next((app[i] for app in [application("konsole")] if app is not None
                                    for i in range(app.childCount)
                                    if app[i].getRoleName() == "frame" and showing(app[i])), None))
    check("Konsole started from the launcher shows a window", window is not None,
          repr(window.name) if window is not None else "no Konsole window within 60 s")

    shell = application("plasmashell")
    check("plasmashell and KWin still run (no crash, no restart)",
          shell is not None and shell.get_process_id() == shell_pid and application("kwin") is not None)


if __name__ == "__main__":
    reference_path, out = sys.argv[1], sys.argv[2]
    try:
        main(reference_path, out)
    finally:
        write_summary(out)
    sys.exit(0 if results and all(ok for _, ok, _ in results) else 1)
