#!/usr/bin/env bash
# =============================================================================
# kali-ui-setup.sh — Kali Linux Post-Install UI & Shell Customization
# Project: kali-cyberpunk-setup
# Version: 1.0.0
# Theme:  Cyberpunk / Dark Teal  (#0d1a16 · #50c896 · #cc4444)
#
# What this script does:
#   1.  Install assets  (wallpaper.png, avatar.png)
#   2.  System packages  (zsh, fzf, eza, bat, ble.sh deps, …)
#   3.  Install ble.sh   (bash autosuggestions + syntax highlighting)
#   4.  Write ~/.shell_common  (shared aliases/env/FZF for bash + zsh)
#   5.  Write ~/.bashrc        (Kali PS1 + cyberpunk colours + ble.sh)
#   6.  Write ~/.zshrc         (Oh My Zsh + Powerlevel10k)
#   7.  Write ~/.p10k.zsh      (Powerlevel10k cyberpunk preset)
#   8.  Install Oh My Zsh + plugins + Powerlevel10k
#   9.  Install MesloLGS Nerd Font
#   10. Apply GNOME/XFCE desktop theme  (wallpaper, terminal palette, GTK)
#   11. Register keyboard shortcuts at DE level
#   12. Configure tmux
#   13. Configure fastfetch
#
# Usage:
#   Place wallpaper.png and avatar.png next to this script, then:
#     chmod +x kali-ui-setup.sh
#     sudo ./kali-ui-setup.sh
# =============================================================================

set -euo pipefail

VERSION="1.0.0"

# ─── Script output colours ───────────────────────────────────────────────────
C_RESET='\033[0m'
C_GREEN='\033[38;2;80;200;150m'     # #50c896
C_TEAL='\033[38;2;74;158;138m'      # #4a9e8a
C_RED='\033[38;2;204;68;68m'        # #cc4444
C_GRAY='\033[0;90m'
C_BOLD='\033[1m'

info()    { echo -e "${C_TEAL}[*]${C_RESET} $*"; }
success() { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()    { echo -e "${C_RED}[!]${C_RESET} $*"; }
section() {
    echo -e "\n${C_BOLD}${C_GRAY}────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}${C_TEAL}  $*${C_RESET}"
    echo -e "${C_BOLD}${C_GRAY}────────────────────────────────────────${C_RESET}"
}

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(eval echo "~${TARGET_USER}")
TARGET_UID=$(id -u "${TARGET_USER}")
USER_BUS_SOCK="/run/user/${TARGET_UID}/bus"

# ─── Secure scratch dir ───────────────────────────────────────────────────────
# All temporary downloads/extractions go here rather than predictable
# /tmp/<name> paths. mktemp -d creates a 0700 root-owned directory, which closes
# the symlink/TOCTOU window a local user could otherwise exploit against a
# fixed /tmp path we write to as root. Removed automatically on exit.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kali-ui-setup.XXXXXX")"
chmod 700 "${WORKDIR}"

# Some build steps must run AS THE TARGET USER (e.g. ble.sh, so the resulting
# files aren't root-owned). Those can't write into the 0700 root-owned dir
# above, so they get their own scratch dir owned by that user -- still 0700, so
# it stays private to them.
USER_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kali-ui-setup-user.XXXXXX")"
chown "${TARGET_USER}:${TARGET_USER}" "${USER_WORKDIR}"
chmod 700 "${USER_WORKDIR}"

cleanup() { rm -rf "${WORKDIR}" "${USER_WORKDIR}"; }
trap cleanup EXIT

# ─── as_user: run a command as TARGET_USER against their REAL, already-running
# session D-Bus bus (not a disposable one from `dbus-launch`). This matters:
# dbus-launch spins up a brand-new throwaway session bus that nothing else is
# listening on, so dconf/xfconf writes made through it land on disk but never
# notify the already-running xfdesktop/xfsettingsd/xfce4-panel -- which is why
# wallpaper/avatar/panel changes silently failed to show up. Using the real
# bus at /run/user/<uid>/bus makes changes apply live, same as the GUI would.
# ────────────────────────────────────────────────────────────────────────────
as_user() {
    if [[ -S "${USER_BUS_SOCK}" ]]; then
        sudo -u "${TARGET_USER}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_BUS_SOCK}" \
            DISPLAY="${DISPLAY:-:0}" \
            "$@"
    else
        warn "No active session bus for ${TARGET_USER} at ${USER_BUS_SOCK} -- is ${TARGET_USER} logged into a desktop session right now?"
        warn "Falling back to a throwaway dbus-launch session -- this setting may need a log out/in to take visible effect."
        sudo -u "${TARGET_USER}" DISPLAY="${DISPLAY:-:0}" dbus-launch "$@"
    fi
}

# ─── set_ini_key: idempotently set KEY=VALUE under [SECTION] in a flat INI
# file, creating the section/key if missing, replacing the value if present.
# Needed for apps like qterminal that store settings in a plain .ini file
# rather than dconf/xfconf.
# ────────────────────────────────────────────────────────────────────────────
set_ini_key() {
    local file="$1" section="$2" key="$3" value="$4"
    touch "${file}"
    awk -v section="${section}" -v key="${key}" -v value="${value}" '
        BEGIN { in_section = 0; done = 0 }
        /^\[.*\]$/ {
            if ($0 == "[" section "]") {
                in_section = 1
            } else {
                if (in_section && !done) { print key "=" value; done = 1 }
                in_section = 0
            }
            print; next
        }
        {
            if (in_section && $0 ~ ("^" key "=")) { print key "=" value; done = 1; next }
            print
        }
        END {
            if (!done) {
                if (!in_section) print "[" section "]"
                print key "=" value
            }
        }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

WALLPAPER_SRC="${SCRIPT_DIR}/wallpaper.png"
AVATAR_SRC="${SCRIPT_DIR}/avatar.png"
ASSETS_DIR="${TARGET_HOME}/.local/share/kali-ui-assets"
WALLPAPER_DEST="${ASSETS_DIR}/wallpaper.png"
AVATAR_DEST="${ASSETS_DIR}/avatar.png"

# ─── Privilege check ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    warn "Run as root: sudo ./kali-ui-setup.sh"
    exit 1
fi

# =============================================================================
# 1. ASSETS
# =============================================================================
section "Installing Assets (Wallpaper & Avatar)"

WALLPAPER_APPLIED="no"
AVATAR_APPLIED="no"

if [[ ! -f "${WALLPAPER_SRC}" || ! -f "${AVATAR_SRC}" ]]; then
    echo ""
    echo -e "${C_RED}${C_BOLD}############################################################${C_RESET}"
    echo -e "${C_RED}${C_BOLD}#  wallpaper.png / avatar.png NOT FOUND NEXT TO THIS SCRIPT #${C_RESET}"
    echo -e "${C_RED}${C_BOLD}#  -> wallpaper/avatar will be SKIPPED for this run.        #${C_RESET}"
    echo -e "${C_RED}${C_BOLD}#  Expected at:                                             #${C_RESET}"
    echo -e "${C_RED}${C_BOLD}#    ${WALLPAPER_SRC}${C_RESET}"
    echo -e "${C_RED}${C_BOLD}#    ${AVATAR_SRC}${C_RESET}"
    echo -e "${C_RED}${C_BOLD}############################################################${C_RESET}"
    echo ""
    sleep 2
fi

mkdir -p "${ASSETS_DIR}"
chown "${TARGET_USER}:${TARGET_USER}" "${ASSETS_DIR}"

if [[ -f "${WALLPAPER_SRC}" ]]; then
    cp "${WALLPAPER_SRC}" "${WALLPAPER_DEST}"
    chown "${TARGET_USER}:${TARGET_USER}" "${WALLPAPER_DEST}"
    success "Wallpaper → ${WALLPAPER_DEST}"
    WALLPAPER_APPLIED="copied"
else
    warn "wallpaper.png not found next to script — skipping"
fi

if [[ -f "${AVATAR_SRC}" ]]; then
    cp "${AVATAR_SRC}" "${AVATAR_DEST}"
    chown "${TARGET_USER}:${TARGET_USER}" "${AVATAR_DEST}"
    mkdir -p /var/lib/AccountsService/icons
    cp "${AVATAR_SRC}" "/var/lib/AccountsService/icons/${TARGET_USER}"
    chmod 644 "/var/lib/AccountsService/icons/${TARGET_USER}"
    ACC_CONF="/var/lib/AccountsService/users/${TARGET_USER}"
    mkdir -p /var/lib/AccountsService/users
    if [[ -f "${ACC_CONF}" ]]; then
        sed -i "s|^Icon=.*|Icon=/var/lib/AccountsService/icons/${TARGET_USER}|" \
            "${ACC_CONF}" 2>/dev/null || true
    else
        printf "[User]\nIcon=/var/lib/AccountsService/icons/%s\n" \
            "${TARGET_USER}" > "${ACC_CONF}"
    fi
    # accounts-daemon caches each user's icon in memory at its own startup
    # and does not watch these files for changes -- without a restart it
    # keeps serving the old (or no) icon to every consumer (greeter, lock
    # screen, etc.) regardless of what's on disk now.
    if command -v systemctl &>/dev/null && systemctl is-active --quiet accounts-daemon 2>/dev/null; then
        systemctl restart accounts-daemon 2>/dev/null && success "accounts-daemon restarted -- new avatar will be picked up" \
            || warn "Could not restart accounts-daemon -- avatar may not show until next reboot"
    fi
    success "Avatar installed"
    AVATAR_APPLIED="copied"
else
    warn "avatar.png not found next to script — skipping"
fi

# =============================================================================
# 2. SYSTEM PACKAGES
# =============================================================================
section "System Update & Essential Packages"

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    bash bash-completion \
    zsh zsh-autosuggestions zsh-syntax-highlighting \
    fzf bat eza \
    tmux neovim \
    curl wget git htop \
    fastfetch xclip \
    locales \
    xfce4-terminal \
    python3-venv python3-pip \
    kali-wallpapers-all \
    gnome-tweaks dconf-cli \
    make build-essential       # needed for ble.sh make install

success "Packages installed"

# =============================================================================
# 2b. LOCALE
#
# ~/.shell_common exports LANG/LC_ALL=en_US.UTF-8, but on a minimal Kali
# install that locale is often not generated, producing "setlocale: cannot
# change locale" warnings on every single new terminal. Generate it.
# =============================================================================
section "Generating en_US.UTF-8 locale"

if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || \
        echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen en_US.UTF-8 &>/dev/null
    success "en_US.UTF-8 locale generated"
else
    info "en_US.UTF-8 already generated -- skipping"
fi
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 &>/dev/null || true

# =============================================================================
# 3. BLE.SH  — bash autosuggestions + syntax highlighting
# =============================================================================
section "Installing ble.sh"

BLESH_DIR="${TARGET_HOME}/.local/share/blesh"
if [[ ! -d "${BLESH_DIR}" ]]; then
    info "Cloning ble.sh..."
    sudo -u "${TARGET_USER}" git clone --depth=1 \
        https://github.com/akinomyoga/ble.sh.git ${USER_WORKDIR}/blesh-src
    pushd ${USER_WORKDIR}/blesh-src > /dev/null
    sudo -u "${TARGET_USER}" make install PREFIX="${TARGET_HOME}/.local" 2>/dev/null
    popd > /dev/null
    rm -rf ${USER_WORKDIR}/blesh-src
    success "ble.sh installed to ${BLESH_DIR}"
else
    info "ble.sh already present — skipping"
fi

# =============================================================================
# 4. ~/.shell_common  — shared by bash AND zsh
# =============================================================================
section "Writing ~/.shell_common"

cat > "${TARGET_HOME}/.shell_common" << 'COMMON_EOF'
# =============================================================================
# ~/.shell_common — shared config for bash AND zsh
# Sourced by .bashrc and .zshrc — keep POSIX-safe syntax only
# =============================================================================

# ── Environment ──────────────────────────────────────────────────────────────
export EDITOR="nvim"
export VISUAL="nvim"
export PAGER="less"
export LESS="-R"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Coloured man pages (cyberpunk palette)
export LESS_TERMCAP_mb=$'\E[1;31m'      # begin blink      → red
export LESS_TERMCAP_md=$'\E[1;36m'      # begin bold       → cyan/teal
export LESS_TERMCAP_me=$'\E[0m'
export LESS_TERMCAP_so=$'\E[01;33m'     # reverse video    → amber
export LESS_TERMCAP_se=$'\E[0m'
export LESS_TERMCAP_us=$'\E[1;32m'      # begin underline  → green
export LESS_TERMCAP_ue=$'\E[0m'

# ── Navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias dl='cd ~/Downloads'
alias dt='cd ~/Desktop'
alias notes='cd ~/Documents/notes'
alias pen='cd ~/pentest'
alias tools='cd ~/tools'

# ── File operations (safe defaults) ──────────────────────────────────────────
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -Iv'
alias mkdir='mkdir -pv'

# ── Listing -- eza replaces ls if installed, falls back to ls ─────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --group-directories-first'
    alias ll='eza -la --group-directories-first'
    alias la='eza -la'
    alias lt='eza -la --sort=modified'
    alias l='eza -CF'
    alias tree='eza --tree'
else
    alias ls='ls --color=auto'
    alias ll='ls -la'
    alias la='ls -A'
    alias lt='ls -lat'
    alias l='ls -CF'
fi

# ── Colour output ─────────────────────────────────────────────────────────────
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'

# bat replaces cat only if installed
if command -v bat &>/dev/null; then
    alias cat='bat --style=plain'
fi

# ── Editors / tools -- nvim replaces vim only if installed ───────────────────
if command -v nvim &>/dev/null; then
    alias vim='nvim'
    alias vi='nvim'
fi
alias cls='clear'
alias xo='xdg-open'

# ── System ────────────────────────────────────────────────────────────────────
alias update='sudo apt-get update && sudo apt-get upgrade -y'
alias hosts='sudo ${EDITOR:-nano} /etc/hosts'
alias iface='ip -br addr'
alias ports='ss -tulpn'
alias myip='curl -s https://api.ipify.org && echo'
alias listen='sudo tcpdump -i any -nn'

# ── Tmux ─────────────────────────────────────────────────────────────────────
alias ta='tmux attach -t'
alias tls='tmux list-sessions'
alias tn='tmux new-session -s'

# ── Python ────────────────────────────────────────────────────────────────────
alias py='python3'
alias venv='python3 -m venv .venv && source .venv/bin/activate'

# ── Applications ──────────────────────────────────────────────────────────────
alias burp="$HOME/BurpSuitePro/BurpSuite"

# ── FZF -- cyberpunk teal palette ─────────────────────────────────────────────
export FZF_DEFAULT_OPTS="--color=bg+:#1a2a24,bg:#0d1a16,spinner:#50c896,hl:#cc4444 --color=fg:#8ab8a8,header:#cc4444,info:#4a9e8a,pointer:#50c896 --color=marker:#50c896,fg+:#c8e8d8,prompt:#4a9e8a,hl+:#cc4444 --border=rounded --prompt='> ' --pointer='>' --marker='*' --height=50% --layout=reverse --info=inline"
export FZF_DEFAULT_COMMAND='find . -type f 2>/dev/null'

# ── fastfetch on new terminal  (comment out if unwanted) ─────────────────────
if command -v fastfetch &>/dev/null; then
    fastfetch
fi
COMMON_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.shell_common"
success "~/.shell_common written"

# =============================================================================
# 5. ~/.bashrc
# =============================================================================
section "Writing ~/.bashrc"

cat > "${TARGET_HOME}/.bashrc" << 'BASHRC_EOF'
# =============================================================================
# ~/.bashrc — executed by bash(1) for non-login shells
# Base:   Kali Linux default structure
# Theme:  Cyberpunk / Dark Teal  (#0d1a16 bg · #50c896 green · #cc4444 red)
# Project: kali-cyberpunk-setup
# =============================================================================

# Non-interactive shell: exit early
case $- in
    *i*) ;;
      *) return;;
esac

# ble.sh — load first; provides autosuggestions + syntax highlighting
[[ -f ~/.local/share/blesh/ble.sh ]] && source ~/.local/share/blesh/ble.sh

# =============================================================================
# HISTORY
# =============================================================================
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=50000
HISTFILESIZE=100000
HISTFILE="$HOME/.bash_history"

shopt -s histappend
shopt -s checkwinsize
#shopt -s globstar

# =============================================================================
# CHROOT LABEL  (Kali / Debian standard)
# =============================================================================
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# =============================================================================
# PROMPT — Kali two-line style, cyberpunk teal/red palette
#
# Colour map (from wallpaper image):
#   #50c896  bright teal-green  → prompt brackets, path indicator
#   #4a9e8a  muted teal         → user@host label
#   #8ab8a8  soft teal-grey     → working directory path
#   #cc4444  lantern red        → root user accent
#   #c09060  warm amber         → virtualenv label
# =============================================================================
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes ;;
esac

force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

# START KALI CONFIG VARIABLES
PROMPT_ALTERNATIVE=twoline
NEWLINE_BEFORE_PROMPT=yes
# STOP KALI CONFIG VARIABLES

if [ "$color_prompt" = yes ]; then
    VIRTUAL_ENV_DISABLE_PROMPT=1

    if [ "$EUID" -eq 0 ]; then
        # root — red accent
        prompt_color='\[\033[38;2;204;68;68m\]'        # #cc4444
        info_color='\[\033[1;38;2;204;68;68m\]'         # #cc4444 bold
        # prompt_symbol=💀
    else
        # user — teal-green accent
        prompt_color='\[\033[38;2;80;200;150m\]'        # #50c896
        info_color='\[\033[1;38;2;74;158;138m\]'        # #4a9e8a bold
    fi
    prompt_symbol=@

    venv_color='\[\033[38;2;192;144;96m\]'              # #c09060 amber
    path_color='\[\033[1;38;2;138;184;168m\]'           # #8ab8a8 bold

    case "$PROMPT_ALTERNATIVE" in
        twoline)
            PS1="${prompt_color}"'┌──'"${prompt_color}"'${debian_chroot:+($debian_chroot)──}'"${venv_color}"'${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))'"${prompt_color}"'}('"${info_color}"'\u'"${prompt_symbol}"'\h'"${prompt_color}"')-['"${path_color}"'\w'"${prompt_color}"']'$'\n'"${prompt_color}"'└─'"${info_color}"'\$\[\033[0m\] '
            ;;
        oneline)
            PS1='${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV)) }${debian_chroot:+($debian_chroot)}'"${info_color}"'\u@\h\[\033[0m\]:'"${prompt_color}"'\[\033[1m\]\w\[\033[0m\]\$ '
            ;;
        backtrack)
            PS1='${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV)) }${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
            ;;
    esac

    unset prompt_color info_color venv_color path_color prompt_symbol
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi

unset color_prompt force_color_prompt

case "$TERM" in
    xterm*|rxvt*|Eterm|aterm|kterm|gnome*|alacritty)
        PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
        ;;
esac

[ "$NEWLINE_BEFORE_PROMPT" = yes ] && PROMPT_COMMAND="PROMPT_COMMAND=echo"

# =============================================================================
# LS_COLORS / DIRCOLORS
# =============================================================================
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    LS_COLORS_OVERRIDE=""
    LS_COLORS_OVERRIDE+="di=1;38;2;80;200;150:"
    LS_COLORS_OVERRIDE+="ex=38;2;80;200;150:"
    LS_COLORS_OVERRIDE+="ln=38;2;74;158;138:"
    LS_COLORS_OVERRIDE+="or=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="mi=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="pi=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="so=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="bd=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="cd=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="su=1;38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="sg=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="ow=30;44:"
    LS_COLORS_OVERRIDE+="tw=30;44:"
    LS_COLORS_OVERRIDE+="*.tar=38;2;204;68;68:*.tgz=38;2;204;68;68:*.gz=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.bz2=38;2;204;68;68:*.xz=38;2;204;68;68:*.zip=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.rar=38;2;204;68;68:*.7z=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.png=38;2;192;144;96:*.jpg=38;2;192;144;96:*.jpeg=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.gif=38;2;192;144;96:*.svg=38;2;192;144;96:*.mp4=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.mkv=38;2;192;144;96:*.mp3=38;2;192;144;96:*.wav=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.pdf=38;2;138;184;168:*.md=38;2;138;184;168:*.txt=38;2;138;184;168:"
    LS_COLORS_OVERRIDE+="*.json=38;2;138;184;168:*.xml=38;2;138;184;168:*.yaml=38;2;138;184;168:"
    LS_COLORS_OVERRIDE+="*.yml=38;2;138;184;168:*.conf=38;2;138;184;168:*.cfg=38;2;138;184;168:"
    export LS_COLORS="${LS_COLORS}${LS_COLORS_OVERRIDE}"
    unset LS_COLORS_OVERRIDE
fi

# =============================================================================
# EZA_COLORS -- "d" type char stays blue (eza built-in, not overridable)
# =============================================================================
EZA_COLORS=""
EZA_COLORS+="ur=38;2;80;200;150:uw=38;2;192;144;96:ux=1;38;2;80;200;150:ue=1;38;2;80;200;150:"
EZA_COLORS+="gr=38;2;74;158;138:gw=38;2;192;144;96:gx=38;2;74;158;138:"
EZA_COLORS+="tr=38;2;74;158;138:tw=38;2;192;144;96:tx=38;2;74;158;138:"
EZA_COLORS+="su=38;2;204;68;68:sf=38;2;204;68;68:xa=38;2;74;158;138:"
EZA_COLORS+="sn=38;2;80;200;150:sb=38;2;74;158;138:"
EZA_COLORS+="nb=38;2;85;85;85:nk=38;2;80;200;150:nm=38;2;80;200;150:ng=38;2;192;144;96:nt=38;2;204;68;68:"
EZA_COLORS+="uu=38;2;80;200;150:un=38;2;204;68;68:gu=38;2;74;158;138:gn=38;2;204;68;68:"
EZA_COLORS+="da=38;2;85;100;95:lc=38;2;74;158;138:lp=38;2;74;158;138:hd=38;2;85;100;95:"
EZA_COLORS+="di=1;38;2;80;200;150:ex=38;2;80;200;150:ln=38;2;74;158;138:or=38;2;204;68;68:"
export EZA_COLORS

# =============================================================================
# SHARED CONFIG -- aliases, env, FZF, fastfetch
# =============================================================================
[[ -f ~/.shell_common ]] && source ~/.shell_common

alias reload='source ~/.bashrc'
alias bashrc='nvim ~/.bashrc'

# =============================================================================
# FZF KEYBINDINGS
# =============================================================================
[[ -f /usr/share/doc/fzf/examples/key-bindings.bash ]] && \
    source /usr/share/doc/fzf/examples/key-bindings.bash
[[ -f /usr/share/doc/fzf/examples/completion.bash ]] && \
    source /usr/share/doc/fzf/examples/completion.bash

# =============================================================================
# BASH COMPLETIONS
# =============================================================================
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# =============================================================================
# KEYBOARD SHORTCUTS  (terminal-scope)
#   Alt+B  -- Burp Suite Pro
#   Alt+T  -- new terminal  (also registered globally by kali-ui-setup.sh)
#   Super+E -- file manager  (DE-level only, not bindable inside bash)
# =============================================================================
if [[ $- == *i* ]]; then
    bind -x '"\eb": "$HOME/BurpSuitePro/BurpSuite &>/dev/null &"'
    bind -x '"\et": "x-terminal-emulator &>/dev/null &"'
fi

# =============================================================================
# BLE.SH  -- syntax-highlight + autosuggestion colours
#
# NOTE: "blerc" is not a real ble.sh hook point -- blehook/eval-after-load
# only fires for hooks ble.sh actually defines (e.g. "complete", "keymap_vi"),
# so registering against "blerc" produced the "hook blerc_load is not
# defined" warning and never ran. ble.sh is already fully attached by the
# time this file reaches this point (it was sourced at the top, and this
# runs after), so the ble-face calls can just run directly -- no hook needed.
# =============================================================================
if [[ ${BLE_VERSION-} ]]; then
    bleopt complete_auto_complete=1
    bleopt complete_auto_delay=50

    ble-face -s syntax_command             fg=#50c896,bold
    ble-face -s command_alias              fg=#50c896
    ble-face -s command_function           fg=#4a9e8a
    ble-face -s command_keyword            fg=#4a9e8a
    ble-face -s filename_directory         fg=#8ab8a8,underline
    ble-face -s syntax_error               fg=#cc4444,bold
    ble-face -s syntax_glob                fg=#c09060
    ble-face -s syntax_quoted              fg=#b8956a
    ble-face -s syntax_quotation           fg=#b8956a
    ble-face -s syntax_comment             fg=#555555
    ble-face -s auto_complete              fg=#4a9e8a
fi

# =============================================================================
# EXTERNAL ALIASES FILE
# =============================================================================
[[ -f ~/.bash_aliases ]] && source ~/.bash_aliases

# =============================================================================
# GO LANGUAGE
# =============================================================================
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# =============================================================================
# BLE.SH ATTACH — must be the very last line
#
# fastfetch (run earlier in ~/.shell_common) queries the terminal for things
# like its color scheme via OSC/CPR escape sequences. If the terminal's reply
# arrives after ble-attach starts reading input, ble.sh treats the raw reply
# bytes as if you'd typed them -- that's the ">0;115;0c2;1R3;1R" style
# garbage showing up next to the prompt. Draining any bytes that are already
# sitting in the input buffer right before attaching avoids that.
# =============================================================================
if [[ ${BLE_VERSION-} ]]; then
    while read -r -t 0.05 -n 4096 _ble_stray_input 2>/dev/null; do :; done
    ble-attach
fi
BASHRC_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.bashrc"
success "~/.bashrc written"

# =============================================================================
# 6. ~/.zshrc
# =============================================================================
section "Writing ~/.zshrc"

cat > "${TARGET_HOME}/.zshrc" << 'ZSHRC_EOF'
# =============================================================================
# ~/.zshrc -- Kali ZSH configuration
# Theme:  Cyberpunk / Dark Teal  (#0d1a16 · #50c896 · #cc4444)
# Project: kali-cyberpunk-setup
# =============================================================================

# Powerlevel10k instant prompt -- keep near the very top
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# =============================================================================
# OH MY ZSH
# =============================================================================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    fzf-tab
    sudo
    history
    colored-man-pages
    command-not-found
    extract
    z
)

source "$ZSH/oh-my-zsh.sh"

# =============================================================================
# HISTORY
# =============================================================================
HISTSIZE=50000
SAVEHIST=50000
HISTFILE="$HOME/.zsh_history"
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY

# =============================================================================
# LS_COLORS / DIRCOLORS
# =============================================================================
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    LS_COLORS_OVERRIDE=""
    LS_COLORS_OVERRIDE+="di=1;38;2;80;200;150:"
    LS_COLORS_OVERRIDE+="ex=38;2;80;200;150:"
    LS_COLORS_OVERRIDE+="ln=38;2;74;158;138:"
    LS_COLORS_OVERRIDE+="or=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="mi=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="pi=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="so=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="bd=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="cd=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="su=1;38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="sg=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="ow=30;44:"
    LS_COLORS_OVERRIDE+="tw=30;44:"
    LS_COLORS_OVERRIDE+="*.tar=38;2;204;68;68:*.tgz=38;2;204;68;68:*.gz=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.bz2=38;2;204;68;68:*.xz=38;2;204;68;68:*.zip=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.rar=38;2;204;68;68:*.7z=38;2;204;68;68:"
    LS_COLORS_OVERRIDE+="*.png=38;2;192;144;96:*.jpg=38;2;192;144;96:*.jpeg=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.gif=38;2;192;144;96:*.svg=38;2;192;144;96:*.mp4=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.mkv=38;2;192;144;96:*.mp3=38;2;192;144;96:*.wav=38;2;192;144;96:"
    LS_COLORS_OVERRIDE+="*.pdf=38;2;138;184;168:*.md=38;2;138;184;168:*.txt=38;2;138;184;168:"
    LS_COLORS_OVERRIDE+="*.json=38;2;138;184;168:*.xml=38;2;138;184;168:*.yaml=38;2;138;184;168:"
    LS_COLORS_OVERRIDE+="*.yml=38;2;138;184;168:*.conf=38;2;138;184;168:*.cfg=38;2;138;184;168:"
    export LS_COLORS="${LS_COLORS}${LS_COLORS_OVERRIDE}"
    unset LS_COLORS_OVERRIDE
fi

# =============================================================================
# EZA_COLORS -- "d" type char stays blue (eza built-in, not overridable)
# =============================================================================
EZA_COLORS=""
EZA_COLORS+="ur=38;2;80;200;150:uw=38;2;192;144;96:ux=1;38;2;80;200;150:ue=1;38;2;80;200;150:"
EZA_COLORS+="gr=38;2;74;158;138:gw=38;2;192;144;96:gx=38;2;74;158;138:"
EZA_COLORS+="tr=38;2;74;158;138:tw=38;2;192;144;96:tx=38;2;74;158;138:"
EZA_COLORS+="su=38;2;204;68;68:sf=38;2;204;68;68:xa=38;2;74;158;138:"
EZA_COLORS+="sn=38;2;80;200;150:sb=38;2;74;158;138:"
EZA_COLORS+="nb=38;2;85;85;85:nk=38;2;80;200;150:nm=38;2;80;200;150:ng=38;2;192;144;96:nt=38;2;204;68;68:"
EZA_COLORS+="uu=38;2;80;200;150:un=38;2;204;68;68:gu=38;2;74;158;138:gn=38;2;204;68;68:"
EZA_COLORS+="da=38;2;85;100;95:lc=38;2;74;158;138:lp=38;2;74;158;138:hd=38;2;85;100;95:"
EZA_COLORS+="di=1;38;2;80;200;150:ex=38;2;80;200;150:ln=38;2;74;158;138:or=38;2;204;68;68:"
export EZA_COLORS

# =============================================================================
# SHARED CONFIG -- aliases, env, FZF, fastfetch
# =============================================================================
[[ -f ~/.shell_common ]] && source ~/.shell_common

alias reload='source ~/.zshrc'
alias zshrc='nvim ~/.zshrc'

# =============================================================================
# FZF KEYBINDINGS  (Ctrl+R, Ctrl+T, Alt+C)
# =============================================================================
[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && \
    source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && \
    source /usr/share/doc/fzf/examples/completion.zsh

# =============================================================================
# AUTOSUGGESTIONS -- muted teal ghost text
# =============================================================================
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#4a9e8a"
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=30

# =============================================================================
# SYNTAX HIGHLIGHTING -- cyberpunk palette
# =============================================================================
ZSH_HIGHLIGHT_STYLES[command]='fg=#50c896,bold'
ZSH_HIGHLIGHT_STYLES[alias]='fg=#50c896'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=#4a9e8a'
ZSH_HIGHLIGHT_STYLES[function]='fg=#4a9e8a'
ZSH_HIGHLIGHT_STYLES[path]='fg=#8ab8a8,underline'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=#cc4444,bold'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=#c09060'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=#b8956a'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=#b8956a'
ZSH_HIGHLIGHT_STYLES[comment]='fg=#555555'

# =============================================================================
# KEYBOARD SHORTCUTS
#   Alt+B  -- Burp Suite Pro
#   Alt+T  -- new terminal  (also registered globally by kali-ui-setup.sh)
#   Super+E -- file manager  (DE-level only)
# =============================================================================
bindkey -s '\eb' '"$HOME/BurpSuitePro/BurpSuite" &>/dev/null &\n'
bindkey -s '\et' 'x-terminal-emulator &>/dev/null &\n'

# =============================================================================
# GO LANGUAGE
# =============================================================================
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# =============================================================================
# POWERLEVEL10K -- load preset last
# Run: p10k configure  to regenerate interactively
# =============================================================================
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHRC_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.zshrc"
success "~/.zshrc written"

# =============================================================================
# 7. ~/.p10k.zsh — Powerlevel10k cyberpunk preset
# =============================================================================
section "Writing ~/.p10k.zsh"

cat > "${TARGET_HOME}/.p10k.zsh" << 'P10K_EOF'
# Powerlevel10k config — cyberpunk teal/green palette
# Run `p10k configure` to regenerate interactively

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  autoload -Uz is-at-least && is-at-least 5.1 || return

  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
      status command_execution_time background_jobs virtualenv context time)

  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_ICON_PADDING=moderate

  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_FOREGROUND=76      # green
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_FOREGROUND=160  # red
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION=' '
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION=' '

  typeset -g POWERLEVEL9K_DIR_FOREGROUND=73                       # teal
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=66
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=80
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=true
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3

  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=178
  typeset -g POWERLEVEL9K_VCS_CONFLICTED_FOREGROUND=196
  typeset -g POWERLEVEL9K_VCS_LOADING_FOREGROUND=244

  typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'

  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_ERROR_CONTENT_EXPANSION='✘ $P9K_STATUS'

  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101

  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose

  typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_RIGHT_SEGMENT_SEPARATOR=''
  typeset -g POWERLEVEL9K_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=''
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL=''
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  builtin setopt "${p10k_config_opts[@]}"
}
P10K_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.p10k.zsh"
success "~/.p10k.zsh written"

# =============================================================================
# 8. OH MY ZSH + PLUGINS + POWERLEVEL10K
# =============================================================================
section "Installing Oh My Zsh, Plugins & Powerlevel10k"

chsh -s "$(which bash)" "${TARGET_USER}"
success "Default shell set to bash"

if [[ ! -d "${TARGET_HOME}/.oh-my-zsh" ]]; then
    sudo -u "${TARGET_USER}" env HOME="${TARGET_HOME}" \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended
    success "Oh My Zsh installed"
else
    info "Oh My Zsh already present"
fi

ZSH_CUSTOM="${TARGET_HOME}/.oh-my-zsh/custom"

for PLUGIN_ENTRY in \
    "https://github.com/zsh-users/zsh-autosuggestions|zsh-autosuggestions" \
    "https://github.com/zsh-users/zsh-syntax-highlighting|zsh-syntax-highlighting" \
    "https://github.com/Aloxaf/fzf-tab|fzf-tab"
do
    REPO_URL="${PLUGIN_ENTRY%%|*}"
    PLUGIN_NAME="${PLUGIN_ENTRY##*|}"
    if [[ ! -d "${ZSH_CUSTOM}/plugins/${PLUGIN_NAME}" ]]; then
        sudo -u "${TARGET_USER}" git clone --depth=1 \
            "${REPO_URL}" "${ZSH_CUSTOM}/plugins/${PLUGIN_NAME}"
        success "Plugin: ${PLUGIN_NAME}"
    else
        info "Plugin already present: ${PLUGIN_NAME}"
    fi
done

if [[ ! -d "${ZSH_CUSTOM}/themes/powerlevel10k" ]]; then
    sudo -u "${TARGET_USER}" git clone --depth=1 \
        https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM}/themes/powerlevel10k"
    success "Powerlevel10k installed"
else
    info "Powerlevel10k already present"
fi

# p10k is a zsh FUNCTION (sourced from the theme, not a real executable), so
# `p10k configure` only exists once you're actually inside an interactive
# zsh session with .zshrc loaded -- running it from bash (e.g. right after
# this script, before logging out) fails with "command not found". This
# wrapper makes `p10k <anything>` work from any shell by launching an
# interactive zsh just long enough to run the real p10k function.
cat > /usr/local/bin/p10k << 'P10K_WRAPPER_EOF'
#!/usr/bin/env bash
exec zsh -ic "p10k $*"
P10K_WRAPPER_EOF
chmod +x /usr/local/bin/p10k
success "/usr/local/bin/p10k wrapper installed -- 'p10k configure' now works from bash too"

# =============================================================================
# 9. MESLO LGS NERD FONT
# =============================================================================
section "Installing MesloLGS Nerd Font"

FONT_DIR="/usr/local/share/fonts/MesloLGS"
mkdir -p "${FONT_DIR}"
FONT_BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"

for FONT_FILE in \
    "MesloLGS NF Regular.ttf" \
    "MesloLGS NF Bold.ttf" \
    "MesloLGS NF Italic.ttf" \
    "MesloLGS NF Bold Italic.ttf"
do
    DEST="${FONT_DIR}/${FONT_FILE}"
    if [[ ! -f "${DEST}" ]]; then
        wget -q "${FONT_BASE}/${FONT_FILE// /%20}" -O "${DEST}"
        info "Downloaded: ${FONT_FILE}"
    fi
done

fc-cache -fv > /dev/null 2>&1
success "MesloLGS Nerd Font installed & cache refreshed"

# =============================================================================
# 9b. GO LANGUAGE
#
# .bashrc/.zshrc already export GOROOT=/usr/local/go and GOPATH=$HOME/go, but
# nothing actually installed the toolchain itself -- any `go install ...`
# (used by several entries in the tool-installer menu: chisel, nuclei,
# goshs, kerbrute, gowitness, httpx, ligolo-ng's proxy) would silently fail
# without this.
# =============================================================================
section "Installing Go"

GO_ARCH="amd64"
[[ "$(uname -m)" == "aarch64" ]] && GO_ARCH="arm64"

if command -v go &>/dev/null && [[ -d /usr/local/go ]]; then
    info "Go already installed: $(go version)"
else
    info "Fetching latest Go release version..."
    GO_LATEST=$(curl -fsSL "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
    if [[ -z "${GO_LATEST}" ]]; then
        warn "Could not determine the latest Go version -- skipping Go install"
        warn "Install manually from https://go.dev/dl/ if needed"
    else
        GO_TARBALL="${GO_LATEST}.linux-${GO_ARCH}.tar.gz"
        info "Downloading ${GO_TARBALL}..."
        if curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "${WORKDIR}/${GO_TARBALL}"; then
            rm -rf /usr/local/go
            tar -C /usr/local -xzf "${WORKDIR}/${GO_TARBALL}"
            rm -f "${WORKDIR}/${GO_TARBALL}"
            chown -R "${TARGET_USER}:${TARGET_USER}" /usr/local/go 2>/dev/null || true
            mkdir -p "${TARGET_HOME}/go"
            chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/go"
            success "Go installed to /usr/local/go ($(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}'))"
        else
            warn "Failed to download Go tarball -- skipping"
        fi
    fi
fi

# =============================================================================
# 10. DESKTOP THEMING  (GNOME / XFCE)
# =============================================================================
section "Desktop Theming"

# ── Terminal palette — 16-colour cyberpunk set ────────────────────────────────
# Colour index map:
#  0  #0d1a16  bg black          8   #1e3830  bright black (dark teal)
#  1  #cc4444  red (lanterns)    9   #e05555  bright red
#  2  #50c896  green (teal glow) 10  #50c896  bright green
#  3  #c09060  amber/yellow      11  #d4aa70  bright amber
#  4  #2d7a9a  blue (neon sign)  12  #3a9abf  bright blue
#  5  #8c50a0  purple            13  #aa64c8  bright purple
#  6  #4a9e8a  cyan/teal         14  #40b8a8  bright cyan
#  7  #8ab8a8  white (fg grey)   15  #c8e8d8  bright white
TERM_PALETTE="['rgb(13,26,22)', 'rgb(204,68,68)', 'rgb(80,200,150)', 'rgb(192,144,96)', 'rgb(45,122,154)', 'rgb(140,80,160)', 'rgb(74,158,138)', 'rgb(138,184,168)', 'rgb(30,56,48)', 'rgb(224,85,85)', 'rgb(80,200,150)', 'rgb(212,170,112)', 'rgb(58,154,191)', 'rgb(170,100,200)', 'rgb(64,184,168)', 'rgb(200,232,216)']"

apply_gnome_theme() {
    info "Applying GNOME settings..."

    # Wallpaper
    as_user dconf write \
        /org/gnome/desktop/background/picture-uri \
        "'file://${WALLPAPER_DEST}'" 2>/dev/null || true
    as_user dconf write \
        /org/gnome/desktop/background/picture-uri-dark \
        "'file://${WALLPAPER_DEST}'" 2>/dev/null || true
    as_user dconf write \
        /org/gnome/desktop/background/picture-options \
        "'zoom'" 2>/dev/null || true

    # Dark mode + Kali GTK theme
    as_user dconf write \
        /org/gnome/desktop/interface/color-scheme \
        "'prefer-dark'" 2>/dev/null || true
    as_user dconf write \
        /org/gnome/desktop/interface/gtk-theme \
        "'Kali-Dark'" 2>/dev/null || true

    # GNOME Terminal profile — cyberpunk palette
    PROFILE_ID="b1dcc9dd-5262-4d8d-a863-c897e6d979b9"
    PP="/org/gnome/terminal/legacy/profiles:/:${PROFILE_ID}"

    as_user dconf write \
        /org/gnome/terminal/legacy/profiles:/default \
        "'${PROFILE_ID}'" 2>/dev/null || true

    as_user dconf write "${PP}/visible-name"               "'Cyberpunk'"           2>/dev/null || true
    as_user dconf write "${PP}/use-theme-colors"           "false"                 2>/dev/null || true
    as_user dconf write "${PP}/background-color"           "'rgb(13,26,22)'"       2>/dev/null || true
    as_user dconf write "${PP}/foreground-color"           "'rgb(138,184,168)'"    2>/dev/null || true
    as_user dconf write "${PP}/palette"                    "${TERM_PALETTE}"       2>/dev/null || true
    as_user dconf write "${PP}/bold-color-same-as-fg"      "true"                  2>/dev/null || true
    as_user dconf write "${PP}/use-transparent-background" "true"                  2>/dev/null || true
    as_user dconf write "${PP}/background-transparency-percent" "8"               2>/dev/null || true
    as_user dconf write "${PP}/font"                       "'MesloLGS NF 11'"      2>/dev/null || true
    as_user dconf write "${PP}/use-system-font"            "false"                 2>/dev/null || true
    as_user dconf write "${PP}/scrollbar-policy"           "'never'"               2>/dev/null || true

    success "GNOME theme applied"
}

apply_xfce_theme() {
    info "Applying XFCE settings..."
    if ! command -v xfconf-query &>/dev/null; then
        warn "xfconf-query not found -- set wallpaper manually"
        return 1
    fi
    if [[ ! -f "${WALLPAPER_DEST}" ]]; then
        warn "No wallpaper installed (place wallpaper.png next to the script) -- skipping"
        return 1
    fi
    if ! as_user xfconf-query -c xfce4-desktop -l &>/dev/null; then
        warn "Could not reach xfconfd for ${TARGET_USER} (no active Xfce session?) -- wallpaper not applied"
        warn "Re-run this script while logged into Xfce, or set it manually: Right-click desktop -> Desktop Settings"
        return 1
    fi

    # The property path encodes the actual monitor/workspace names in use
    # (monitorVirtual1, monitor0, workspace0, per-workspace mode, ...), which
    # varies per machine -- so enumerate every real last-image/image-path
    # property instead of guessing a single hardcoded path.
    APPLIED=0
    while IFS= read -r PROP; do
        [[ -z "${PROP}" ]] && continue
        if as_user xfconf-query -c xfce4-desktop -p "${PROP}" -s "${WALLPAPER_DEST}" 2>/dev/null; then
            APPLIED=$((APPLIED + 1))
        fi
        # Each last-image/image-path property has a sibling "image-style" in
        # the same directory (0=None, 1=Centered, 2=Tiled, 3=Stretched,
        # 4=Scaled, 5=Zoomed). If that's 0 (or the display mode is set to a
        # solid color instead of an image), the path can be perfectly correct
        # and nothing will ever visibly render. Force it to Zoomed.
        STYLE_PROP="${PROP%/*}/image-style"
        as_user xfconf-query -c xfce4-desktop -p "${STYLE_PROP}" -s 5 2>/dev/null || \
            as_user xfconf-query -c xfce4-desktop -p "${STYLE_PROP}" -n -t int -s 5 2>/dev/null || true
    done < <(as_user xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/(last-image|image-path)$')

    if [[ ${APPLIED} -gt 0 ]]; then
        success "XFCE wallpaper applied to ${APPLIED} monitor/workspace propert$([[ ${APPLIED} -eq 1 ]] && echo y || echo ies) (style forced to Zoomed)"
        WALLPAPER_APPLIED="live on desktop"

        # Sanity-check the file itself -- a 0-byte or unrecognized file would
        # explain a "correct" path rendering nothing.
        if command -v file &>/dev/null; then
            FILETYPE=$(file -b "${WALLPAPER_DEST}" 2>/dev/null)
            if [[ "${FILETYPE}" != *"image"* ]]; then
                warn "wallpaper.png doesn't look like a valid image to 'file': ${FILETYPE}"
            fi
        fi

        # NOTE: deliberately NOT restarting/quitting xfdesktop here. Confirmed
        # the hard way that `xfdesktop --quit` + relaunch can wipe the entire
        # /backdrop property tree instead of reloading it, which is worse
        # than doing nothing. A plain xfconf property write on an EXISTING
        # property tree notifies the running xfdesktop instance correctly on
        # its own -- no external nudge needed or wanted.
    else
        warn "No /backdrop properties exist yet on this system -- xfdesktop only creates them the first time"
        warn "you set a wallpaper through its own GUI (right-click desktop -> Desktop Settings)."
        warn "Do that once manually, then re-run this script -- from then on it'll maintain it safely."
        return 1
    fi
}

apply_xfce_terminal_theme() {
    if ! command -v xfce4-terminal &>/dev/null; then
        info "xfce4-terminal not installed -- skipping terminal theming"
        return 0
    fi

    # xfce4-terminal does NOT use xfconf/dconf for its color scheme -- it
    # reads a flat ini-style file at ~/.config/xfce4/terminal/terminalrc.
    # That's why nothing here got themed before: the GNOME Terminal dconf
    # writes above simply don't apply to this terminal at all.
    TERM_CONF_DIR="${TARGET_HOME}/.config/xfce4/terminal"
    mkdir -p "${TERM_CONF_DIR}"

    cat > "${TERM_CONF_DIR}/terminalrc" << 'XFTERM_EOF'
[Configuration]
FontName=MesloLGS NF 11
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=FALSE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=110x30
MiscInheritGeometry=FALSE
MiscMenubarDefault=TRUE
MiscMouseAutohide=FALSE
MiscMouseWheelZoom=TRUE
MiscToolbarDefault=FALSE
MiscConfirmClose=TRUE
MiscCycleTabs=TRUE
MiscTabCloseButtons=TRUE
MiscTabCloseMiddleClick=TRUE
MiscTabPosition=GTK_POS_TOP
MiscHighlightUrls=TRUE
MiscMiddleClickOpensUri=FALSE
MiscCopyOnSelect=FALSE
MiscShowRelaunchDialog=TRUE
MiscRewrapOnResize=TRUE
MiscUseShiftArrowsToScroll=FALSE
MiscSlimTabs=FALSE
MiscNewTabAdjacent=FALSE
ColorForeground=#8ab8a8
ColorBackground=#23252E
ColorCursor=#50c896
ColorCursorUseDefault=FALSE
ColorBold=#50c896
ColorBoldUseDefault=FALSE
ColorSelectionUseDefault=TRUE
ColorPalette=#0d1a16;#cc4444;#50c896;#c09060;#2d7a9a;#8c50a0;#4a9e8a;#8ab8a8;#1e3830;#e05555;#50c896;#d4aa70;#3a9abf;#aa64c8;#40b8a8;#c8e8d8
BackgroundMode=TERMINAL_BACKGROUND_SOLID
TabActivityColor=#50c896
ColorUseTheme=FALSE
FontUseSystem=FALSE
ScrollingUnlimited=TRUE
ScrollingLines=50000
ScrollingOnOutput=FALSE
XFTERM_EOF

    chown -R "${TARGET_USER}:${TARGET_USER}" "${TERM_CONF_DIR}"
    success "~/.config/xfce4/terminal/terminalrc written -- solid cyberpunk background, no transparency"
}

apply_qterminal_theme() {
    if ! command -v qterminal &>/dev/null; then
        info "qterminal not installed -- skipping"
        return 0
    fi

    # qterminal (LXQt's terminal, used here instead of xfce4-terminal) does
    # NOT use xfconf/dconf either -- it stores window/opacity settings in
    # ~/.config/qterminal.org/qterminal.ini, and the actual color palette in
    # a separate .colorscheme file under ~/.local/share/qterminal/color-schemes/
    # (the older ~/.config/qterminal.org/color-schemes/ path is deprecated).
    QT_SCHEME_DIR="${TARGET_HOME}/.local/share/qterminal/color-schemes"
    mkdir -p "${QT_SCHEME_DIR}"

    cat > "${QT_SCHEME_DIR}/Cyberpunk.colorscheme" << 'QTCS_EOF'
[General]
Description=Cyberpunk Teal
Opacity=1

[Background]
Bold=false
Color=35,37,46
Transparency=false

[BackgroundIntense]
Bold=false
Color=35,37,46
Transparency=false

[Foreground]
Bold=false
Color=138,184,168
Transparency=false

[ForegroundIntense]
Bold=true
Color=200,232,216
Transparency=false

[Color0]
Bold=false
Color=35,37,46
Transparency=false
[Color0Intense]
Bold=false
Color=30,56,48
Transparency=false

[Color1]
Bold=false
Color=204,68,68
Transparency=false
[Color1Intense]
Bold=false
Color=224,85,85
Transparency=false

[Color2]
Bold=false
Color=80,200,150
Transparency=false
[Color2Intense]
Bold=false
Color=80,200,150
Transparency=false

[Color3]
Bold=false
Color=192,144,96
Transparency=false
[Color3Intense]
Bold=false
Color=212,170,112
Transparency=false

[Color4]
Bold=false
Color=45,122,154
Transparency=false
[Color4Intense]
Bold=false
Color=58,154,191
Transparency=false

[Color5]
Bold=false
Color=140,80,160
Transparency=false
[Color5Intense]
Bold=false
Color=170,100,200
Transparency=false

[Color6]
Bold=false
Color=74,158,138
Transparency=false
[Color6Intense]
Bold=false
Color=64,184,168
Transparency=false

[Color7]
Bold=false
Color=138,184,168
Transparency=false
[Color7Intense]
Bold=false
Color=200,232,216
Transparency=false
QTCS_EOF

    QT_CONF_DIR="${TARGET_HOME}/.config/qterminal.org"
    QT_INI="${QT_CONF_DIR}/qterminal.ini"
    mkdir -p "${QT_CONF_DIR}"

    # termOpacity/appOpacity: confirmed via upstream qterminal issue #163
    # (github.com/lxqt/qterminal/issues/163) these are TRANSPARENCY
    # percentages, not opacity -- "both default to 0% == opaque". The
    # previous value of 100 here was therefore backwards: it set MAXIMUM
    # transparency instead of removing it. 0 = fully solid.
    set_ini_key "${QT_INI}" "General"    "colorScheme" "Cyberpunk"
    set_ini_key "${QT_INI}" "General"    "termOpacity" "0"
    set_ini_key "${QT_INI}" "MainWindow" "appOpacity"  "0"

    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.local/share/qterminal" "${QT_CONF_DIR}"
    # Defensive second layer: xfwm4's own compositor can also apply opacity
    # to windows independent of what the app itself requests. Unlike
    # qterminal's inverted "Opacity" fields, xfwm4 uses normal semantics here
    # (higher = more opaque), so force these to fully opaque too.
    as_user xfconf-query -c xfwm4 -p /general/inactive_opacity -s 100 2>/dev/null || \
        as_user xfconf-query -c xfwm4 -p /general/inactive_opacity -n -t int -s 100 2>/dev/null || true
    as_user xfconf-query -c xfwm4 -p /general/popup_opacity -s 100 2>/dev/null || \
        as_user xfconf-query -c xfwm4 -p /general/popup_opacity -n -t int -s 100 2>/dev/null || true
    as_user xfconf-query -c xfwm4 -p /general/frame_opacity -s 100 2>/dev/null || \
        as_user xfconf-query -c xfwm4 -p /general/frame_opacity -n -t int -s 100 2>/dev/null || true

    success "qterminal: Cyberpunk color scheme written, transparency forced to 0% (solid)"

    # qterminal runs as a single-instance app (new windows are new tabs in
    # the same process), so closing a window does NOT make it re-read
    # qterminal.ini -- the process needs to fully exit first. We do NOT kill
    # it automatically here: if this script is itself running inside a
    # qterminal window (likely), killing the process would tear down this
    # very script mid-run. Run this yourself once the script finishes:
    warn "IMPORTANT: after this script finishes, run:  pkill qterminal"
    warn "  (closing the window alone is not enough -- it's single-instance and won't reload the config otherwise)"
    warn "  Then open a fresh terminal from the panel to see the change."
    QTERMINAL_RESTART_NEEDED=1
}

# =============================================================================
# GTK APPEARANCE: icon theme, cursor theme, GTK theme, fonts, DPI, bg color
# =============================================================================
apply_xfce_gtk_appearance() {
    section "GTK Appearance -- Icons / Cursor / Theme / Fonts"

    if ! as_user xfconf-query -c xsettings -l &>/dev/null; then
        warn "xsettings channel not reachable for ${TARGET_USER} -- skipping GTK appearance (needs an active Xfce session)"
        return 1
    fi

    # Undo damage from an earlier version of this script that forced a
    # hardcoded DPI (broke panel/icon/font sizing on high-DPI displays).
    # Reset it back to Xfce's auto-detected default.
    if as_user xfconf-query -c xsettings -p /Xft/DPI &>/dev/null; then
        as_user xfconf-query -c xsettings -p /Xft/DPI -r 2>/dev/null || true
        info "Reset /Xft/DPI to auto-detected default (undoing a previous bad override)"
    fi

    # ── Papirus-Dark icon theme (packaged) ──────────────────────────────────
    if [[ ! -d /usr/share/icons/Papirus-Dark ]]; then
        apt-get install -y -qq papirus-icon-theme &>/dev/null \
            && success "papirus-icon-theme installed" \
            || warn "papirus-icon-theme apt install failed -- icon theme won't be available"
    else
        info "Papirus-Dark already installed"
    fi

    # ── Recolor Papirus folders to teal ─────────────────────────────────────
    # Papirus ships one folder icon per accent colour; the active set defaults
    # to blue. papirus-folders (upstream helper) flips the active colour to the
    # cyberpunk teal. Change FOLDER_COLOR to any colour Papirus ships (run
    # `papirus-folders -l` to list) if you ever want a different accent.
    FOLDER_COLOR="teal"
    if [[ -d /usr/share/icons/Papirus-Dark ]]; then
        if ! command -v papirus-folders &>/dev/null; then
            info "Fetching papirus-folders helper..."
            if curl -fsSL https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-folders/master/papirus-folders \
                    -o ${WORKDIR}/papirus-folders 2>/dev/null; then
                install -m 755 ${WORKDIR}/papirus-folders /usr/local/bin/papirus-folders
                rm -f ${WORKDIR}/papirus-folders
                success "papirus-folders installed to /usr/local/bin"
            else
                warn "Could not download papirus-folders -- folders will stay the default blue"
            fi
        fi

        if command -v papirus-folders &>/dev/null; then
            if [[ -f "/usr/share/icons/Papirus-Dark/48x48/places/folder-${FOLDER_COLOR}-documents.svg" ]]; then
                # Apply to every installed Papirus variant so open/save dialogs
                # (which may use the light theme) match the file manager too.
                for PVAR in Papirus Papirus-Dark Papirus-Light; do
                    [[ -d "/usr/share/icons/${PVAR}" ]] || continue
                    papirus-folders -C "${FOLDER_COLOR}" --theme "${PVAR}" &>/dev/null \
                        && success "${PVAR} folders recoloured to ${FOLDER_COLOR}" \
                        || warn "papirus-folders failed for ${PVAR}"
                done
            else
                warn "Papirus has no '${FOLDER_COLOR}' folder variant here -- leaving folder colour unchanged"
                warn "  run 'papirus-folders -l' to list the colours your Papirus version ships"
            fi
        fi
    fi

    # ── Bibata-Modern-Ice cursor theme (GitHub release tarball) ─────────────
    if [[ ! -d /usr/share/icons/Bibata-Modern-Ice ]]; then
        info "Downloading Bibata-Modern-Ice cursor theme..."
        BIBATA_URL=$(curl -fsSL https://api.github.com/repos/ful1e5/Bibata_Cursor/releases/latest 2>/dev/null \
            | grep -oP '"browser_download_url":\s*"\K[^"]*Bibata-Modern-Ice\.tar\.xz' | head -1)
        if [[ -n "${BIBATA_URL}" ]]; then
            if curl -fsSL "${BIBATA_URL}" -o ${WORKDIR}/Bibata-Modern-Ice.tar.xz 2>/dev/null; then
                tar -xJf ${WORKDIR}/Bibata-Modern-Ice.tar.xz -C ${WORKDIR}
                if [[ -d ${WORKDIR}/Bibata-Modern-Ice ]]; then
                    mv ${WORKDIR}/Bibata-Modern-Ice /usr/share/icons/
                    success "Bibata-Modern-Ice installed to /usr/share/icons/"
                else
                    warn "Bibata-Modern-Ice tarball extracted but folder not found as expected"
                fi
                rm -f ${WORKDIR}/Bibata-Modern-Ice.tar.xz
            else
                warn "Failed to download Bibata-Modern-Ice tarball"
            fi
        else
            warn "Could not resolve latest Bibata-Modern-Ice release URL -- skipping cursor theme"
        fi
    else
        info "Bibata-Modern-Ice already installed"
    fi

    # ── Fluent-round-teal-Dark-compact GTK theme (built from source) ────────
    if [[ ! -d /usr/share/themes/Fluent-round-teal-Dark-compact ]]; then
        info "Building Fluent-round-teal-Dark-compact GTK theme (this takes a minute)..."
        apt-get install -y -qq sassc optipng inkscape libglib2.0-dev-bin libxml2-utils &>/dev/null || \
            warn "Some Fluent-gtk-theme build deps may be missing (sassc/optipng/inkscape/libglib2.0-dev-bin/libxml2-utils)"
        FLUENT_SRC="${WORKDIR}/Fluent-gtk-theme"
        rm -rf "${FLUENT_SRC}"
        if git clone --depth=1 https://github.com/vinceliuice/Fluent-gtk-theme.git "${FLUENT_SRC}" &>/dev/null; then
            (cd "${FLUENT_SRC}" && ./install.sh -t teal -c dark -s compact --tweaks round &>${WORKDIR}/fluent-install.log)
            if [[ -d /usr/share/themes/Fluent-round-teal-Dark-compact ]]; then
                success "Fluent-round-teal-Dark-compact installed to /usr/share/themes/"
            else
                warn "Fluent-gtk-theme install.sh ran but the expected variant folder wasn't produced. Last 15 lines of the build log:"
                tail -n 15 ${WORKDIR}/fluent-install.log 2>/dev/null | while IFS= read -r LOGLINE; do
                    echo -e "    \033[0;90m${LOGLINE}\033[0m"
                done
                warn "(full build output shown above was captured to a temporary scratch dir)"
            fi
        else
            warn "Failed to clone Fluent-gtk-theme -- skipping GTK theme"
        fi
        rm -rf "${FLUENT_SRC}"
    else
        info "Fluent-round-teal-Dark-compact already installed"
    fi

    # ── Fonts ─────────────────────────────────────────────────────────────
    # Fonts are installed so they're AVAILABLE to pick from in Appearance
    # settings, but font name/size is intentionally NOT force-applied via
    # xsettings anymore -- that's in the same "could make everything look
    # broken/huge if something doesn't parse the way I expect" category as
    # the DPI override that already caused real damage. Set these two
    # manually via Settings Manager -> Appearance -> Fonts if you want them.
    apt-get install -y -qq fonts-cantarell fonts-firacode &>/dev/null || \
        warn "Font package install failed for fonts-cantarell/fonts-firacode"

    # ── Apply via xfconf (xsettings channel = Xfce's GTK appearance daemon) ─
    # ThemeName is only set if the Fluent build actually succeeded -- pointing
    # GTK at a theme name with no matching folder on disk is asking for
    # fallback/rendering weirdness for no reason.
    if [[ -d /usr/share/themes/Fluent-round-teal-Dark-compact ]]; then
        as_user xfconf-query -c xsettings -p /Net/ThemeName -s "Fluent-round-teal-Dark-compact" 2>/dev/null || \
            as_user xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s "Fluent-round-teal-Dark-compact" 2>/dev/null || true
    else
        warn "Fluent-round-teal-Dark-compact not present on disk -- not touching /Net/ThemeName"
    fi
    as_user xfconf-query -c xsettings -p /Net/IconThemeName    -s "Papirus-Dark" 2>/dev/null || \
        as_user xfconf-query -c xsettings -p /Net/IconThemeName    -n -t string -s "Papirus-Dark" 2>/dev/null || true
    as_user xfconf-query -c xsettings -p /Gtk/CursorThemeName  -s "Bibata-Modern-Ice" 2>/dev/null || \
        as_user xfconf-query -c xsettings -p /Gtk/CursorThemeName  -n -t string -s "Bibata-Modern-Ice" 2>/dev/null || true
    # No DPI, no Gtk/FontName, no Gtk/MonospaceFontName, no CursorThemeSize --
    # nothing here touches element/text scale, only icon set, cursor set, and
    # (if built) the widget theme.

    success "GTK theme/icons/cursor/fonts applied via xsettings"

    # ── Background color override (#23252E) ──────────────────────────────
    # Themes control background color through their own CSS, which a simple
    # xfconf property can't override -- so this is layered on top as a GTK
    # CSS rule that applies regardless of which theme is active.
    for GTKV in gtk-3.0 gtk-4.0; do
        GTK_CSS_DIR="${TARGET_HOME}/.config/${GTKV}"
        mkdir -p "${GTK_CSS_DIR}"
        GTK_CSS_FILE="${GTK_CSS_DIR}/gtk.css"
        touch "${GTK_CSS_FILE}"
        if ! grep -q "ui-bg-override" "${GTK_CSS_FILE}" 2>/dev/null; then
            cat >> "${GTK_CSS_FILE}" << 'GTKCSS_EOF'

/* ui-bg-override -- forced background color, added by kali-ui-setup.sh */
window, .background {
    background-color: #23252E;
}
GTKCSS_EOF
        fi
        chown -R "${TARGET_USER}:${TARGET_USER}" "${GTK_CSS_DIR}"
    done
    success "Background color #23252E applied via ~/.config/gtk-3.0|4.0/gtk.css"
}

# NOTE: $XDG_CURRENT_DESKTOP is NOT reliable here -- this script normally runs
# under `sudo`, which strips almost all environment variables from the caller
# by default, so XDG_CURRENT_DESKTOP is typically empty even though the
# invoking user IS in a graphical Xfce/GNOME session. Detect by checking
# which session process is actually running for TARGET_USER instead.
if pgrep -u "${TARGET_USER}" -x xfce4-session &>/dev/null; then
    DE="xfce"
elif pgrep -u "${TARGET_USER}" -x gnome-session &>/dev/null; then
    DE="gnome"
elif pgrep -u "${TARGET_USER}" -x plasmashell &>/dev/null; then
    DE="kde"
else
    DE="${XDG_CURRENT_DESKTOP:-unknown}"
fi
info "Detected DE: ${DE}"
case "${DE,,}" in
    *gnome*) apply_gnome_theme ;;
    *xfce*)  apply_xfce_theme; apply_xfce_terminal_theme; apply_qterminal_theme; apply_xfce_gtk_appearance ;;
    *)
        warn "Unknown DE '${DE}' — attempting GNOME dconf"
        apply_gnome_theme || true
        ;;
esac

# =============================================================================
# 11. DE-LEVEL KEYBOARD SHORTCUTS
# =============================================================================
section "Registering Keyboard Shortcuts"

apply_gnome_shortcuts() {
    BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"

    declare -a SC_NAMES=("Burp Suite Pro"                      "File Manager" "Terminal")
    declare -a SC_CMDS=( "${TARGET_HOME}/BurpSuitePro/BurpSuite"   "thunar"       "x-terminal-emulator")
    declare -a SC_KEYS=( "<Alt>b"                              "<Super>e"     "<Alt>t")

    PATHS=""
    for i in "${!SC_NAMES[@]}"; do
        as_user dconf write \
            "${BASE}/custom${i}/name"    "'${SC_NAMES[$i]}'" 2>/dev/null || true
        as_user dconf write \
            "${BASE}/custom${i}/command" "'${SC_CMDS[$i]}'"  2>/dev/null || true
        as_user dconf write \
            "${BASE}/custom${i}/binding" "'${SC_KEYS[$i]}'"  2>/dev/null || true
        PATHS="${PATHS}'${BASE}/custom${i}/', "
    done

    as_user dconf write \
        "${BASE}" "[${PATHS%, }]" 2>/dev/null || true

    success "GNOME shortcuts: Alt+B (Burp) · Alt+T (Terminal) · Super+E (Files)"
}

apply_xfce_shortcuts() {
    if command -v xfconf-query &>/dev/null; then
        sudo -u "${TARGET_USER}" xfconf-query -c xfce4-keyboard-shortcuts \
            -p "/commands/custom/<Alt>b"   -n -t string -s "${TARGET_HOME}/BurpSuitePro/BurpSuite" 2>/dev/null || true
        sudo -u "${TARGET_USER}" xfconf-query -c xfce4-keyboard-shortcuts \
            -p "/commands/custom/<Super>e" -n -t string -s "thunar"                            2>/dev/null || true
        sudo -u "${TARGET_USER}" xfconf-query -c xfce4-keyboard-shortcuts \
            -p "/commands/custom/<Alt>t"   -n -t string -s "x-terminal-emulator"               2>/dev/null || true
        success "XFCE shortcuts registered"
    else
        warn "xfconf-query not found — set shortcuts manually"
    fi
}

case "${DE,,}" in
    *gnome*) apply_gnome_shortcuts ;;
    *xfce*)  apply_xfce_shortcuts  ;;
    *)
        warn "Unknown DE '${DE}' — trying GNOME dconf shortcuts"
        apply_gnome_shortcuts || true
        ;;
esac

# =============================================================================
# 12. TMUX
# =============================================================================
section "Tmux Configuration"

cat > "${TARGET_HOME}/.tmux.conf" << 'TMUX_EOF'
# =============================================================================
# ~/.tmux.conf — cyberpunk teal theme
# =============================================================================

# Prefix: Ctrl+A
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Indexing from 1
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Quality of life
set -g mouse on
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g history-limit 50000
set -s escape-time 10

# Split panes — preserve CWD
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Pane navigation: Alt+Arrow
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D

# Reload config
bind r source-file ~/.tmux.conf \; display-message " Config reloaded"

# ── Status bar — cyberpunk teal ───────────────────────────────────────────────
set -g status on
set -g status-interval 5
set -g status-position bottom
set -g status-justify left

set -g status-style              "bg=#0d1a16,fg=#4a9e8a"
set -g status-left-length        40
set -g status-left               "#[fg=#50c896,bold] #S #[fg=#1a3a2a]│ "
set -g status-right-length       60
set -g status-right              "#[fg=#4a9e8a]#H #[fg=#1a3a2a]│ #[fg=#50c896,bold]%H:%M"

setw -g window-status-format         "#[fg=#3a6a5a] #I:#W "
setw -g window-status-current-format "#[fg=#0d1a16,bg=#50c896,bold] #I:#W "
setw -g window-status-separator      ""

set -g pane-border-style         "fg=#1a3a2a"
set -g pane-active-border-style  "fg=#50c896"
set -g message-style             "bg=#1a2a24,fg=#50c896,bold"
TMUX_EOF

chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.tmux.conf"
success "~/.tmux.conf written"

# =============================================================================
# 13. FASTFETCH
# =============================================================================
section "Fastfetch Configuration"

FASTFETCH_DIR="${TARGET_HOME}/.config/fastfetch"
mkdir -p "${FASTFETCH_DIR}"

# fastfetch uses JSON config (config.jsonc)
cat > "${FASTFETCH_DIR}/config.jsonc" << 'FASTFETCH_EOF'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "source": "kali",
        "color": {
            "1": "38;2;80;200;150",
            "2": "38;2;74;158;138"
        }
    },
    "display": {
        "separator": " ",
        "color": {
            "keys":   "38;2;74;158;138",
            "title":  "38;2;80;200;150"
        }
    },
    "modules": [
        "title",
        "separator",
        { "type": "os",       "key": "OS      " },
        { "type": "kernel",   "key": "Kernel  " },
        { "type": "uptime",   "key": "Uptime  " },
        { "type": "shell",    "key": "Shell   " },
        { "type": "terminal", "key": "Terminal" },
        { "type": "de",       "key": "DE/WM   " },
        { "type": "cpu",      "key": "CPU     " },
        { "type": "memory",   "key": "Memory  " },
        { "type": "disk",     "key": "Disk    ", "folders": "/" },
        "break"
    ]
}
FASTFETCH_EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${FASTFETCH_DIR}"
success "Fastfetch config written"

# =============================================================================
# 14. NEOVIM CLIPBOARD FIX
#
# Bug: garbled text like "+q4D73O$sr/1EQ4iqfEsiJQ==" appearing inside vim/nvim.
# Cause: Neovim's built-in OSC52 clipboard fallback fires whenever it can't
#        reach a real clipboard tool (e.g. no $DISPLAY in an SSH session, or
#        xclip fails silently), and it writes the raw OSC52 escape sequence
#        (ESC ] 52 ; c ; <base64> BEL) to the terminal. xterm-256color's
#        terminfo does not advertise OSC52 support, so the terminal prints
#        the sequence as literal text instead of consuming it.
# Fix:   explicitly pin the clipboard provider — use xclip only when a real
#        X11 $DISPLAY is present, otherwise disable clipboard integration
#        entirely so nvim never falls back to OSC52.
# =============================================================================
section "Neovim Clipboard Fix (OSC52 garbage-text bug)"

NVIM_CONFIG_DIR="${TARGET_HOME}/.config/nvim"
mkdir -p "${NVIM_CONFIG_DIR}"

cat > "${NVIM_CONFIG_DIR}/init.lua" << 'NVIM_EOF'
-- =============================================================================
-- ~/.config/nvim/init.lua
-- Clipboard fix: prevent Neovim's OSC52 fallback from leaking raw escape
-- sequences into terminals (xterm-256color) that don't render them.
-- =============================================================================

if vim.fn.executable("xclip") == 1 and vim.env.DISPLAY ~= nil and vim.env.DISPLAY ~= "" then
  -- Real X11 session available -- use xclip, never OSC52.
  vim.g.clipboard = {
    name = "xclip-X11",
    copy = {
      ["+"] = "xclip -selection clipboard",
      ["*"] = "xclip -selection primary",
    },
    paste = {
      ["+"] = "xclip -selection clipboard -o",
      ["*"] = "xclip -selection primary -o",
    },
    cache_enabled = 0,
  }
else
  -- No usable X11 clipboard (SSH session, headless, etc.) --
  -- disable clipboard integration outright so Neovim never falls back
  -- to printing an OSC52 escape sequence into an unsupporting terminal.
  vim.g.clipboard = {
    name = "disabled",
    copy = { ["+"] = "", ["*"] = "" },
    paste = {
      ["+"] = function() return {} end,
      ["*"] = function() return {} end,
    },
    cache_enabled = 0,
  }
end

-- Do not auto-sync the unnamed register with the system clipboard;
-- use explicit "+y" / "+p" when you actually want the system clipboard.
vim.opt.clipboard = ""
NVIM_EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${NVIM_CONFIG_DIR}"
success "~/.config/nvim/init.lua written -- OSC52 fallback disabled"

# =============================================================================
# 15. XFCE PANEL -- LIVE STATS MONITOR (interface / IP / CPU% / RAM%)
#
# Adds a text-only Generic Monitor (genmon) plugin to the panel, styled with
# the cyberpunk teal palette, similar in spirit to the reference screenshot:
# "eth0 192.168.10.128 | RAM 40% | CPU 81%". No graphs/sparklines -- plain
# percentage text only, refreshed every 3s. Existing panel items (whisker
# menu, pinned launchers, workspace switcher, systray/clock/lock/etc.) are
# left untouched -- the plugin is appended, not inserted destructively.
# =============================================================================
section "XFCE Panel -- Live Stats Monitor"

STATS_BIN_DIR="${TARGET_HOME}/.local/bin"
mkdir -p "${STATS_BIN_DIR}"

cat > "${STATS_BIN_DIR}/panel-stats.sh" << 'STATS_EOF'
#!/usr/bin/env bash
# Emits genmon-compatible pango markup: interface, IP, CPU%, RAM%
# Palette: teal-green #50c896 (labels/good), amber #c09060 (values),
#          soft teal-grey #8ab8a8 (separators), red #cc4444 (link down).

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [[ -z "${IFACE}" ]]; then
    IFACE=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
fi

if [[ -n "${IFACE}" ]]; then
    IP=$(ip -4 -o addr show "${IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
fi
IFACE="${IFACE:-none}"
IP="${IP:-no ip}"

# CPU% -- instantaneous delta sample from /proc/stat (100ms window)
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 _ < /proc/stat
sleep 0.1
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 _ < /proc/stat
IDLE1=$((i1 + w1)); IDLE2=$((i2 + w2))
TOTAL1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1))
TOTAL2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2))
DIFF_TOTAL=$((TOTAL2 - TOTAL1))
DIFF_IDLE=$((IDLE2 - IDLE1))
if [[ ${DIFF_TOTAL} -gt 0 ]]; then
    CPU=$(( (100 * (DIFF_TOTAL - DIFF_IDLE)) / DIFF_TOTAL ))
else
    CPU=0
fi

# RAM%
read -r MEM_TOTAL MEM_AVAIL < <(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)
if [[ -n "${MEM_TOTAL}" && "${MEM_TOTAL}" -gt 0 ]]; then
    RAM=$(( 100 * (MEM_TOTAL - MEM_AVAIL) / MEM_TOTAL ))
else
    RAM=0
fi

C_LABEL="#8ab8a8"
C_VALUE="#c09060"
C_GOOD="#50c896"
C_BAD="#cc4444"
C_SEP="#3a6a5a"

IFACE_COLOR="${C_GOOD}"
[[ "${IFACE}" == "none" ]] && IFACE_COLOR="${C_BAD}"

printf '<txt><span foreground="%s">%s</span> <span foreground="%s">%s</span> <span foreground="%s"> | </span><span foreground="%s">CPU</span> <span foreground="%s">%s%%</span><span foreground="%s"> | </span><span foreground="%s">RAM</span> <span foreground="%s">%s%%</span></txt>\n' \
    "${IFACE_COLOR}" "${IFACE}" "${C_LABEL}" "${IP}" "${C_SEP}" \
    "${C_LABEL}" "${C_VALUE}" "${CPU}" "${C_SEP}" \
    "${C_LABEL}" "${C_VALUE}" "${RAM}"

printf '<tool>Interface: %s\nIP: %s\nCPU: %s%%\nRAM: %s%%</tool>\n' "${IFACE}" "${IP}" "${CPU}" "${RAM}"
STATS_EOF

chmod +x "${STATS_BIN_DIR}/panel-stats.sh"
chown "${TARGET_USER}:${TARGET_USER}" "${STATS_BIN_DIR}/panel-stats.sh"
success "~/.local/bin/panel-stats.sh written"

add_xfce_genmon() {
    if ! command -v xfce4-panel &>/dev/null; then
        warn "xfce4-panel not found -- skipping automatic panel plugin add"
        return 1
    fi
    if ! as_user xfconf-query -c xfce4-panel -p /panels -l &>/dev/null; then
        warn "No running XFCE panel session detected for ${TARGET_USER} -- skipping automatic add"
        return 1
    fi

    # Find the panel with the most existing plugins (assume it's the main bar
    # shown in the screenshot) -- we only append to it, nothing is removed.
    MAIN_PANEL=""
    MAX_COUNT=0
    for P in $(as_user xfconf-query -c xfce4-panel -p /panels -l 2>/dev/null | grep -oP '(?<=/panels/panel-)\d+(?=/plugin-ids)' | sort -un); do
        COUNT=$(as_user xfconf-query -c xfce4-panel -p "/panels/panel-${P}/plugin-ids" 2>/dev/null | wc -l)
        if [[ ${COUNT} -gt ${MAX_COUNT} ]]; then
            MAX_COUNT=${COUNT}
            MAIN_PANEL="${P}"
        fi
    done
    [[ -z "${MAIN_PANEL}" ]] && MAIN_PANEL="1"
    info "Target panel: panel-${MAIN_PANEL} (${MAX_COUNT} existing plugins)"

    # ── Idempotency: find every genmon plugin already on this panel whose
    # command is our panel-stats.sh (i.e. added by a previous run of this
    # script). Keep the first one, remove any extras -- this both prevents
    # piling up duplicates on repeat runs AND self-heals the duplicates that
    # earlier (buggy) runs already created.
    mapfile -t PANEL_IDS < <(as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL}/plugin-ids" 2>/dev/null | tail -n +2)

    EXISTING_MATCHES=()
    for id in "${PANEL_IDS[@]}"; do
        [[ -z "${id}" ]] && continue
        TYPE=$(as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null)
        [[ "${TYPE}" != "genmon" ]] && continue
        CMD=$(as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}/command" 2>/dev/null)
        [[ "${CMD}" == "${STATS_BIN_DIR}/panel-stats.sh" ]] && EXISTING_MATCHES+=("${id}")
    done

    if [[ ${#EXISTING_MATCHES[@]} -gt 0 ]]; then
        KEEP_ID="${EXISTING_MATCHES[0]}"
        info "panel-stats.sh genmon already present as plugin-${KEEP_ID} -- not adding another"

        if [[ ${#EXISTING_MATCHES[@]} -gt 1 ]]; then
            warn "Found ${#EXISTING_MATCHES[@]} duplicate stats plugins from previous runs -- removing all but plugin-${KEEP_ID}"
            REMOVE_IDS=("${EXISTING_MATCHES[@]:1}")

            # Rebuild plugin-ids for this panel excluding the duplicates
            SET_ARGS=()
            for id in "${PANEL_IDS[@]}"; do
                [[ -z "${id}" ]] && continue
                SKIP=0
                for rm in "${REMOVE_IDS[@]}"; do [[ "${id}" == "${rm}" ]] && SKIP=1; done
                [[ ${SKIP} -eq 1 ]] && continue
                SET_ARGS+=(-t int -s "${id}")
            done
            as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL}/plugin-ids" "${SET_ARGS[@]}" --create 2>/dev/null || true

            for rm in "${REMOVE_IDS[@]}"; do
                as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${rm}" -r -R 2>/dev/null || true
            done

            as_user xfce4-panel -r 2>/dev/null || true
            success "Removed ${#REMOVE_IDS[@]} duplicate stats plugin(s), kept plugin-${KEEP_ID}"
        fi
        return 0
    fi

    # Next free plugin id
    NEXT_ID=$(as_user xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null \
        | grep -oP '(?<=/plugins/plugin-)\d+' | sort -n | tail -1)
    NEXT_ID=$((${NEXT_ID:-0} + 1))
    info "New plugin id: ${NEXT_ID}"

    as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${NEXT_ID}" -n -t string -s "genmon" 2>/dev/null || true

    # Read back the EXISTING plugin ids for this panel as an array (one id
    # per line) and rebuild the full array with our new id appended -- each
    # id needs its own "-t int -s <id>" pair; xfconf-query does not accept a
    # space-joined list as a single value.
    SET_ARGS=()
    for id in "${PANEL_IDS[@]}"; do
        [[ -z "${id}" ]] && continue
        SET_ARGS+=(-t int -s "${id}")
    done
    SET_ARGS+=(-t int -s "${NEXT_ID}")

    as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL}/plugin-ids" "${SET_ARGS[@]}" --create 2>/dev/null || true

    PP="/plugins/plugin-${NEXT_ID}"
    as_user xfconf-query -c xfce4-panel -p "${PP}/command"      -n -t string -s "${STATS_BIN_DIR}/panel-stats.sh" 2>/dev/null || true
    as_user xfconf-query -c xfce4-panel -p "${PP}/period"       -n -t int    -s 3                                  2>/dev/null || true
    as_user xfconf-query -c xfce4-panel -p "${PP}/use-label"    -n -t bool   -s false                              2>/dev/null || true
    as_user xfconf-query -c xfce4-panel -p "${PP}/font"         -n -t string -s "MesloLGS NF 10"                   2>/dev/null || true

    as_user xfce4-panel -r 2>/dev/null || true
    sleep 1

    # Verify: is NEXT_ID actually present in the panel's plugin-ids now?
    if as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL}/plugin-ids" 2>/dev/null | grep -qx "${NEXT_ID}"; then
        success "Genmon stats plugin added to panel-${MAIN_PANEL} as plugin-${NEXT_ID}"
        return 0
    else
        warn "Wrote plugin-${NEXT_ID} but it's not showing up in panel-${MAIN_PANEL}'s plugin-ids -- xfconf write likely failed"
        return 1
    fi
}

if ! add_xfce_genmon; then
    warn "Automatic panel injection skipped/failed -- add it by hand (takes ~30 seconds):"
    warn "  Right-click panel -> Panel -> Add New Items... -> Generic Monitor -> Add"
    warn "  Then edit it: Command = ${STATS_BIN_DIR}/panel-stats.sh, Period = 3s, uncheck 'Show text label'"
fi

# =============================================================================
# XFCE PANEL -- icon size + remove the built-in CPU graph plugin(s)
#
# NOTE on caution: after the DPI incident, this is intentionally scoped to
# ONLY the panel's own icon-size/row-size properties -- nothing here touches
# fonts, DPI, or any GTK-wide scale factor. Worst case if this number is
# wrong is a panel row that's too big or too small, trivially fixable by
# editing PANEL_ICON_SIZE/PANEL_ROW_SIZE below and re-running.
# =============================================================================
section "XFCE Panel -- Icon Size & Cleanup"

PANEL_ICON_SIZE=32   # px, confirmed correct size
PANEL_ROW_SIZE=32    # px, matched exactly to icon size per request

# NOTE: "/panels/panel-N" alone is not a real xfconf property -- only its
# children (e.g. .../plugin-ids, .../size) are. Checking the bare path
# always failed here even though the panel is perfectly reachable, which is
# why the CPU-graph removal (which queries a real leaf, .../plugin-ids)
# worked fine in the same run while this block reported "could not reach".
if as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/plugin-ids" &>/dev/null; then
    as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/icon-size" -s "${PANEL_ICON_SIZE}" 2>/dev/null || \
        as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/icon-size" -n -t int -s "${PANEL_ICON_SIZE}" 2>/dev/null || true
    as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/size" -s "${PANEL_ROW_SIZE}" 2>/dev/null || \
        as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/size" -n -t int -s "${PANEL_ROW_SIZE}" 2>/dev/null || true
    success "Panel icon size set to ${PANEL_ICON_SIZE}px (row height ${PANEL_ROW_SIZE}px)"
else
    warn "Could not reach panel-${MAIN_PANEL:-1} to adjust icon size"
fi

# Remove the built-in CPU graph / system load plugin(s) -- these are separate
# from our own panel-stats.sh genmon and were likely added by the default
# Kali panel layout, not by this script, so they're the only case here where
# we deliberately remove existing plugins rather than only ever appending.
REMOVE_TYPES=("cpugraph" "systemload")
mapfile -t CLEANUP_PANEL_IDS < <(as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/plugin-ids" 2>/dev/null | tail -n +2)

CPU_REMOVE_IDS=()
for id in "${CLEANUP_PANEL_IDS[@]}"; do
    [[ -z "${id}" ]] && continue
    PTYPE=$(as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${id}" 2>/dev/null)
    for rt in "${REMOVE_TYPES[@]}"; do
        [[ "${PTYPE}" == "${rt}" ]] && CPU_REMOVE_IDS+=("${id}")
    done
done

if [[ ${#CPU_REMOVE_IDS[@]} -gt 0 ]]; then
    SET_ARGS=()
    for id in "${CLEANUP_PANEL_IDS[@]}"; do
        [[ -z "${id}" ]] && continue
        SKIP=0
        for rm in "${CPU_REMOVE_IDS[@]}"; do [[ "${id}" == "${rm}" ]] && SKIP=1; done
        [[ ${SKIP} -eq 1 ]] && continue
        SET_ARGS+=(-t int -s "${id}")
    done
    as_user xfconf-query -c xfce4-panel -p "/panels/panel-${MAIN_PANEL:-1}/plugin-ids" "${SET_ARGS[@]}" --create 2>/dev/null || true
    for rm in "${CPU_REMOVE_IDS[@]}"; do
        as_user xfconf-query -c xfce4-panel -p "/plugins/plugin-${rm}" -r -R 2>/dev/null || true
    done
    success "Removed ${#CPU_REMOVE_IDS[@]} built-in CPU graph/load plugin(s): ${CPU_REMOVE_IDS[*]}"
else
    info "No built-in cpugraph/systemload plugins found on this panel"
fi

as_user xfce4-panel -r 2>/dev/null || true

# =============================================================================
# 16. TOOL INSTALLER -- pop up a terminal with the install menu
# (script content: see tool-installer.sh, deployed to ~/.local/bin)
# =============================================================================
section "Tool Installer Menu"

if [[ -f "${SCRIPT_DIR}/tool-installer.sh" ]]; then
    cp "${SCRIPT_DIR}/tool-installer.sh" "${STATS_BIN_DIR}/tool-installer.sh"
    chmod +x "${STATS_BIN_DIR}/tool-installer.sh"
    chown "${TARGET_USER}:${TARGET_USER}" "${STATS_BIN_DIR}/tool-installer.sh"
    success "tool-installer.sh deployed to ~/.local/bin/"
else
    warn "tool-installer.sh not found next to this script -- skipping deployment"
fi

if command -v x-terminal-emulator &>/dev/null; then
    as_user \
        x-terminal-emulator -e bash -lc "${STATS_BIN_DIR}/tool-installer.sh" &>/dev/null &
    success "Tool installer menu launched in a new terminal"
else
    warn "x-terminal-emulator not found -- run manually: ~/.local/bin/tool-installer.sh"
fi

# =============================================================================
# SUMMARY
# =============================================================================
section "Setup Complete"

echo -e "${C_GRAY}  kali-cyberpunk-setup v${VERSION}${C_RESET}"
echo -e '\033[38;2;80;200;150m'
cat << 'BANNER'
  ██╗  ██╗ █████╗ ██╗     ██╗    ██████╗  ██████╗ ███╗   ██╗███████╗
  ██║ ██╔╝██╔══██╗██║     ██║    ██╔══██╗██╔═══██╗████╗  ██║██╔════╝
  █████╔╝ ███████║██║     ██║    ██║  ██║██║   ██║██╔██╗ ██║█████╗
  ██╔═██╗ ██╔══██║██║     ██║    ██║  ██║██║   ██║██║╚██╗██║██╔══╝
  ██║  ██╗██║  ██║███████╗██║    ██████╔╝╚██████╔╝██║ ╚████║███████╗
  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝
BANNER
echo -e '\033[0m'

echo -e '\033[38;2;74;158;138mStatus check:\033[0m'
if [[ "${WALLPAPER_APPLIED}" == "live on desktop" ]]; then
    echo -e "  \033[38;2;80;200;150m✓\033[0m Wallpaper: applied and live"
else
    echo -e "  \033[38;2;204;68;68m✗\033[0m Wallpaper: NOT applied ($([[ ${WALLPAPER_APPLIED} == no ]] && echo 'wallpaper.png missing next to script' || echo 'copied but xfconf write failed -- see warnings above'))"
fi
if [[ "${AVATAR_APPLIED}" == "copied" ]]; then
    echo -e "  \033[38;2;80;200;150m✓\033[0m Avatar: installed to AccountsService (shows at next login/lock screen)"
else
    echo -e "  \033[38;2;204;68;68m✗\033[0m Avatar: NOT applied (avatar.png missing next to script)"
fi
echo ""

echo -e '\033[38;2;74;158;138mFiles written:\033[0m'
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.shell_common        shared aliases, env, FZF"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.bashrc              Kali PS1 cyberpunk + ble.sh"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.zshrc               Oh My Zsh + Powerlevel10k"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.p10k.zsh            Powerlevel10k cyberpunk preset"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.tmux.conf           teal status bar"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.config/xfce4/terminal/terminalrc  solid bg, no transparency"
echo -e "  \033[38;2;80;200;150m+\033[0m Papirus-Dark (teal folders) / Bibata-Modern-Ice / Fluent-round-teal-Dark-compact"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.config/gtk-3.0|4.0/gtk.css  background #23252E"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.config/fastfetch/    custom config"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.config/nvim/init.lua OSC52 clipboard fix (vim garbled-text bug)"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.local/bin/panel-stats.sh   XFCE panel: iface/IP/CPU%/RAM%"
echo -e "  \033[38;2;80;200;150m+\033[0m ~/.local/bin/tool-installer.sh  fzf tool installer (/opt/tools)"
echo -e "  \033[38;2;80;200;150m+\033[0m ${ASSETS_DIR}/"
echo ""
echo -e '\033[38;2;74;158;138mKeyboard shortcuts:\033[0m'
echo -e "  Alt+B    Burp Suite Pro"
echo -e "  Alt+T    New terminal"
echo -e "  Super+E  File manager  (DE-level)"
echo ""
echo -e '\033[38;2;74;158;138mNext steps:\033[0m'
if [[ "${QTERMINAL_RESTART_NEEDED:-0}" == "1" ]]; then
    echo -e "  \033[38;2;204;68;68m0. Run: pkill qterminal  -- then open a fresh terminal from the panel\033[0m"
    echo -e "     \033[0;90m(qterminal is single-instance; closing the window alone won't reload the new opaque background)\033[0m"
fi
echo -e "  1. Log out and back in  (default shell is now zsh)"
echo -e "  2. On first zsh launch: \033[0;90mp10k configure\033[0m  or preset loads automatically"
echo -e "  3. Set terminal font to: \033[0;90mMesloLGS NF 11\033[0m"
echo -e "  4. Place wallpaper.png / avatar.png next to this script before running"
echo ""
