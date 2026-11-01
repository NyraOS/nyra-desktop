#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Every package in image/packages/ has a reason on its line (docs/IMAGE.md, "Packages"): a line is a
# comment, empty, or "package  reason". Fails on a package without a reason, a package twice, and a
# name that is not a Debian package name.
#   ci/check-package-reasons.sh [LIST...]   (default: image/packages/*.list)
set -euo pipefail

[ "$#" -gt 0 ] || set -- image/packages/*.list
status=0
for f in "$@"; do
  awk -v f="$f" '
    /^#/ || /^[[:space:]]*$/ { next }
    {
      if ($1 !~ /^[a-z0-9][a-z0-9+.-]+$/) { printf "%s:%d: \"%s\" is not a package name\n", f, NR, $1; bad = 1; next }
      if (NF < 2) { printf "%s:%d: %s has no reason\n", f, NR, $1; bad = 1 }
      if ($1 in seen) { printf "%s:%d: %s is already on line %d\n", f, NR, $1, seen[$1]; bad = 1 }
      seen[$1] = NR
    }
    END { exit bad }' "$f" || status=1
done
exit "$status"
