#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The guest's login-screen journal (the `journal` command of plasma.sh and plasma-arm64.sh prints it between
# two markers on the serial console) copied out of the serial log into its own artifact file.
#   tests/vm/extract-journal.sh SERIAL_LOG OUT
# The serial console is the only channel the tests have to the guest, and the journal is printed by a command
# that runs whether or not the checks before it passed, so the file is there for a failed run too.
set -euo pipefail
tr -d '\r' < "$1" | sed -n '/^NYRA-JOURNAL-BEGIN/,/^NYRA-JOURNAL-END/p' > "$2"
