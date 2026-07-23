# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-23

Initial public release.

### kali-ui-setup.sh
- One-shot Kali post-install theming, run as root, scoped to the invoking user
  (`SUDO_USER`) so nothing lands in root's profile.
- Cyberpunk dark-teal theme across shells and desktop: `~/.shell_common`,
  `~/.bashrc` (with ble.sh autosuggestions + syntax highlighting) and `~/.zshrc`
  (Oh My Zsh + Powerlevel10k).
- Desktop theming: Papirus-Dark icons with folders recolored to teal via
  `papirus-folders`, Bibata-Modern-Ice cursor, Fluent-round-teal-Dark-compact GTK
  theme, palette-matched terminal, and a custom XFCE panel stats plugin.
- MesloLGS Nerd Font, fastfetch, tmux, and a Neovim OSC52 clipboard fix.
- Desktop keyboard shortcuts: Alt+B (Burp), Alt+T (terminal), Super+E (files).
- Deploys `tool-installer.sh` to `~/.local/bin` and launches it at the end.
- Deliberately makes no DPI / global font-scale changes.

### tool-installer.sh
- `fzf`-driven menu to install and track 89+ offensive-security tools under
  `/opt/tools`, with install-state detection.
- Install types: `apt`, `pip`, `git+pip`, `git+bash`, `go`, `winbin`
  (Windows-target binaries), `rawfile`, and `special`.
- Isolated Python installs via `pipx`; optional faster `uv` backend chosen per
  selection after tools are picked.
- Schema-versioned `tools.conf` that auto-regenerates (with backup) when the
  on-disk copy is outdated.
- "Add a new tool" menu entry and a download-only Burp Suite fetcher that
  enforces the SHA-256 published by PortSwigger (aborts and deletes on mismatch).

### Security / privacy hardening
- Generic browser User-Agent instead of a bespoke, fingerprintable one.
- `go install` routed with `GOPROXY=direct` and `GOSUMDB=off` so module paths
  aren't reported to Google's proxy/checksum database.
- No personal handle in scripts, comments, or on-disk paths; neutral directory
  names (`~/.config/kali-tools`, `~/.local/share/kali-ui-assets`).
- Root downloads/extractions use `mktemp -d` (0700, auto-cleaned) instead of
  predictable `/tmp` paths; installer logs go to a private per-user directory.
- `GIT_TERMINAL_PROMPT=0` so a wrong/private repo URL fails fast instead of
  hanging on a credential prompt.

[1.0.0]: https://example.com/your-repo/releases/tag/v1.0.0
