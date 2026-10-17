# Contributing to nyra-desktop

This repository builds the desktop image of Nyra OS on top of
[nyra-base](https://github.com/NyraOS/nyra-base). The rules are the same as there: strict but short.

- **Branch and pull request, never a push to `main`.** Enable the local guard once:
  `git config core.hooksPath tools/hooks` (`tools/hooks/pre-push` refuses a push to `main`).
  Every change is reviewed before it is merged (`.github/CODEOWNERS`).
- **One change per pull request**, small and with a clear reason. Prefer the simplest solution that
  works; no options or abstractions "for later".
- **Code rules** (for everyone, people and agents alike; reviews check them):
  - **Rust:** the code must be easy to read, without needless complication. A reader who knows
    Rust understands a function without jumping through five files; names say what a thing is;
    generics, traits, macros or `unsafe` only when really needed, with the reason written next to
    them; plain code instead of an abstraction used once; comments say why, not what.
- **Never weaken or skip a test to make it pass.** A flaky test is a bug: fix it or report it.
- **A change to the look changes the reference screenshot in the same pull request**, and only then
  ([`docs/TESTING.md`](docs/TESTING.md)).
- **No secrets.** No keys, tokens or passwords in the repository, its history or CI logs; gitleaks
  scans every push.
- **Configuration goes in `/usr`**, never in `/etc` of the image: `/etc` belongs to the user and is
  kept across updates.
- **Pin what CI runs:** actions by commit SHA, container images by digest, packages by version,
  hash or snapshot date.
- **English** for code, comments, commit messages and documentation. New files carry an SPDX header
  (`GPL-3.0-or-later`, the licence of this repository); contributions are accepted under it.
- Run shellcheck, actionlint and the session test ([`docs/TESTING.md`](docs/TESTING.md)) before you
  push, and push once when the change is ready.
