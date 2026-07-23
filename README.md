# Kali Cyberpunk Setup

**Version 1.0.0** · [Changelog](CHANGELOG.md) · [License](LICENSE)

A two-script post-install kit for Kali Linux that turns a fresh install into a
themed, ready-to-work offensive-security workstation:

- **`kali-ui-setup.sh`** — one-shot desktop/shell customization (cyberpunk dark-teal
  theme, shells, fonts, icons, cursor, GTK theme, panel, editor, keyboard shortcuts).
- **`tool-installer.sh`** — an `fzf`-driven menu that installs and tracks pentest
  tooling under `/opt/tools`, handling the messy reality of PEP 668, `pipx`, `uv`,
  Go modules, and Windows-target binaries.

The two are independent but designed to work together: `kali-ui-setup.sh` deploys
`tool-installer.sh` to `~/.local/bin` and launches it at the end of a run.

---

## Theme

Everything shares one cyberpunk dark-teal palette:

| Role | Hex |
|------|-----|
| Background (deep) | `#0d1a16` |
| Primary teal | `#1F6F6B` |
| Bright teal-green | `#50c896` |
| Muted teal | `#4a9e8a` |
| Soft teal-grey | `#8ab8a8` |
| Red accent | `#cc4444` |
| Amber accent | `#c09060` |

---

## Repository layout

```
.
├── kali-ui-setup.sh      # desktop + shell customization (run as root)
├── tool-installer.sh     # fzf tool installer for /opt/tools
├── wallpaper.png         # optional — applied as desktop wallpaper
├── avatar.png            # optional — applied as login/lock avatar
└── README.md
```

`wallpaper.png` and `avatar.png` are optional. If they are not found next to the
script, the run continues and simply skips the wallpaper/avatar steps.

---

## Requirements

- **OS:** Kali Linux (rolling). Primary target is the **XFCE** desktop; GNOME is
  partially supported (shortcuts and icon/theme names are applied where the GNOME
  path exists).
- **Privileges:** `kali-ui-setup.sh` must run as **root** (`sudo`). It derives the
  real target user from `SUDO_USER`, so it themes *your* account, not root's.
- **Network:** required — packages, fonts, themes, and tools are fetched online.
- **Python:** the tool installer expects Python 3 with `venv`/`pip` (installed by
  the setup script). Kali currently ships Python 3.13.
- Nothing is hardcoded to a specific username. The only fixed paths by design are
  the keyboard-shortcut *mappings* and the `/opt/tools` install root.

---

## Quick start

```bash
# 1. make both scripts executable
chmod +x kali-ui-setup.sh tool-installer.sh

# 2. (optional) drop wallpaper.png and avatar.png next to the scripts

# 3. run the UI setup as root
sudo ./kali-ui-setup.sh

# 4. log out and back in (default shell becomes zsh; theming applies fully)
```

The tool installer can also be run on its own, any time:

```bash
./tool-installer.sh          # or ~/.local/bin/tool-installer.sh after setup
```

---

## `kali-ui-setup.sh`

Run once as root. It is broadly **idempotent** — re-running skips work that is
already done and only re-applies settings.

### What it configures

1. **Assets** — copies `wallpaper.png`/`avatar.png` into place and applies them
   (desktop wallpaper via xfconf on the live session bus; avatar via
   AccountsService so it shows on the login/lock screen).
2. **System packages** — `bash-completion`, `zsh` + autosuggestions +
   syntax-highlighting, `fzf`, `bat`, `eza`, `tmux`, `neovim`, `fastfetch`,
   `xclip`, `xfce4-terminal`, `python3-venv`/`python3-pip`, build tooling, and
   more.
3. **ble.sh** — Fish-style autosuggestions and syntax highlighting for **bash**.
4. **`~/.shell_common`** — shared aliases, environment, and FZF config sourced by
   both bash and zsh.
5. **`~/.bashrc`** — two-line Kali prompt recolored to the palette, full
   `LS_COLORS`/`EZA_COLORS` overrides, guarded aliases, keyboard bindings.
6. **`~/.zshrc`** — Oh My Zsh + Powerlevel10k with matching syntax highlighting.
7. **`~/.p10k.zsh`** — a cyberpunk Powerlevel10k preset.
8. **Fonts** — MesloLGS Nerd Font (plus Cantarell/FiraCode, available but not
   force-applied).
9. **Desktop theming**
   - Icons: **Papirus-Dark**, with folders recolored to **teal** via
     `papirus-folders`.
   - Cursor: **Bibata-Modern-Ice** (fetched from GitHub releases).
   - GTK theme: **Fluent-round-teal-Dark-compact** (built from source).
   - Terminal: solid opaque background, palette-matched colors.
10. **XFCE panel** — a custom `panel-stats.sh` generic-monitor plugin
    (interface / IP / CPU% / RAM%), panel icon-size normalization, and removal of
    the default CPU-graph plugin.
11. **Editor** — `~/.config/nvim/init.lua` with an OSC52 clipboard fix.
12. **Keyboard shortcuts** — registered at the desktop level (see below).
13. **Tool installer** — deploys `tool-installer.sh` to `~/.local/bin` and opens
    it in a new terminal.

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `Alt+B` | Launch Burp Suite (`$HOME/BurpSuitePro/BurpSuite`) |
| `Alt+T` | New terminal |
| `Super+E` | File manager (desktop-level only) |

The Burp path resolves to the running user's home automatically; if Burp is not
installed there, the shortcut simply does nothing.

### Safety notes

- **No DPI / global scale changes.** A previous DPI override caused real damage, so
  the script now deliberately never touches DPI, `Gtk/FontName`, or any GTK-wide
  scale factor. Worst case for the panel icon-size block is a too-large/too-small
  panel row, trivially fixed by editing `PANEL_ICON_SIZE`/`PANEL_ROW_SIZE` and
  re-running.
- **Live-session aware.** Desktop settings are written through the user's real,
  already-running session D-Bus bus so changes apply immediately instead of
  landing on disk unseen.

### After running

Log out and back in. On first zsh launch the Powerlevel10k preset loads
automatically (or run `p10k configure`). Set your terminal font to `MesloLGS NF`.
Newly recolored folders may need a file-manager restart (`thunar -q`, then reopen)
or a re-login to refresh the icon cache.

---

## `tool-installer.sh`

An `fzf` menu for installing and tracking offensive-security tooling. Tools install
under `/opt/tools` (git/binary tools) or into isolated `pipx`/`uv` environments
(CLI tools). It can be run standalone or is launched automatically by the setup
script.

### The menu

- `TAB` to multi-select, `ENTER` to install the selection, `ESC` to quit.
- Each row shows an install-state marker (`[installed]` / `[ - ]`), the install
  **type** in brackets, the tool name, and a short description.
- Three action entries sit at the top: **Add a new tool**, **Download Burp Suite**,
  and the normal tool rows.

After you select tools and press `ENTER`, you are asked **how** to install them:

```
Install method for the selected tool(s):
  1) standard  (pipx for CLI tools, python venv + pip for repos)
  2) uv        (uv tool / uv venv + uv pip -- much faster; installs uv if missing)
Choice [1/2, default 1]:
```

The choice only affects Python-based tools; `apt`, `go`, `winbin`, `rawfile`, and
`special` tools always use their own handler. It resets to `standard` after each
batch.

### Configuration & schema versioning

The tool list lives at:

```
~/.config/kali-tools/tools.conf
```

It is **schema-versioned**. The first line carries a `schema vN` marker. On startup
the installer:

- seeds the bundled default list if no config exists, or
- if the on-disk config predates the current schema version, **backs it up**
  (`tools.conf.bak-<timestamp>`) and regenerates it.

This is what guarantees you always converge on the newest bundled tool list. Any
tools you added by hand are preserved in the `.bak` file for manual re-add after a
schema bump.

### Config format

Pipe-delimited, seven fields, `-` for "not applicable":

```
name|type|check_cmd|apt_pkg|git_url|install_cmd|description
```

| Field | Meaning |
|-------|---------|
| `name` | menu name; also the `/opt/tools/<name>` directory for repo/binary tools |
| `type` | one of the install types below |
| `check_cmd` | binary used to detect an existing install (`-` if none) |
| `apt_pkg` | apt package name (only used by `type=apt`) |
| `git_url` | git repo URL, go module path, or raw-file URL depending on type |
| `install_cmd` | the install step (`pip install ...`, `make`, script, etc.) |
| `description` | short one-line description shown in the menu |

Example:

```
certipy|git+pip|certipy-ad|-|https://github.com/ly4k/Certipy.git|pip install -e .|ADCS enumeration & abuse (ESC1-ESC16)
```

### Install types

| Type | Behavior |
|------|----------|
| `apt` | `sudo apt-get install <apt_pkg>` |
| `pip` | isolated CLI install via **pipx** (or **uv tool** if the uv backend/`--python` pin is used); never touches the system interpreter |
| `git+pip` | clone into `/opt/tools/<name>`, create a `.venv`, run `install_cmd` inside it |
| `git+bash` | clone only, optionally run `install_cmd` directly (no venv) |
| `go` | `go install <module>` (auto-detects Go at `/usr/local/go` if not on PATH) |
| `winbin` | clone source **and** fetch the latest GitHub release binary — for tools meant to run on a Windows target, not on Kali |
| `rawfile` | download a single script directly (with an optional venv for its deps) |
| `special` | bespoke installer dispatched by name (e.g. Sysinternals suite, Eisvogel report template) |

### Adding your own tool

Choose **"+ Add a new tool to this menu"** and answer the prompts. Your entry is
appended to `tools.conf`. Note that a schema bump will regenerate the default list;
your additions are preserved in the timestamped `.bak` so you can re-add them.

### Burp Suite downloader

**"Download Burp Suite"** queries PortSwigger's own release feed, selects the
Stable build matching your **edition** (Community/Professional) and architecture,
and **enforces** integrity: it deletes the download and aborts unless its SHA-256
matches the checksum published on `portswigger.net`. On success it drops the
installer in `~/Downloads`. It is deliberately **download-only** — it never
installs or runs anything.

### Install-state detection

A tool is shown as `[installed]` if any of these hold:

1. its `check_cmd` binary is on `PATH`;
2. `/opt/tools/<name>` exists and is non-empty;
3. a `pipx`/`uv` tool venv named after the tool exists (catches CLI tools whose
   binary name differs, e.g. `corscanner` → `cors`);
4. a known special-installer artifact exists (e.g. the Eisvogel template, the
   Sysinternals directory).

### Bundled tooling

The default list ships **89 tools** across categories including Active Directory /
Windows enumeration and abuse, ADCS, Kerberos, coercion, tunneling and file
transfer, web-application testing, and reporting. By install type:

| Type | Count |
|------|-------|
| `git+pip` | 26 |
| `git+bash` | 13 |
| `apt` | 13 |
| `winbin` | 12 |
| `pip` | 11 |
| `go` | 8 |
| `rawfile` | 4 |
| `special` | 2 |

---

## A note on `uv`

`uv` is a single fast binary (from Astral) that replaces `pip`, `venv`,
`virtualenv`, and `pipx`, and can also manage Python versions:

- `uv tool install <pkg>` — the `pipx` equivalent (isolated CLI apps on PATH).
- `uv venv` / `uv pip install` — a much faster venv + pip.
- `uv python install 3.12` — fetches and manages standalone Python builds.

The installer uses it in two places:

- As an optional, faster backend for a whole selection (the `2) uv` prompt choice).
- **Automatically** for any tool that pins a specific Python version. For example,
  `spraycharles` pins `numpy<2.0`, which has no Python 3.13 wheel; on Kali's 3.13
  that would force a doomed source build. The installer pins it to Python 3.12 and
  routes it through `uv`, which downloads a standalone 3.12 interpreter on demand
  so a prebuilt numpy wheel is used instead. `uv` is installed automatically the
  first time it is needed.

---

## Customization

- **Folder icon color:** edit `FOLDER_COLOR="teal"` in `kali-ui-setup.sh`
  (run `papirus-folders -l` to list available colors).
- **Panel icon size:** `PANEL_ICON_SIZE` / `PANEL_ROW_SIZE` in `kali-ui-setup.sh`.
- **Install root:** `TOOLS_DIR="/opt/tools"` in `tool-installer.sh`.
- **Config location:** `~/.config/kali-tools/tools.conf`.
- **Keyboard shortcuts:** the mappings are intentionally fixed in the shortcut
  section of `kali-ui-setup.sh`; edit them there.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| Menu shows only a handful of tools | Old `tools.conf` on disk. The installer now auto-regenerates on a schema bump; you can also delete `~/.config/kali-tools/tools.conf` and re-run. |
| `externally-managed-environment` on a `pip` install | PEP 668. The `pip` type now installs via `pipx`/`uv`, never the system interpreter. |
| `Go toolchain not found` for `go`-type tools | Go isn't on this shell's PATH. The installer probes `/usr/local/go`; if Go is genuinely absent, re-run `kali-ui-setup.sh` or `sudo apt install golang-go`. |
| `Could not open requirements file: requirements.txt` | Some repos don't ship one. The `git+pip` handler now falls back to `pip install .` (if packaging metadata exists), an alternate `requirements*.txt`, or clone-only. |
| A tool clone prompts for a GitHub username/password | Usually a wrong/private URL. `GIT_TERMINAL_PROMPT=0` makes such clones fail fast instead of hanging. |
| `spraycharles` fails building `numpy` | Python 3.13 has no `numpy<2.0` wheel; it is pinned to 3.12 via `uv` automatically. |
| A pipx/uv tool shows as not installed | Fixed — detection now checks pipx/uv tool venvs and special-installer artifacts, not just PATH. |
| Recolored folders still look blue | The file manager cached old icons. Run `thunar -q` and reopen, or log out/in. |

### Logs

Per-tool install logs are written to a private, per-user directory
(`$XDG_RUNTIME_DIR/kali-tools-<uid>/`, mode 0700, falling back to `$TMPDIR`/`/tmp`)
rather than world-readable `/tmp/*.log`, so other local users can't read your
username or which tools you install. The Burp download, uv, and pipx setup steps
write their logs into the same private directory.

---

## Acknowledgments

This project doesn't bundle any of the tools it sets up — it downloads each one
from its official source at install time. Full credit for those tools goes to
their respective authors and maintainers, and each remains under its own license.
With thanks to the creators of (non-exhaustive): the Papirus icon theme and
`papirus-folders`, the Bibata cursor theme, the Fluent GTK theme, Oh My Zsh,
Powerlevel10k, ble.sh, fastfetch, `pipx`, `uv`, and the many security tools listed
in `tools.conf`.

---

## Disclaimer

This project is provided for **educational purposes and authorized security
testing only**. It must not be used, or modified to be used, for any unlawful or
malicious activity. Use the installed tools **only** against systems you own or
have explicit written permission to test; you alone are responsible for complying
with all applicable laws, regulations, and engagement rules.

The software is provided "as is", without warranty of any kind. The author accepts
no liability for any misuse or for any damage arising from its use. The third-party
tools it downloads are the work and responsibility of their respective authors.

---

## License

The code in this project (the two scripts and this README) is released under the
**MIT License** — see [`LICENSE`](LICENSE). This license covers only the code in
this repository. It does **not** extend to the third-party tools, themes, or fonts
the scripts download, each of which remains under its own separate license.
