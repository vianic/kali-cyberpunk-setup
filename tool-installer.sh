#!/usr/bin/env bash
# =============================================================================
# tool-installer.sh -- fzf-based tool installer for /opt/tools
# Theme: Cyberpunk / Dark Teal
# Version: 1.0.0
#
# Row format (pipe-delimited, 7 fields, "-" = not applicable):
#   name|type|check_cmd|apt_pkg|git_url|install_cmd|description
#
# type is one of:
#   apt        -- sudo apt-get install <apt_pkg>
#   pip        -- pip install <install_cmd's argument>, no git clone at all
#   git+pip    -- git clone, python3 -m venv .venv, run install_cmd inside it
#   git+bash   -- git clone only, optionally run install_cmd directly (no venv)
#   go         -- `go install <git_url>` if a Go toolchain is present
#   winbin     -- Windows-target tool: git clone source AND fetch the latest
#                 GitHub release asset (precompiled .exe), since these are
#                 meant to be transferred to a Windows box, not run on Kali
#   special    -- bespoke installer, dispatched by name (see install_special)
#
# Tool list lives in ~/.config/kali-tools/tools.conf and can be extended
# from inside the menu itself ("+ Add a new tool to this menu").
# =============================================================================

set -uo pipefail

VERSION="1.0.0"

# ─── Palette ──────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_GREEN='\033[38;2;80;200;150m'   # #50c896
C_TEAL='\033[38;2;74;158;138m'    # #4a9e8a
C_RED='\033[38;2;204;68;68m'      # #cc4444
C_AMBER='\033[38;2;192;144;96m'   # #c09060
C_GRAY='\033[0;90m'
C_BOLD='\033[1m'

info()    { echo -e "${C_TEAL}[*]${C_RESET} $*"; }
success() { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()    { echo -e "${C_RED}[!]${C_RESET} $*"; }
skip()    { echo -e "${C_AMBER}[~]${C_RESET} $*"; }
section() {
    echo -e "\n${C_BOLD}${C_GRAY}────────────────────────────────────────${C_RESET}"
    echo -e "${C_BOLD}${C_TEAL}  $*${C_RESET}"
    echo -e "${C_BOLD}${C_GRAY}────────────────────────────────────────${C_RESET}"
}

# Generic browser User-Agent -- blends into ordinary traffic instead of
# advertising a bespoke setup tool to every service we contact.
UA="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

# ─── Config ───────────────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.config/kali-tools"
CONFIG_FILE="${CONFIG_DIR}/tools.conf"
TOOLS_DIR="/opt/tools"

mkdir -p "${CONFIG_DIR}"

# Per-user private log directory (0700) instead of world-readable /tmp/*.log.
# Keeps install output -- which reveals your username and the toolset you pull --
# from other local users, and sidesteps predictable-/tmp symlink games.
LOG_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/kali-tools-$(id -u)"
mkdir -p "${LOG_DIR}" && chmod 700 "${LOG_DIR}"

# Make user-local install targets visible to THIS process so is_installed()
# can see pipx- and go-installed binaries during the same run.
export PATH="${HOME}/.local/bin:${HOME}/go/bin:${PATH}"

# Never let git block on an interactive username/password prompt: a wrong or
# private repo URL should fail fast instead of hanging waiting for input that
# is invisible behind our log redirects (this is what stalled the bad
# nanodump URL). Applies to every git clone in this script.
export GIT_TERMINAL_PROMPT=0

# Python install backend for this run:
#   standard -> pipx for CLI tools, python venv + pip for repos
#   uv       -> uv tool install / uv venv + uv pip  (set by "Install ALL (uv)")
PY_BACKEND="standard"

TOOLS_CONF_VERSION=4

# seed_default_config: (over)write the bundled default tool list. The very
# first line of the heredoc carries a "schema vN" marker; a later run greps
# for it to tell whether the tools.conf on disk is current. This is what stops
# an old, stale config (e.g. the original 11-tool list) from silently masking
# every tool added since.
seed_default_config() {
    cat > "${CONFIG_FILE}" << 'DEFAULT_TOOLS_EOF'
# tools.conf | schema v4 | managed by tool-installer.sh -- do not delete this header line
# ── AD / Windows enumeration & abuse ────────────────────────────────────────
netexec|apt|nxc|netexec|-|-|AD/SMB swiss-army-knife enumeration (formerly CrackMapExec)
bloodhound-py|apt|bloodhound-python|bloodhound.py|-|-|Python BloodHound ingestor
certipy|git+pip|certipy-ad|-|https://github.com/ly4k/Certipy.git|pip install -e .|ADCS enumeration & abuse (ESC1-ESC16)
coercer|git+pip|Coercer|-|https://github.com/p0dalirius/Coercer.git|pip install .|Automated authentication coercion (PetitPotam/PrinterBug/...)
enum4linux-ng|git+pip|enum4linux-ng|-|https://github.com/cddmp/enum4linux-ng.git|pip install -r requirements.txt|SMB/AD null-session enumeration
windapsearch|git+pip|windapsearch.py|-|https://github.com/ropnop/windapsearch.git|pip install -r requirements.txt|LDAP enumeration (anonymous/authenticated bind)
pywsus|git+pip|pywsus|-|https://github.com/GoSecure/pywsus.git|pip install -r requirements.txt|WSUS HTTP spoofing server
pygpoabuse|git+pip|-|-|https://github.com/Hackndo/pyGPOAbuse.git|pip install -r requirements.txt|Python port of SharpGPOAbuse (GPO scheduled task abuse)
pywhisker|git+pip|-|-|https://github.com/ShutdownRepo/pywhisker.git|pip install -r requirements.txt|Shadow Credentials attacks (msDS-KeyCredentialLink)
rdpassspray|git+pip|-|-|https://github.com/xFreed0m/RDPassSpray.git|pip install -r requirements.txt|RDP password spraying (also needs freerdp2-x11 via apt)
seth|git+bash|-|-|https://github.com/SySS-Research/Seth.git|-|RDP MitM cleartext credential extraction
snaffler-ng|pip|snaffler|-|-|pip install snaffler-ng|Impacket-based Python port of Snaffler (SMB share/credential hunting)
spraycharles|pip|spraycharles|-|-|pip install spraycharles --python 3.12|Low-and-slow password spraying (O365/OWA/EWS/Okta/ADFS/Citrix/SMB)
webclientservicescanner|git+pip|-|-|https://github.com/Hackndo/WebclientServiceScanner.git|pip install .|Scan for WebDAV/WebClient service (coercion prerequisite)
dementor|git+bash|-|-|https://github.com/NotMedic/NetNTLMtoSilverTicket.git|-|Printer spooler NTLM coercion (dementor.py)
linwinpwn|git+bash|-|-|https://github.com/lefayjey/linWinPwn.git|chmod +x linWinPwn.sh|Bash wrapper automating a large AD enumeration toolchain (CLONE ONLY -- its install.sh is long and interactive and pulls in tools this menu already installs; run /opt/tools/linwinpwn/install.sh by hand if you want its bundled deps)
printnightmare|git+pip|-|-|https://github.com/ly4k/PrintNightmare.git|pip install impacket|CVE-2021-1675/34527 exploitation (impacket-based)

# ── Windows-target tools (clone source + fetch release .exe) ───────────────
rubeus|winbin|-|-|https://github.com/GhostPack/Rubeus.git|-|Kerberos abuse toolkit (C#, no official prebuilt release -- build via msbuild/VS)
seatbelt|winbin|-|-|https://github.com/GhostPack/Seatbelt.git|-|Host situational awareness (C#, no official prebuilt release -- build via msbuild/VS)
remotepotato0|winbin|-|-|https://github.com/antonioCoco/RemotePotato0.git|-|DCOM/RPC NTLM relay privesc (has prebuilt release .exe)
remotekrbrelay|winbin|-|-|https://github.com/CICADA8-Research/RemoteKrbRelay.git|-|Remote Kerberos relay framework
winpeas|winbin|-|-|https://github.com/peass-ng/PEASS-ng.git|-|Windows privilege escalation enumeration (prebuilt release .exe)

# ── Tunneling / file transfer ───────────────────────────────────────────────
chisel|go|chisel|-|github.com/jpillora/chisel@latest|-|Fast TCP/UDP tunnel over HTTP
ligolo-ng|go|proxy|-|github.com/nicocha30/ligolo-ng/cmd/proxy@latest|-|Layer3 tunneling via reverse TLS (also grab agent binaries from Releases for targets)
goshs|go|goshs|-|github.com/patrickhener/goshs@latest|-|Feature-rich single-binary file server (HTTP/WebDAV/FTP/SMB/NTLM capture)
socat|apt|socat|socat|-|-|Swiss-army-knife relay/tunnel tool

# ── Web application testing ─────────────────────────────────────────────────
corscanner|pip|cors|-|-|pip install corscanner|CORS misconfiguration scanner
typo3scan|git+pip|-|-|https://github.com/whoot/Typo3Scan.git|pip install -r requirements.txt|TYPO3 CMS version/extension scanner (legacy targets only, unmaintained since v12+)
xsstrike|git+pip|-|-|https://github.com/s0md3v/XSStrike.git|pip install -r requirements.txt|Advanced XSS detection suite
wpscan|apt|wpscan|wpscan|-|-|WordPress vulnerability/enumeration scanner
nuclei|go|nuclei|-|github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest|-|Template-based vulnerability scanner (run 'nuclei -update-templates' after install)
p0wny-shell|git+bash|-|-|https://github.com/flozz/p0wny-shell.git|-|Single-file PHP webshell
wwwolf-php-webshell|git+bash|-|-|https://github.com/WhiteWinterWolf/wwwolf-php-webshell.git|-|Single-file PHP webshell (WhiteWinterWolf)
payloadsallthethings|git+bash|-|-|https://github.com/swisskyrepo/PayloadsAllTheThings.git|-|Reference repo: reverse shells, payloads, bypass cheatsheets

# ── Reporting / misc ─────────────────────────────────────────────────────────
sysinternals|special|-|-|-|sysinternals|Microsoft SysinternalsSuite (direct download, not a git repo)
pandoc-eisvogel|special|-|-|-|eisvogel|pandoc + LaTeX + Eisvogel report template

# ── More AD tools from our past conversations ──────────────────────────────
kerbrute|go|kerbrute|-|github.com/ropnop/kerbrute@latest|-|Kerberos pre-auth username enum & password spraying
evil-winrm|apt|evil-winrm|evil-winrm|-|-|WinRM shell (Pass-the-Hash/Cert/Kerberos support)
mitm6|pip|mitm6|-|-|pip install mitm6|IPv6 DNS takeover + NTLM relay setup
ldapdomaindump|pip|ldapdomaindump|-|-|pip install ldapdomaindump|LDAP enumeration -> HTML/JSON domain dump
manspider|pip|manspider|-|-|pip install manspider|Crawl SMB shares for filenames/content/extensions
wsuks|pip|wsuks|-|-|pip install wsuks|Automated WSUS MITM privesc (also needs python3-nftables via apt)
gowitness|go|gowitness|-|github.com/sensepost/gowitness@latest|-|Web screenshotting for recon at scale
httpx|go|httpx|-|github.com/projectdiscovery/httpx/cmd/httpx@latest|-|Fast HTTP probing/recon toolkit
sccmhunter|git+pip|-|-|https://github.com/garrettfoster13/sccmhunter.git|pip install -r requirements.txt|SCCM enumeration & relay (MP/DP/site discovery)
powerview-py|git+pip|-|-|https://github.com/aniqfakhrul/powerview.py.git|pip install .|Python port of PowerView -- runs natively on Kali, no pwsh needed

# ── More Windows-target tools (clone source + fetch release .exe) ──────────
sharpdpapi|winbin|-|-|https://github.com/GhostPack/SharpDPAPI.git|-|C# port of Mimikatz DPAPI functionality (masterkeys/credentials/vaults/Chrome)
certify|winbin|-|-|https://github.com/GhostPack/Certify.git|-|AD CS abuse -- C# counterpart to Certipy for on-host use
sharpsccm|winbin|-|-|https://github.com/Mayyhem/SharpSCCM.git|-|SCCM interaction/exploitation from a domain-joined host

# ── More AD/Windows tools ────────────────────────────────────────────────────
bloodyad|pip|bloodyAD|-|-|pip install bloodyAD|AD privilege escalation / ACL abuse swiss-army-knife
pkinittools|git+pip|-|-|https://github.com/dirkjanm/PKINITtools.git|pip install -r requirements.txt|PKINIT auth from PFX/cert on Linux (gettgtpkinit.py etc.)
krbrelayx|git+pip|-|-|https://github.com/dirkjanm/krbrelayx.git|pip install impacket dnspython ldap3 future|Kerberos relay toolkit (unconstrained deleg, printer bug, ADIDNS)
lsassy|pip|lsassy|-|-|pip install lsassy|Remote LSASS dumping via multiple methods
donpapi|git+pip|-|-|https://github.com/login-securite/DonPAPI.git|pip install .|Remotely dump DPAPI secrets across a domain
pypykatz|pip|pypykatz|-|-|pip install pypykatz|Pure-Python Mimikatz-equivalent credential parsing
pre2k|git+pip|-|-|https://github.com/garrettfoster13/pre2k.git|pip install .|Pre-Windows2000 computer account abuse
dfscoerce|git+bash|-|-|https://github.com/Wh04m1001/DFSCoerce.git|-|Authentication coercion via MS-DFSNM
shadowcoerce|git+bash|-|-|https://github.com/ShutdownRepo/ShadowCoerce.git|-|Authentication coercion via MS-FSRVP (VSS)
zerologon|git+pip|-|-|https://github.com/dirkjanm/CVE-2020-1472.git|pip install impacket|CVE-2020-1472 Netlogon privilege escalation
smbmap|apt|smbmap|smbmap|-|-|SMB share enumeration and permission mapping
adexplorersnapshot|git+pip|-|-|https://github.com/c3c/ADExplorerSnapshot.py.git|pip install .|Parse AD Explorer .dat snapshots into BloodHound-compatible data
adrecon|git+bash|-|-|https://github.com/adrecon/ADRecon.git|-|AD recon report generator (PowerShell, needs pwsh)
mssqlpwner|apt|mssqlpwner|mssqlpwner|-|-|MSSQL linked-server abuse / lateral movement
adfsbrute|git+pip|-|-|https://github.com/ricardojoserf/adfsbrute.git|pip install requests PySocks stem urllib3|ADFS password spraying/bruteforcing
o365spray|git+pip|-|-|https://github.com/0xZDH/o365spray.git|pip install -r requirements.txt|Office 365 username enum & password spraying

# ── More Windows-target tools (clone source + fetch release .exe) ──────────
sharphound|winbin|-|-|https://github.com/BloodHoundAD/SharpHound.git|-|Official C# BloodHound collector
nanodump|winbin|-|-|https://github.com/fortra/nanodump.git|-|LSASS minidump generation with evasion techniques
powersharppack|winbin|-|-|https://github.com/S3cur3Th1sSh1t/PowerSharpPack.git|-|Bundle of Sharp* tools wrapped for in-memory PowerShell execution
winpwn|git+bash|-|-|https://github.com/S3cur3Th1sSh1t/WinPwn.git|-|All-in-one PowerShell AD recon/exploitation automation (not compiled, PowerShell source)
donut|git+bash|-|-|https://github.com/TheWover/donut.git|make|Shellcode generator from PE files (builds fine on Linux via make)
petitpotam|git+bash|-|-|https://github.com/topotam/PetitPotam.git|-|MS-EFSRPC authentication coercion (the original PrinterBug-style coercion tool)
snaffler|winbin|-|-|https://github.com/SnaffCon/Snaffler.git|-|Original C# Snaffler -- for on-host use on a Windows box (snaffler-ng above is the Linux-native pip version)

# ── More web/recon tools ─────────────────────────────────────────────────────
hydra|apt|hydra|hydra|-|-|Classic online login bruteforcer (many protocols)
sqlmap|apt|sqlmap|sqlmap|-|-|Automated SQL injection detection/exploitation
nikto|apt|nikto|nikto|-|-|Web server vulnerability/misconfiguration scanner
whatweb|apt|whatweb|whatweb|-|-|Web technology fingerprinting
bettercap|apt|bettercap|bettercap|-|-|Full MITM/network attack framework
dnsrecon|apt|dnsrecon|dnsrecon|-|-|DNS enumeration and zone transfer testing
assetfinder|go|assetfinder|-|github.com/tomnomnom/assetfinder@latest|-|Subdomain discovery via certificate transparency/APIs
sublist3r|git+pip|-|-|https://github.com/aboul3la/Sublist3r.git|pip install -r requirements.txt|Subdomain enumeration via search engines
git-dumper|git+pip|-|-|https://github.com/arthaud/git-dumper.git|pip install -r requirements.txt|Recover exposed .git repositories from web servers
apachetomcatscanner|pip|apachetomcatscanner|-|-|pip install apachetomcatscanner|Apache Tomcat version/vulnerability/manager-credential scanner
neo-regeorg|git+bash|-|-|https://github.com/L-codes/Neo-reGeorg.git|-|Successor to reGeorg -- SOCKS-over-webshell tunneling
log4j-scan|git+pip|-|-|https://github.com/fullhunt/log4j-scan.git|pip install -r requirements.txt|Log4Shell (CVE-2021-44228) scanner

# ── Single-file scripts from S3cur3Th1sSh1t/AI-Coded-scripts ───────────────
invoke-sharesnaffler|rawfile|-|-|https://raw.githubusercontent.com/S3cur3Th1sSh1t/AI-Coded-scripts/main/Invoke-ShareSnaffler.ps1|-|PowerShell SMB share snaffling (Windows-target, needs pwsh)
certipy_min|rawfile|-|-|https://raw.githubusercontent.com/S3cur3Th1sSh1t/AI-Coded-scripts/main/certipy_min.py|certipy-ad ldap3 impacket dnspython pycryptodomex|ADCS ESC1-8 misconfig checks via LDAP only (no direct PKI access needed)
pyadrecon|rawfile|-|-|https://raw.githubusercontent.com/S3cur3Th1sSh1t/AI-Coded-scripts/main/pyadrecon.py|ldap3 impacket openpyxl|Python port of ADRecon -- full AD enum via LDAP, NTLM/Kerberos, CSV/XLSX export
teams-enum|rawfile|-|-|https://raw.githubusercontent.com/S3cur3Th1sSh1t/AI-Coded-scripts/main/teams_enum.py|requests dnspython brotli|Email validation via MS Teams API (device-code MFA support)

ace_analyzer|git+pip|-|-|-|-|placeholder -- edit or remove via "add new tool"
DEFAULT_TOOLS_EOF
    success "Wrote default tool list (schema v${TOOLS_CONF_VERSION}) -> ${CONFIG_FILE}"
}

# Always converge on the newest bundled list: seed it if absent, and if the
# file on disk predates the current schema version, back it up and regenerate.
if [[ ! -f "${CONFIG_FILE}" ]]; then
    seed_default_config
elif ! grep -q "schema v${TOOLS_CONF_VERSION}" "${CONFIG_FILE}"; then
    _conf_backup="${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "${CONFIG_FILE}" "${_conf_backup}"
    warn "tools.conf on disk predates schema v${TOOLS_CONF_VERSION} -- backing up and regenerating"
    warn "  old file kept at ${_conf_backup} (re-add any custom tools from there)"
    seed_default_config
fi

sudo mkdir -p "${TOOLS_DIR}"
sudo chown "$(id -u):$(id -g)" "${TOOLS_DIR}" 2>/dev/null || true

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Return 0 (installed) / 1 (not installed)
is_installed() {
    local check_cmd="$1" name="$2"
    # 1) a binary on PATH
    if [[ "${check_cmd}" != "-" ]] && command -v "${check_cmd}" &>/dev/null; then
        return 0
    fi
    # 2) a populated /opt/tools/<name> dir (git / winbin / rawfile installs)
    if [[ -d "${TOOLS_DIR}/${name}" ]] && [[ -n "$(ls -A "${TOOLS_DIR}/${name}" 2>/dev/null)" ]]; then
        return 0
    fi
    # 3) a pipx or uv tool venv named after the tool -- catches pip-type tools
    #    whose console-script name differs from check_cmd, or that live in
    #    ~/.local/bin without it being on PATH at display time (e.g. corscanner
    #    exposes `cors`, not `corscanner`).
    if [[ -d "${HOME}/.local/share/pipx/venvs/${name}" ]] || \
       [[ -d "${HOME}/.local/share/uv/tools/${name}" ]]; then
        return 0
    fi
    # 4) special installers whose artifact is neither a bin nor a /opt/tools dir
    case "${name}" in
        pandoc-eisvogel)
            [[ -f "${HOME}/.local/share/pandoc/templates/eisvogel.latex" ]] && return 0 ;;
        sysinternals)
            [[ -d "${TOOLS_DIR}/sysinternals" && -n "$(ls -A "${TOOLS_DIR}/sysinternals" 2>/dev/null)" ]] && return 0 ;;
    esac
    return 1
}

install_via_apt() {
    local pkg="$1"
    info "Installing via apt: ${pkg}"
    if sudo apt-get install -y "${pkg}" &>${LOG_DIR}/apt.log; then
        success "${pkg} installed via apt"
        return 0
    fi
    warn "apt install failed for ${pkg} -- see ${LOG_DIR}/apt.log"
    return 1
}

# Kali is a PEP 668 "externally managed" environment: a bare `pip install`
# into the system interpreter is refused (externally-managed-environment).
# pipx is the sanctioned path for standalone CLI tools -- it drops each app in
# its own venv and links the entrypoint onto PATH. Install it once, on demand.
ensure_pipx() {
    if command -v pipx &>/dev/null; then
        return 0
    fi
    info "pipx not found -- installing it (required on PEP 668 externally-managed Kali)"
    if sudo apt-get install -y pipx &>${LOG_DIR}/pipx.log; then
        pipx ensurepath &>/dev/null || true
        export PATH="${HOME}/.local/bin:${PATH}"
        success "pipx installed"
        return 0
    fi
    warn "Could not install pipx via apt -- see ${LOG_DIR}/pipx.log"
    return 1
}

# uv (astral.sh): a single fast binary that replaces pip/venv/pipx. `uv tool
# install` is its pipx equivalent (isolated CLI apps); `uv pip` is a drop-in
# faster pip. Installed on demand via the official installer.
ensure_uv() {
    if command -v uv &>/dev/null; then
        return 0
    fi
    info "uv not found -- installing via the official installer (astral.sh)"
    if curl -LsSf https://astral.sh/uv/install.sh -o ${LOG_DIR}/uv-install.sh 2>${LOG_DIR}/uv.log \
       && sh ${LOG_DIR}/uv-install.sh &>>${LOG_DIR}/uv.log; then
        export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
        if command -v uv &>/dev/null; then
            success "uv installed"
            return 0
        fi
    fi
    warn "Could not install uv automatically -- see ${LOG_DIR}/uv.log (fallback: pipx install uv)"
    return 1
}

install_via_pip() {
    local name="$1" install_cmd="$2"
    # install_cmd is of the form "pip install <pkgspec>"; strip the prefix so
    # we can hand <pkgspec> to pipx / uv instead.
    local pkgspec="${install_cmd}"
    pkgspec="${pkgspec#pip install }"
    pkgspec="${pkgspec#pip3 install }"

    # A "--python X.Y" pin means the tool needs a specific interpreter (e.g.
    # spraycharles pins numpy<2.0, which has no cp313 wheels, so it must be
    # built on Python 3.12). Only uv can fetch an arbitrary interpreter on
    # demand, so force the uv path for such tools regardless of chosen backend.
    local needs_pyver=0
    [[ "${pkgspec}" == *"--python "* ]] && needs_pyver=1

    if [[ "${PY_BACKEND}" == "uv" || ${needs_pyver} -eq 1 ]]; then
        if ensure_uv; then
            [[ ${needs_pyver} -eq 1 ]] && info "${name} needs a pinned Python -- installing via uv (it will fetch the interpreter if absent)"
            info "Installing via uv tool: ${pkgspec}"
            if uv tool install ${pkgspec} </dev/null &>${LOG_DIR}/${name}.log; then
                success "${name} installed via uv tool (isolated, entrypoint on PATH)"
                return 0
            fi
            warn "uv tool install failed for ${name} -- see ${LOG_DIR}/${name}.log"
            if [[ ${needs_pyver} -eq 1 ]]; then
                warn "  ${name} requires the pinned Python; not falling back to pipx (would hit the same build failure)"
                return 1
            fi
            warn "  falling back to pipx/venv"
        elif [[ ${needs_pyver} -eq 1 ]]; then
            warn "${name} needs a specific Python that only uv can provision, but uv is unavailable -- skipping"
            return 1
        fi
    fi

    # pipx can't provision interpreters, so drop any --python pin for its path.
    local pipx_spec="${pkgspec%% --python *}"

    if ensure_pipx; then
        info "Installing via pipx: ${pipx_spec}"
        # </dev/null: never let a stray prompt hang behind the log redirect.
        if pipx install ${pipx_spec} </dev/null &>${LOG_DIR}/${name}.log; then
            success "${name} installed via pipx (isolated venv, entrypoint on PATH)"
            return 0
        fi
        warn "pipx install failed for ${name} -- see ${LOG_DIR}/${name}.log; trying an isolated venv under ${TOOLS_DIR}"
    fi

    # Fallback: a dedicated venv under /opt/tools (still never touches the
    # system interpreter). Used if pipx is unavailable or the package ships no
    # console_scripts for pipx to expose.
    local dest="${TOOLS_DIR}/${name}"
    mkdir -p "${dest}"
    python3 -m venv "${dest}/.venv"
    # shellcheck disable=SC1091
    source "${dest}/.venv/bin/activate"
    if pip install ${pipx_spec} </dev/null &>>${LOG_DIR}/${name}.log; then
        success "${name} installed into ${dest}/.venv (add ${dest}/.venv/bin to PATH to run it)"
        deactivate 2>/dev/null || true
        return 0
    fi
    deactivate 2>/dev/null || true
    warn "Isolated-venv install also failed for ${name} -- see ${LOG_DIR}/${name}.log"
    return 1
}

install_via_git_pip() {
    local name="$1" git_url="$2" install_cmd="$3"
    local dest="${TOOLS_DIR}/${name}"

    if [[ -d "${dest}" ]]; then
        skip "${dest} already exists -- not re-cloning"
    else
        info "Cloning ${git_url} -> ${dest}"
        if ! git clone --depth=1 "${git_url}" "${dest}"; then
            warn "git clone failed for ${name}"
            return 1
        fi
    fi

    pushd "${dest}" > /dev/null || return 1

    if [[ ! -d ".venv" ]]; then
        info "Creating virtualenv: ${dest}/.venv"
        if [[ "${PY_BACKEND}" == "uv" ]] && command -v uv &>/dev/null; then
            uv venv .venv &>/dev/null || python3 -m venv .venv
        else
            python3 -m venv .venv
        fi
    fi

    # shellcheck disable=SC1091
    source ".venv/bin/activate"

    # Resolve the effective install command. Several repos in the list don't
    # actually ship the requirements.txt the config assumed (krbrelayx,
    # printnightmare, zerologon, adfsbrute, ...); rather than fail, fall back to
    # packaging metadata or an alternate requirements file, else clone-only.
    local eff_cmd="${install_cmd}"
    if [[ "${eff_cmd}" == *"-r requirements.txt"* && ! -f "requirements.txt" ]]; then
        if [[ -f "pyproject.toml" || -f "setup.py" ]]; then
            warn "${name}: no requirements.txt -- using 'pip install .' (packaging metadata present)"
            eff_cmd="pip install ."
        else
            local altreq
            altreq=$(ls requirements*.txt 2>/dev/null | head -1)
            if [[ -n "${altreq}" ]]; then
                warn "${name}: using ${altreq} in place of requirements.txt"
                eff_cmd="pip install -r ${altreq}"
            else
                warn "${name}: no requirements/packaging file found -- cloned only, review ${dest} manually"
                eff_cmd="-"
            fi
        fi
    fi

    # Under the uv backend, route pip commands through uv's resolver.
    if [[ "${PY_BACKEND}" == "uv" && "${eff_cmd}" == "pip install "* ]] && command -v uv &>/dev/null; then
        eff_cmd="uv ${eff_cmd}"
    fi

    if [[ "${eff_cmd}" != "-" ]]; then
        info "Running install step: ${eff_cmd}"
        if eval "${eff_cmd}" </dev/null &>${LOG_DIR}/${name}.log; then
            success "${name} installed -> ${dest} (venv: ${dest}/.venv)"
        else
            warn "Install command failed for ${name} -- see ${LOG_DIR}/${name}.log"
            deactivate 2>/dev/null || true
            popd > /dev/null
            return 1
        fi
    else
        skip "No install command for ${name} -- cloned only, review ${dest} manually"
    fi

    deactivate 2>/dev/null || true
    popd > /dev/null
    return 0
}

install_via_git_bash() {
    local name="$1" git_url="$2" install_cmd="$3"
    local dest="${TOOLS_DIR}/${name}"

    if [[ -d "${dest}" ]]; then
        skip "${dest} already exists -- not re-cloning"
    else
        info "Cloning ${git_url} -> ${dest}"
        if ! git clone --depth=1 "${git_url}" "${dest}"; then
            warn "git clone failed for ${name}"
            return 1
        fi
    fi

    if [[ "${install_cmd}" != "-" ]]; then
        pushd "${dest}" > /dev/null || return 1
        info "Running: ${install_cmd}"
        if eval "${install_cmd}" </dev/null &>${LOG_DIR}/${name}.log; then
            success "${name} installed -> ${dest}"
        else
            warn "Install command failed for ${name} -- see ${LOG_DIR}/${name}.log"
        fi
        popd > /dev/null
    else
        success "${name} cloned -> ${dest}"
    fi
    return 0
}

install_via_go() {
    local name="$1" go_pkg="$2"
    if ! command -v go &>/dev/null; then
        # kali-ui-setup.sh installs Go to /usr/local/go. A terminal opened
        # before that PATH entry took effect won't see `go` yet, so pick it up
        # directly rather than reporting it missing.
        if [[ -x /usr/local/go/bin/go ]]; then
            export GOROOT=/usr/local/go
            export GOPATH="${GOPATH:-${HOME}/go}"
            export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
            info "Picked up Go from /usr/local/go (was not on PATH in this shell)"
        fi
    fi
    if ! command -v go &>/dev/null; then
        warn "Go toolchain not found (checked PATH and /usr/local/go) -- cannot 'go install ${go_pkg}'"
        warn "Install Go (re-run kali-ui-setup.sh, or: sudo apt install golang-go), then retry ${name}"
        return 1
    fi
    info "go install ${go_pkg}"
    # Privacy: fetch modules straight from their source (GitHub, which we are
    # already contacting) instead of routing the request through Google's
    # proxy.golang.org, and skip the sum.golang.org checksum-DB lookup so the
    # module paths you pull aren't reported to Google's infrastructure.
    # Trade-off: no global sumdb verification -- acceptable here since these are
    # source-built offensive tools fetched directly from their upstream repos.
    if GOPROXY=direct GOSUMDB=off GOFLAGS=-mod=mod go install "${go_pkg}" </dev/null &>${LOG_DIR}/${name}.log; then
        success "${name} installed via go install (binary in \$(go env GOPATH)/bin)"
        return 0
    fi
    warn "go install failed for ${name} -- see ${LOG_DIR}/${name}.log"
    return 1
}

# Single-file script (not a full repo): download the raw file directly rather
# than git-cloning a whole multi-tool repo just to get one script out of it.
# install_cmd here is repurposed to carry the pip dependency line (or "-" for
# scripts with no deps / non-Python scripts like .ps1).
install_via_rawfile() {
    local name="$1" raw_url="$2" pip_deps="$3"
    local dest="${TOOLS_DIR}/${name}"
    local fname
    fname=$(basename "${raw_url}")

    mkdir -p "${dest}"
    info "Downloading ${fname} -> ${dest}/${fname}"
    if ! curl -fsSL -A "${UA}" "${raw_url}" -o "${dest}/${fname}"; then
        warn "Download failed for ${name}"
        return 1
    fi
    [[ "${fname}" == *.py || "${fname}" == *.sh ]] && chmod +x "${dest}/${fname}"

    if [[ "${pip_deps}" != "-" ]]; then
        pushd "${dest}" > /dev/null || return 1
        if [[ ! -d ".venv" ]]; then
            info "Creating virtualenv: ${dest}/.venv"
            python3 -m venv .venv
        fi
        # shellcheck disable=SC1091
        source ".venv/bin/activate"
        info "Installing dependencies: ${pip_deps}"
        if pip install ${pip_deps} </dev/null &>${LOG_DIR}/${name}.log; then
            success "${name} downloaded -> ${dest}/${fname} (venv: ${dest}/.venv)"
        else
            warn "Dependency install failed for ${name} -- see ${LOG_DIR}/${name}.log"
        fi
        deactivate 2>/dev/null || true
        popd > /dev/null
    else
        success "${name} downloaded -> ${dest}/${fname}"
    fi
    return 0
}

# Windows-target tool: clone source AND grab the latest GitHub release asset
# (a precompiled .exe/.zip) if one exists. These tools are meant to be
# transferred to a Windows box, never built or run on Kali itself.
install_winbin() {
    local name="$1" git_url="$2"
    local dest="${TOOLS_DIR}/${name}"
    local src_dir="${dest}/src"
    local release_dir="${dest}/release"

    mkdir -p "${dest}"

    if [[ -d "${src_dir}" ]]; then
        skip "${src_dir} already exists -- not re-cloning"
    else
        info "Cloning source: ${git_url} -> ${src_dir}"
        git clone --depth=1 "${git_url}" "${src_dir}" || warn "git clone failed for ${name} source"
    fi

    # Derive owner/repo from the git URL for the GitHub API
    local api_repo
    api_repo=$(echo "${git_url}" | sed -E 's#https://github.com/##; s#\.git$##')

    info "Checking for a prebuilt release on GitHub..."
    local release_json
    release_json=$(curl -fsSL -A "${UA}" "https://api.github.com/repos/${api_repo}/releases/latest" 2>/dev/null)

    if [[ -z "${release_json}" ]] || echo "${release_json}" | grep -q '"message": *"Not Found"'; then
        warn "No GitHub Releases found for ${name} -- source clone only (build it yourself, e.g. via msbuild/Visual Studio)"
        return 0
    fi

    mkdir -p "${release_dir}"
    local asset_urls
    asset_urls=$(echo "${release_json}" | grep -oP '"browser_download_url": *"\K[^"]+')

    if [[ -z "${asset_urls}" ]]; then
        warn "Release found but no downloadable assets -- source clone only"
        return 0
    fi

    while IFS= read -r url; do
        [[ -z "${url}" ]] && continue
        local fname
        fname=$(basename "${url}")
        if [[ -f "${release_dir}/${fname}" ]]; then
            skip "${fname} already downloaded"
            continue
        fi
        info "Downloading release asset: ${fname}"
        curl -fsSL -A "${UA}" "${url}" -o "${release_dir}/${fname}" || warn "Failed to download ${fname}"
    done <<< "${asset_urls}"

    success "${name}: source in ${src_dir}, release binaries in ${release_dir}"
    return 0
}

# ─── Special (bespoke) installers ──────────────────────────────────────────

install_sysinternals() {
    local dest="${TOOLS_DIR}/sysinternals"
    mkdir -p "${dest}"
    local zip="${dest}/SysinternalsSuite.zip"
    info "Downloading SysinternalsSuite from Microsoft..."
    if curl -fsSL -A "${UA}" "https://download.sysinternals.com/files/SysinternalsSuite.zip" -o "${zip}"; then
        if command -v unzip &>/dev/null; then
            unzip -oq "${zip}" -d "${dest}"
            success "SysinternalsSuite extracted to ${dest}"
        else
            success "SysinternalsSuite.zip downloaded to ${zip} (install 'unzip' to auto-extract)"
        fi
    else
        warn "Failed to download SysinternalsSuite"
        return 1
    fi
}

install_eisvogel() {
    info "Installing pandoc + LaTeX packages (texlive-latex-extra, this is a large download)..."
    sudo apt-get install -y pandoc texlive-latex-extra texlive-fonts-extra &>${LOG_DIR}/eisvogel-apt.log \
        || warn "apt install of pandoc/texlive packages had issues -- see ${LOG_DIR}/eisvogel-apt.log"

    local tpl_dir="${HOME}/.local/share/pandoc/templates"
    mkdir -p "${tpl_dir}"

    info "Fetching latest Eisvogel template release..."
    local release_json
    release_json=$(curl -fsSL -A "${UA}" "https://api.github.com/repos/Wandmalfarbe/pandoc-latex-template/releases/latest" 2>/dev/null)
    local asset_url
    asset_url=$(echo "${release_json}" | grep -oP '"browser_download_url": *"\K[^"]+\.tar\.gz' | head -1)

    if [[ -z "${asset_url}" ]]; then
        warn "Could not find a release asset -- get it manually from https://github.com/Wandmalfarbe/pandoc-latex-template/releases"
        return 1
    fi

    local workdir; workdir=$(mktemp -d)
    local tmpfile="${workdir}/eisvogel.tar.gz"
    curl -fsSL -A "${UA}" "${asset_url}" -o "${tmpfile}" || { warn "Download failed"; rm -rf "${workdir}"; return 1; }

    tar -xzf "${tmpfile}" -C "${workdir}"
    local latex_file
    latex_file=$(find "${workdir}" -maxdepth 2 -iname "eisvogel.latex" -o -iname "eisvogel.tex" 2>/dev/null | head -1)
    if [[ -n "${latex_file}" ]]; then
        cp "${latex_file}" "${tpl_dir}/eisvogel.latex"
        success "Eisvogel template installed to ${tpl_dir}/eisvogel.latex"
        info "Use with: pandoc report.md -o report.pdf --template eisvogel --listings"
    else
        warn "Downloaded the release but couldn't find eisvogel.latex/.tex inside it"
        rm -rf "${workdir}"
        return 1
    fi
    rm -rf "${workdir}"
}

install_special() {
    local name="$1" handler="$2"
    case "${handler}" in
        sysinternals) install_sysinternals ;;
        eisvogel)     install_eisvogel ;;
        *) warn "Unknown special installer '${handler}' for ${name}" ;;
    esac
}

install_tool() {
    local line="$1"
    IFS='|' read -r name type check_cmd apt_pkg git_url install_cmd description <<< "${line}"

    section "${name} [${type}]"

    if is_installed "${check_cmd}" "${name}"; then
        skip "${name} already present on this system -- skipping"
        return
    fi

    case "${type}" in
        apt)
            install_via_apt "${apt_pkg}"
            ;;
        pip)
            install_via_pip "${name}" "${install_cmd}"
            ;;
        git+pip)
            install_via_git_pip "${name}" "${git_url}" "${install_cmd}"
            ;;
        git+bash)
            install_via_git_bash "${name}" "${git_url}" "${install_cmd}"
            ;;
        go)
            install_via_go "${name}" "${git_url}"
            ;;
        rawfile)
            install_via_rawfile "${name}" "${git_url}" "${install_cmd}"
            ;;
        winbin)
            install_winbin "${name}" "${git_url}"
            ;;
        special)
            install_special "${name}" "${install_cmd}"
            ;;
        *)
            warn "Unknown install type '${type}' for ${name} -- edit ${CONFIG_FILE}"
            ;;
    esac
}

add_new_tool() {
    section "Add a new tool to the menu"
    echo -e "${C_GRAY}Leave a field empty and press Enter to use '-' (not applicable).${C_RESET}"
    read -rp "$(echo -e "${C_TEAL}Tool name (used as /opt/tools/<name>): ${C_RESET}")" n_name
    [[ -z "${n_name}" ]] && { warn "Name is required -- aborted"; return; }
    echo -e "${C_TEAL}Install type: 1=apt 2=pip 3=git+pip 4=git+bash 5=go${C_RESET}"
    read -rp "$(echo -e "${C_TEAL}Choice [1-5]: ${C_RESET}")" n_type_choice
    case "${n_type_choice}" in
        1) n_type="apt" ;;
        2) n_type="pip" ;;
        3) n_type="git+pip" ;;
        4) n_type="git+bash" ;;
        5) n_type="go" ;;
        *) n_type="git+pip" ;;
    esac
    read -rp "$(echo -e "${C_TEAL}Check command (binary to detect an existing install): ${C_RESET}")" n_check
    read -rp "$(echo -e "${C_TEAL}apt package name (only used for type=apt): ${C_RESET}")" n_apt
    read -rp "$(echo -e "${C_TEAL}Git URL / go module path (as applicable): ${C_RESET}")" n_git
    read -rp "$(echo -e "${C_TEAL}Install command (pip install line, or script to run): ${C_RESET}")" n_install
    read -rp "$(echo -e "${C_TEAL}Short description: ${C_RESET}")" n_desc

    n_check="${n_check:--}"; n_apt="${n_apt:--}"; n_git="${n_git:--}"
    n_install="${n_install:--}"; n_desc="${n_desc:--}"

    echo "${n_name}|${n_type}|${n_check}|${n_apt}|${n_git}|${n_install}|${n_desc}" >> "${CONFIG_FILE}"
    success "${n_name} added to ${CONFIG_FILE}"
    read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu...${C_RESET}")" _
}

# ─── Burp Suite (Community / Professional) downloader ──────────────────────
#
# Deliberately download-only -- never installs or runs anything. Queries
# PortSwigger's own release JSON (the same endpoint their homepage uses) for
# the latest "Desktop" build, picks the Linux build matching the host's
# architecture, verifies it against the SHA256 PortSwigger publishes for
# that build, and drops the installer in ~/Downloads for you to run by hand.
download_burpsuite() {
    section "Burp Suite Download (Community / Professional)"

    if ! command -v python3 &>/dev/null; then
        warn "python3 not found -- needed to parse PortSwigger's release JSON"
        return
    fi

    echo "  1) Community Edition"
    echo "  2) Professional"
    read -rp "$(echo -e "${C_TEAL}Edition [1/2]: ${C_RESET}")" ED
    case "${ED}" in
        1) PRODUCT="community"; EDITION_LABEL="Community" ;;
        2) PRODUCT="pro"; EDITION_LABEL="Professional" ;;
        *) warn "Invalid choice -- aborted"; return ;;
    esac

    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64|amd64)   BUILD_PLATFORM="Linux" ;;
        aarch64|arm64)  BUILD_PLATFORM="LinuxArm64" ;;
        *) warn "Unrecognized architecture '${ARCH}' -- PortSwigger only publishes x64/ARM64 Linux builds"; return ;;
    esac
    info "Detected architecture: ${ARCH} -> ${BUILD_PLATFORM}"

    info "Querying PortSwigger for the latest Burp Suite Desktop release..."
    RELEASE_JSON=$(curl -fsSL -A "${UA}" "https://portswigger.net/burp/releases/data" 2>/dev/null)
    if [[ -z "${RELEASE_JSON}" ]]; then
        warn "Could not reach portswigger.net/burp/releases/data"
        return
    fi

    RESULT=$(echo "${RELEASE_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
platform = sys.argv[1]           # Linux | LinuxArm64
product  = sys.argv[2]           # community | pro
# PortSwigger tags each build with BuildCategoryId (edition) AND
# BuildCategoryPlatform. The old code matched only the platform and grabbed
# the first build -- so it returned the *other* edition's checksum, which never
# matched the file we actually download. Match BOTH, on a Stable release.
aliases = {'community': {'community'}, 'pro': {'pro', 'professional'}}.get(product, {product})
for item in data.get('ResultSet', {}).get('Results', []):
    if 'Stable' not in (item.get('releaseChannels') or []):
        continue
    version = item.get('version')
    for b in item.get('builds', []):
        if b.get('BuildCategoryId') in aliases and b.get('BuildCategoryPlatform') == platform:
            print(f\"{version}|{b.get('Sha256Checksum','')}\")
            sys.exit(0)
sys.exit(1)
" "${BUILD_PLATFORM}" "${PRODUCT}" 2>/dev/null)

    if [[ -z "${RESULT}" ]]; then
        warn "Could not find a Stable ${EDITION_LABEL} ${BUILD_PLATFORM} build in the release data -- PortSwigger may have changed their API"
        return
    fi

    VERSION="${RESULT%%|*}"
    EXPECTED_SHA256="${RESULT##*|}"
    info "Latest version: ${VERSION}"

    DL_URL="https://portswigger-cdn.net/burp/releases/download?product=${PRODUCT}&version=${VERSION}&type=${BUILD_PLATFORM}"
    DOWNLOAD_DIR="${HOME}/Downloads"
    mkdir -p "${DOWNLOAD_DIR}"
    DEST_FILE="${DOWNLOAD_DIR}/burpsuite_${PRODUCT}_${BUILD_PLATFORM,,}_v${VERSION}.sh"

    info "Downloading to ${DEST_FILE} (this is a real installer, several hundred MB)..."
    if ! curl -fL --progress-bar -A "${UA}" "${DL_URL}" -o "${DEST_FILE}"; then
        warn "Download failed"
        rm -f "${DEST_FILE}"
        return
    fi

    # Enforce integrity: the file is only trustworthy if its SHA-256 matches the
    # value published on the official portswigger.net feed. Anything else (empty
    # checksum, no sha256sum, or a mismatch) means we cannot verify it, so we
    # delete it rather than leave an unverified installer sitting executable.
    if [[ -z "${EXPECTED_SHA256}" ]]; then
        warn "No published checksum found for this build -- refusing to keep an unverifiable installer"
        rm -f "${DEST_FILE}"
        read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu...${C_RESET}")" _
        return
    fi
    if ! command -v sha256sum &>/dev/null; then
        warn "sha256sum not available -- cannot verify integrity; refusing to keep the installer"
        rm -f "${DEST_FILE}"
        read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu...${C_RESET}")" _
        return
    fi
    ACTUAL_SHA256=$(sha256sum "${DEST_FILE}" | awk '{print $1}')
    if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
        warn "SHA256 MISMATCH -- deleting the download."
        warn "  expected: ${EXPECTED_SHA256}"
        warn "  actual:   ${ACTUAL_SHA256}"
        warn "The CDN served something that doesn't match PortSwigger's published checksum. Not keeping it."
        rm -f "${DEST_FILE}"
        read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu...${C_RESET}")" _
        return
    fi
    success "SHA256 verified against PortSwigger's published checksum"

    chmod +x "${DEST_FILE}"
    success "Burp Suite ${EDITION_LABEL} ${VERSION} (${BUILD_PLATFORM}) downloaded to ${DEST_FILE}"
    info "Not installed automatically -- run it yourself when ready: ${DEST_FILE}"
    if [[ "${PRODUCT}" == "pro" ]]; then
        info "Note: Professional requires a valid license key at first run."
    fi
    read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu...${C_RESET}")" _
}

# ─── Install-method prompt (asked after tools are selected) ────────────────
# Only Python installs (types pip / git+pip) are affected by the choice; apt,
# go, winbin, rawfile and special always use their own handlers regardless.
choose_backend() {
    echo -e "${C_TEAL}Install method for the selected tool(s):${C_RESET}"
    echo -e "  1) standard  ${C_GRAY}(pipx for CLI tools, python venv + pip for repos)${C_RESET}"
    echo -e "  2) uv        ${C_GRAY}(uv tool / uv venv + uv pip -- much faster; installs uv if missing)${C_RESET}"
    read -rp "$(echo -e "${C_TEAL}Choice [1/2, default 1]: ${C_RESET}")" _be
    case "${_be}" in
        2)
            if ensure_uv; then
                PY_BACKEND="uv"
                info "Using the uv backend for Python installs in this batch"
            else
                PY_BACKEND="standard"
                warn "uv unavailable -- falling back to the standard backend"
            fi
            ;;
        *)
            PY_BACKEND="standard"
            ;;
    esac
}

# ─── Main menu loop ─────────────────────────────────────────────────────────
main_menu() {
    if ! command -v fzf &>/dev/null; then
        warn "fzf is not installed -- cannot show the interactive menu."
        warn "Install it with: sudo apt install fzf"
        exit 1
    fi

    while true; do
        local lines=()
        lines+=("$(echo -e "${C_AMBER}+ Add a new tool to this menu${C_RESET}")::__ADD__")
        lines+=("$(echo -e "${C_AMBER}⚡ Download Burp Suite (Community / Professional)${C_RESET}")::__BURP__")

        while IFS= read -r row; do
            [[ -z "${row}" || "${row}" == \#* ]] && continue
            IFS='|' read -r name type check_cmd apt_pkg git_url install_cmd description <<< "${row}"
            if is_installed "${check_cmd}" "${name}"; then
                mark="$(echo -e "${C_GREEN}[installed]${C_RESET}")"
            else
                mark="$(echo -e "${C_GRAY}[ - ]${C_RESET}")"
            fi
            type_tag="$(echo -e "${C_AMBER}[${type}]${C_RESET}")"
            display="$(printf "%s %-11s %-24s %s" "${mark}" "${type_tag}" "${name}" "${description}")"
            lines+=("${display}::${row}")
        done < "${CONFIG_FILE}"

        selection=$(printf '%s\n' "${lines[@]}" | \
            fzf --ansi --multi --height=90% --border --reverse \
                --delimiter='::' --with-nth=1 \
                --header="tool-installer v${VERSION}  |  TAB select · ENTER install · ESC quit  --  /opt/tools" \
                --prompt="tools> ")

        [[ -z "${selection}" ]] && { info "Nothing selected. Bye."; break; }

        if echo "${selection}" | grep -q "Add a new tool"; then
            add_new_tool
            continue
        fi

        if echo "${selection}" | grep -q "Download Burp Suite"; then
            download_burpsuite
            continue
        fi

        # Collect the tool rows the user actually selected (drop action entries).
        local selected_rows=()
        while IFS= read -r sel_line; do
            [[ -z "${sel_line}" ]] && continue
            matched="${sel_line#*::}"
            [[ -n "${matched}" && "${matched}" != "__ADD__" && "${matched}" != "__BURP__" ]] && selected_rows+=("${matched}")
        done <<< "${selection}"

        [[ ${#selected_rows[@]} -eq 0 ]] && continue

        # Now that tools are chosen, ask HOW to install them (this only affects
        # Python-based tools; apt/go/winbin/etc. always use their own handler).
        choose_backend

        for row in "${selected_rows[@]}"; do
            install_tool "${row}"
        done
        PY_BACKEND="standard"   # reset to default for the next batch

        section "Batch complete"
        read -rp "$(echo -e "${C_GRAY}Press Enter to return to the menu, or Ctrl+C to exit...${C_RESET}")" _
    done
}

section "Tool Installer -- /opt/tools"
info "Config: ${CONFIG_FILE}"
main_menu
