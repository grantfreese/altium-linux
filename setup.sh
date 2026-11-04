#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later
# Sets up Altium Designer under Wine on a Debian/Ubuntu-based Linux system (tested on Linux Mint 22.2).
#
# Run without arguments for an interactive setup (menus for the installer, Wine prefix, license and
# options). Options given on the command line pre-fill the menus.
#
# Usage: ./setup.sh [options]
#   --installer FILE          Altium installer: offline .zip or online .exe (not needed if Altium is
#                             already in the prefix)
#   --prefix DIR              Wine prefix to create/use (default: ~/.wine-altium<NN> from the
#                             installer's name; without --installer, the one Altium's file types and
#                             launcher already use)
#   --license FILE            .alf license file to copy into Altium's license folder (optional; without
#                             it, use a cloud or license server license in Altium)
#   --user-data ZIP           user data archive to import: from export-windows.ps1 (Windows) or the menu's
#                             Export user data (preferences, editor defaults, menus, color schemes)
#   --prefs-from-prefix DIR   copy the user data of an existing Wine prefix with Altium installed
#   --no-filetypes            don't register Altium file types/icons (removes them if registered before)
#   --no-desktop-icon         don't put an Altium icon on the desktop
#   --keep-splash             don't turn off Altium's splash screen (it hides dialogs at startup)
#   --link 'C:\dir=PATH'      make a Windows path a symlink to a Linux path (repeatable)
#   --drive 'M:=PATH'         map a drive letter to a Linux folder, e.g. for a library (repeatable;
#                             the menu's Drive mappings item also changes and removes mappings)
#   --data-dir DIR            where Altium's settings/data folders live, symlinked from the prefix
#                             (default: ~/.local/share/altium<major version>, e.g. altium21)
#   --non-interactive         don't show the menus (default when not run from a terminal)
#   --uninstall               remove the Wine prefix (--prefix) and the Linux file types, menu entry,
#                             launcher and icons; keeps the data folders (--data-dir) and the build cache
#   --yes                     don't ask for confirmation (with --uninstall)
#   -h, --help
#
# Also installs a launcher (~/.local/bin/altium<major version>) and a menu entry (see install-desktop.sh).
#
# Menu entries are saved in settings.yml. Command-line options override them.
#
# No Windows fonts are used: Altium's Windows UI fonts (Segoe UI, ...) are mapped to free Linux fonts.
# Steps that are already done are skipped, so it can be re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=""            # default: the prefix of an earlier install (installed_prefix), else ~/.wine-altium
INSTALLER=""
WINDOWS_EXPORT=""
PREFS_PREFIX=""
LICENSE=""
ACTIVATION_CODE=""   # of LICENSE; set in the menu (default: from the file name)
REGISTER_FILETYPES=1
DESKTOP_ICON=1
DISABLE_SPLASH=1
PREFS_FROM_EXPORT=1
INTERACTIVE=""
RUN_INSTALLER=0      # 1: run the installer even if Altium is already in the prefix (chosen in the menu)
UNINSTALL=0
UNINSTALL_CONFIRMED=0
ASSUME_YES=0
DATA_DIR_OPT=""      # --data-dir
DATA_DIR=""          # set_version
AD_MAJOR=""          # set_version
LINKS=()
DRIVES=()            # "M:=/linux/path"
SYNC_DRIVES=0        # 1: DRIVES is the complete list (menu); other drive mappings in the prefix are removed
CLI_SET=""           # checkboxes set on the command line
PREFIX_GIVEN=0       # --prefix
SKIP_DEPS=0          # 1: continue with missing dependencies
SETTINGS_FILE="$SCRIPT_DIR/settings.yml"

WINE_VERSION_EXPECTED="11.0"
WINE_SRC_SHA256="c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701"   # wine-11.0.tar.xz
DXVK_VERSION="3.1.1"
DXVK_SHA256="40565b4a724aadc4433fa4e010b4b23916d9b1f1baeee64e17186db94f54e608"       # dxvk-3.1.1.tar.gz
WINETRICKS_VERSION="20260125"
WINETRICKS_SHA256="431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"   # src/winetricks
WINETRICKS_VERBS="corefonts vcrun2019 dotnet48 gdiplus msxml6"
# apt packages setup needs (plus winehq-stable from WineHQ's repository, with i386 enabled)
APT_PACKAGES="python3 wget ca-certificates zip unzip xz-utils cabextract binutils icoutils desktop-file-utils xdg-utils
    shared-mime-info gcc make flex bison pkg-config gcc-mingw-w64-x86-64 fonts-open-sans fonts-dejavu-core
    fonts-liberation fonts-liberation-sans-narrow fonts-noto-core fonts-noto-cjk"
# Altium versions tested with this setup ("- 21.5.1" lines); others get a warning.
TESTED_VERSIONS="$(sed -n 's/^- *\([0-9][0-9.]*\).*/\1/p' "$SCRIPT_DIR/tested_altium_versions.md" 2>/dev/null | paste -sd' ' -)"
# Made by the menu's "Prepare offline install": the downloads setup needs (other than apt packages).
# When it's there, setup takes them from it instead of the network.
OFFLINE_DIR="$SCRIPT_DIR/offline-cache"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/altium-linux"
OLD_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/altium-21-linux"
[[ -e "$CACHE_DIR" || ! -d "$OLD_CACHE_DIR" ]] || mv "$OLD_CACHE_DIR" "$CACHE_DIR"
# Shared by all Altium versions (also read by install-desktop.sh)
FILETYPES_LIST="${XDG_DATA_HOME:-$HOME/.local/share}/altium-linux/filetypes.list"
OLD_FILETYPES_LIST="${XDG_DATA_HOME:-$HOME/.local/share}/altium21/filetypes.list"
if [[ ! -e "$FILETYPES_LIST" && -f "$OLD_FILETYPES_LIST" ]]; then
    mkdir -p "$(dirname "$FILETYPES_LIST")" && cp "$OLD_FILETYPES_LIST" "$FILETYPES_LIST"
fi
# Windows fonts Altium asks for, and the free Linux fonts Wine substitutes for them (Wine font
# replacements). Without them, text that Altium draws in one of these fonts by name shows boxes, e.g. the
# hyphen in "All - On" and the icon next to the cloud button.
FONT_REPLACEMENTS="Segoe UI=Open Sans
Segoe UI Symbol=DejaVu Sans
Microsoft Sans Serif=Liberation Sans
Arial Narrow=Liberation Sans Narrow
Ebrima=Noto Sans Ethiopic
Yu Gothic UI=Noto Sans CJK JP
Yu Gothic=Noto Sans CJK JP
Meiryo UI=Noto Sans CJK JP
Meiryo=Noto Sans CJK JP
Microsoft JhengHei UI=Noto Sans CJK TC
Microsoft JhengHei=Noto Sans CJK TC
Microsoft YaHei UI=Noto Sans CJK SC
Microsoft YaHei=Noto Sans CJK SC
Malgun Gothic=Noto Sans CJK KR"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

usage() { sed -n '2,/^$/p' "$0" | sed '/SPDX-License-Identifier/d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer) INSTALLER="$2"; shift 2 ;;
        --user-data) WINDOWS_EXPORT="$2"; shift 2 ;;
        --prefs-from-prefix) PREFS_PREFIX="$2"; shift 2 ;;
        --license) LICENSE="$2"; shift 2 ;;
        --no-filetypes) REGISTER_FILETYPES=0; shift ;;
        --no-desktop-icon) DESKTOP_ICON=0; CLI_SET+=" desktop_icon"; shift ;;
        --keep-splash) DISABLE_SPLASH=0; CLI_SET+=" disable_splash"; shift ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --link) LINKS+=("$2"); shift 2 ;;
        --drive) DRIVES+=("$2"); shift 2 ;;
        --prefix) PREFIX="$2"; PREFIX_GIVEN=1; shift 2 ;;
        --data-dir) DATA_DIR_OPT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) warn "unknown option: $1"; usage 1 ;;
    esac
done

# C:\foo\bar -> $DRIVE_C/foo/bar
# Windows paths are case-insensitive and Linux paths aren't: each component is matched to an existing
# entry regardless of case (e.g. C:\altium\AD21 -> drive_c/Altium/AD21).
winpath() {
    local p="${1#[Cc]:}" cur="$DRIVE_C" part match
    local -a parts
    p="${p//\\//}"
    IFS=/ read -ra parts <<< "${p#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ ! -e "$cur/$part" && -d "$cur" ]]; then
            match="$(find "$cur" -mindepth 1 -maxdepth 1 -iname "$part" -print -quit 2>/dev/null || true)"
            [[ -z "$match" ]] || { cur="$match"; continue; }
        fi
        cur="$cur/$part"
    done
    printf '%s' "$cur"
}

# The prefix of an earlier install: the one Altium's file types open in (they're associated with
# altium<NN>.desktop, which runs the altium<NN> launcher), or failing that the newest launcher's. Empty if none.
installed_prefix() {
    local app entry launcher p
    launcher="$(ls -d "$HOME"/.local/bin/altium[0-9]* 2>/dev/null | sort -V | tail -1)"
    app="$(xdg-mime query default application/x-altium-schdoc 2>/dev/null || true)"
    entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$app"
    if [[ -n "$app" && -f "$entry" ]]; then
        p="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$entry" | head -1)"
        [[ ! -f "$p" ]] || launcher="$p"
    fi
    p="$(sed -n 's/^export WINEPREFIX="\(.*\)"$/\1/p' "$launcher" 2>/dev/null || true)"
    [[ -n "$p" && -f "$p/system.reg" ]] || return 0
    printf '%s' "$p"
}

# A file setup downloads: from offline-cache if it's there, else from the cache folder, else downloaded
# into the cache folder. Checked against SHA256 if given. Prints the local path.
fetch() {   # <file name> <URL> <SHA256 or "">
    local name="$1" url="$2" sum="$3" f
    for f in "$OFFLINE_DIR/$name" "$CACHE_DIR/$name"; do
        [[ -f "$f" ]] || continue
        [[ -z "$sum" ]] || echo "$sum  $f" | sha256sum -c --quiet - >&2 || { echo "checksum mismatch: $f" >&2; return 1; }
        printf '%s' "$f"
        return 0
    done
    mkdir -p "$CACHE_DIR"
    f="$CACHE_DIR/$name"
    wget -q -O "$f.part" "$url" || { rm -f "$f.part"; echo "couldn't download $url" >&2; return 1; }
    [[ -z "$sum" ]] || echo "$sum  $f.part" | sha256sum -c --quiet - >&2 \
        || { rm -f "$f.part"; echo "checksum mismatch: $url" >&2; return 1; }
    mv "$f.part" "$f"
    printf '%s' "$f"
}

wine_source_url() {   # <Wine version>
    case "$1" in
        *.0) echo "https://dl.winehq.org/wine/source/$1/wine-$1.tar.xz" ;;
        *) echo "https://dl.winehq.org/wine/source/${1%%.*}.x/wine-$1.tar.xz" ;;
    esac
}

dxvk_url() { echo "https://github.com/doitsujin/dxvk/releases/download/v$DXVK_VERSION/dxvk-$DXVK_VERSION.tar.gz"; }

# Pinned winetricks. The distribution's package depends on its own wine.
WINETRICKS=""
get_winetricks() {
    [[ -n "$WINETRICKS" ]] || WINETRICKS="$(fetch "winetricks-$WINETRICKS_VERSION" \
        "https://raw.githubusercontent.com/Winetricks/winetricks/$WINETRICKS_VERSION/src/winetricks" "$WINETRICKS_SHA256")"
}
winetricks() { get_winetricks || return 1; sh "$WINETRICKS" "$@"; }

# ---- dependencies

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

missing_deps() {
    local p
    for p in $APT_PACKAGES winehq-stable; do
        pkg_installed "$p" || echo "$p"
    done
    [[ -f "$OFFLINE_DIR/winetricks-$WINETRICKS_VERSION" || -f "$CACHE_DIR/winetricks-$WINETRICKS_VERSION" ]] \
        || echo "winetricks"
}

plan_deps() {
    local p
    . /etc/os-release
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    command -v apt-get >/dev/null || die "only apt-based distributions (Debian/Ubuntu/Mint) are supported"
    [[ -n "$CODENAME" ]] || die "can't determine the distribution codename"
    NEED_PKGS=()
    for p in $APT_PACKAGES; do
        pkg_installed "$p" || NEED_PKGS+=("$p")
    done
    pkg_installed winehq-stable || NEED_PKGS+=(winehq-stable)
    # Distribution Wine packages conflict with WineHQ's.
    REMOVE_PKGS=()
    if ! pkg_installed winehq-stable; then
        for p in wine wine64 wine32:i386 libwine libwine:i386 fonts-wine wine-binfmt wine64-preloader wine32-preloader:i386 winetricks; do
            pkg_installed "$p" && REMOVE_PKGS+=("$p")
        done
    fi
    ADD_I386=0 ADD_WINEHQ_REPO=0
    if ! pkg_installed winehq-stable; then
        dpkg --print-foreign-architectures | grep -qx i386 || ADD_I386=1
        [[ -f "/etc/apt/sources.list.d/winehq-$CODENAME.sources" ]] || ADD_WINEHQ_REPO=1
    fi
    NEED_WINETRICKS=0
    [[ -f "$OFFLINE_DIR/winetricks-$WINETRICKS_VERSION" || -f "$CACHE_DIR/winetricks-$WINETRICKS_VERSION" ]] || NEED_WINETRICKS=1
}

deps_summary() {
    [[ $ADD_I386 -eq 0 ]] || echo "- Enable i386 architecture"
    [[ $ADD_WINEHQ_REPO -eq 0 ]] || echo "- Add WineHQ apt repository ($CODENAME)"
    [[ ${#REMOVE_PKGS[@]} -eq 0 ]] || echo "- Remove distribution Wine packages: ${REMOVE_PKGS[*]}"
    [[ ${#NEED_PKGS[@]} -eq 0 ]] || echo "- Install apt packages: ${NEED_PKGS[*]}"
    [[ $NEED_WINETRICKS -eq 0 ]] || echo "- Download winetricks $WINETRICKS_VERSION"
    return 0
}

install_deps() {   # [1: don't ask]
    plan_deps
    [[ -n "$(deps_summary)" ]] || return 0
    if [[ "${1:-0}" -ne 1 ]]; then
        info "System changes needed (uses sudo):"
        deps_summary
        confirm "Proceed?" || die "aborted"
    fi
    if [[ ${#NEED_PKGS[@]} -gt 0 || ${#REMOVE_PKGS[@]} -gt 0 || $ADD_I386 -eq 1 || $ADD_WINEHQ_REPO -eq 1 ]]; then
        if [[ $ADD_I386 -eq 1 ]]; then
            sudo dpkg --add-architecture i386
        fi
        if [[ $ADD_WINEHQ_REPO -eq 1 ]]; then
            pkg_installed wget || sudo apt-get install -y wget ca-certificates
            sudo mkdir -pm755 /etc/apt/keyrings
            sudo wget -q -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
            sudo wget -q -NP /etc/apt/sources.list.d/ \
                "https://dl.winehq.org/wine-builds/ubuntu/dists/$CODENAME/winehq-$CODENAME.sources" \
                || die "WineHQ has no repository for '$CODENAME'"
        fi
        if [[ ${#REMOVE_PKGS[@]} -gt 0 ]]; then
            sudo apt-get remove -y "${REMOVE_PKGS[@]}"
        fi
        sudo apt-get update
        if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
            # winehq-stable needs its recommends (wine-stable-i386 etc.)
            sudo apt-get install -y --install-recommends "${NEED_PKGS[@]}"
        fi
    fi
    info "winetricks $WINETRICKS_VERSION"
    get_winetricks || die "couldn't get winetricks $WINETRICKS_VERSION"
}

# The menu's "Prepare offline install": puts everything setup downloads, other than apt packages, into
# offline-cache next to setup.sh: the Wine source (for d2d1.dll), DXVK, winetricks and its downloads
# (the Microsoft runtimes and fonts). Files already in the local caches are copied, the rest are
# downloaded. winetricks can only download by installing, so missing winetricks files are fetched by
# installing those verbs into a temporary prefix (which needs wine here).
prepare_offline() {
    local wt="$OFFLINE_DIR/winetricks" user_wt="${XDG_CACHE_HOME:-$HOME/.cache}/winetricks" f d missing tmp
    mkdir -p "$wt"
    echo "Wine $WINE_VERSION_EXPECTED source"
    f="$(fetch "wine-$WINE_VERSION_EXPECTED.tar.xz" "$(wine_source_url "$WINE_VERSION_EXPECTED")" "$WINE_SRC_SHA256")" || return 1
    [[ "$f" == "$OFFLINE_DIR/"* ]] || cp "$f" "$OFFLINE_DIR/"
    echo "DXVK $DXVK_VERSION"
    f="$(fetch "dxvk-$DXVK_VERSION.tar.gz" "$(dxvk_url)" "$DXVK_SHA256")" || return 1
    [[ "$f" == "$OFFLINE_DIR/"* ]] || cp "$f" "$OFFLINE_DIR/"
    echo "winetricks $WINETRICKS_VERSION"
    get_winetricks || return 1
    [[ "$WINETRICKS" == "$OFFLINE_DIR/"* ]] || cp "$WINETRICKS" "$OFFLINE_DIR/"
    # winetricks' own cache folders for these verbs and the ones they pull in
    for d in corefonts vcrun2019 ucrtbase2019 dotnet48 dotnet40 win7sp1 msxml6; do
        [[ ! -d "$user_wt/$d" ]] || cp -r --update=none "$user_wt/$d" "$wt/"
    done
    missing="$(comm -23 <(tr ' ' '\n' <<< "$WINETRICKS_VERBS" | sort) <(W_CACHE="$wt" winetricks list-cached 2>/dev/null | sort))"
    if [[ -n "$missing" ]]; then
        command -v wine >/dev/null || { echo "wine is needed to download: $(echo $missing)"; return 1; }
        echo "winetricks downloads (by installing into a temporary prefix): $(echo $missing)"
        tmp="$(mktemp -d)"
        WINEPREFIX="$tmp/prefix" WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES='mscoree=d;mshtml=d;winemenubuilder.exe=d' \
            wineboot -i >/dev/null 2>&1
        WINEPREFIX="$tmp/prefix" WINEDEBUG=-all W_CACHE="$wt" winetricks -q $missing || true
        WINEPREFIX="$tmp/prefix" wineserver -k 2>/dev/null || true
        rm -rf "$tmp"
        missing="$(comm -23 <(tr ' ' '\n' <<< "$WINETRICKS_VERBS" | sort) <(W_CACHE="$wt" winetricks list-cached 2>/dev/null | sort))"
        [[ -z "$missing" ]] || { echo "still missing: $(echo $missing)"; return 1; }
    fi
    echo "Done: $OFFLINE_DIR ($(du -sh "$OFFLINE_DIR" | cut -f1))"
}

# ---- user data archives
#
# A user data archive (export-windows.ps1 on Windows, or the menu's Export user data) holds what you
# made or changed in an Altium install, not its program files, caches or license (see apply_license):
#   build.txt   build_key=Altium Designer {GUID} of the install it came from (and version=)
#   hkcu.reg    its preferences: HKCU\Software\Altium\<build key> (UTF-16 registry export), without
#               NetworkLicenseUsage (the activation key)
#   settings/   from AppData\Roaming\Altium\<build>: editor defaults (*.DFT, *.MMsdft, *.MbsDft,
#               *.PCBDwf), menus and shortcuts (DXP.RAF), user tools (UserTools.TLT), color schemes
#               (ViewConfigurations) and the last workspace
#   userdata/   ProgramData\Altium\<build>\UserData (dictionaries)
USER_DATA_SETTINGS=(-iname '*.dft' -o -iname '*.mmsdft' -o -iname '*.mbsdft' -o -iname '*.pcbdwf' -o -iname DXP.RAF
    -o -iname UserTools.TLT -o -iname ViewConfigurations -o -iname LastWorkspace)

unpack_user_data() {   # <zip> <dir>
    mkdir -p "$2"
    # Exit status 1 is a warning (PowerShell's Compress-Archive uses backslash separators, which unzip converts).
    unzip -q -o "$1" -d "$2" 2>/dev/null || [[ $? -eq 1 ]] || { echo "couldn't unpack $1" >&2; return 1; }
    # Windows attributes can come through as directories without owner write/search permission.
    chmod -R u+rwX "$2"
    [[ -f "$2/build.txt" ]] || { echo "$1 isn't a user data archive (no build.txt)" >&2; return 1; }
}

# Writes the user data of the Altium build <GUID> in <prefix> to <dir>, in the archive layout above.
export_user_data() {   # <prefix> <GUID> <dir>
    local p="$1" key="Altium Designer {$2}" out="$3"
    mkdir -p "$out/settings" "$out/userdata"
    printf 'build_key=%s\nversion=%s\n' "$key" "$(build_version "$p" "$2")" > "$out/build.txt"
    WINEPREFIX="$p" WINEDEBUG=-all wine reg export "HKCU\\Software\\Altium\\$key" "$(zpath "$out/hkcu.reg")" /y \
        >/dev/null 2>&1 || { echo "couldn't export the preferences of $key" >&2; return 1; }
    iconv -f UTF-16LE -t UTF-8 "$out/hkcu.reg" | tr -d '\r' | sed '1s/^\xef\xbb\xbf//' | no_license_keys \
        | sed 's/$/\r/' | iconv -f UTF-8 -t UTF-16LE > "$out/hkcu.body"
    { printf '\xff\xfe'; cat "$out/hkcu.body"; } > "$out/hkcu.reg"
    rm "$out/hkcu.body"
    # (-L: the folders can be links into DATA_DIR or elsewhere)
    find -L "$p/drive_c/users/$USER/AppData/Roaming/Altium/$key" -mindepth 1 -maxdepth 1 \( "${USER_DATA_SETTINGS[@]}" \) \
        -exec cp -rL {} "$out/settings/" \; 2>/dev/null || true
    cp -rL "$p/drive_c/ProgramData/Altium/$key/UserData/." "$out/userdata/" 2>/dev/null || true
}

# Folders in imported preferences ("Template Path", SVN working copies) on mapped drives (M:\...)
# that don't exist: created in the drive's Linux folder, so Altium doesn't ask at startup. C: paths
# are left alone.
create_drive_paths() {   # <prefix> <UTF-8 .reg file>
    local p="$1" win d root
    while IFS= read -r win; do
        [[ "$win" =~ ^([A-Za-z]):(.*) && "${win:0:1}" != [Cc] ]] || continue
        root="$p/dosdevices/${win:0:1}"
        root="${root,,}:"
        if [[ ! -L "$root" ]]; then
            echo "WARNING: $win: drive ${win:0:1}: not mapped"
        elif [[ ! -d "$root/" ]]; then
            echo "WARNING: $win: $(readlink "$root") doesn't exist"
        else
            d="$(DRIVE_C="$(readlink -f "$root")" winpath "C:${BASH_REMATCH[2]}")"
            [[ -e "$d" ]] || { mkdir -p "$d" && echo "Created $win"; }
        fi
    done < <(grep -E '^"(Template Path|SVNDefaultWorkingCopy[0-9]+)"="[A-Za-z]:' "$2" \
        | sed 's/^"[^"]*"="//; s/"$//; s/\\\\/\\/g' | sort -u)
}

# Altium's default document folder ("Default Open Path") is the home folder (as a Z: path).
set_open_path() {   # <prefix> <build key>
    WINEPREFIX="$1" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' wine reg add \
        "HKCU\\Software\\Altium\\$2\\DesignExplorer\\Preferences\\WorkspaceManager\\Workspace Preferences" \
        /v "Default Open Path" /d "$(zpath "$HOME")" /f >/dev/null 2>&1
    echo "Default document path: $HOME"
}

# Altium's auto-save backups ("Default Recovery Path") go to DATA_DIR/altium-backup, with the other
# Altium data folders on the Linux side (as a Z: path).
set_recovery_path() {   # <prefix> <build key>
    local dir
    dir="$(realpath -m "$(expand_path "$DATA_DIR")")/altium-backup"
    mkdir -p "$dir"
    WINEPREFIX="$1" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' wine reg add \
        "HKCU\\Software\\Altium\\$2\\DesignExplorer\\Preferences\\WorkspaceManager\\Workspace Preferences" \
        /v "Default Recovery Path" /d "$(zpath "$dir")" /f >/dev/null 2>&1
    echo "Recovery backups: $dir"
}

# Altium's local history ("GlobalRepositoryPath") goes to DATA_DIR/history.
set_history_path() {   # <prefix> <build key>
    local dir
    dir="$(realpath -m "$(expand_path "$DATA_DIR")")/history"
    mkdir -p "$dir"
    WINEPREFIX="$1" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' wine reg add \
        "HKCU\\Software\\Altium\\$2\\DesignExplorer\\Preferences\\VersionControl\\LocalHistory" \
        /v GlobalRepositoryPath /d "$(zpath "$dir")" /f >/dev/null 2>&1
    echo "Local history: $dir"
}

# Registry export (UTF-8) without the NetworkLicenseUsage keys (the activation key).
no_license_keys() { awk 'BEGIN { keep = 1 } /^\[/ { keep = index($0, "\\NetworkLicenseUsage") == 0 } keep'; }

# Imports unpacked user data into the Altium build <GUID> in <prefix>: the preferences, renamed from the
# source install's GUID to this one's (Altium keys them by install), and the files, replacing ones
# of the same name. Altium should be closed (it writes its settings on exit).
import_user_data() {   # <dir> <prefix> <GUID>
    local src="$1" p="$2" guid="$3" key="Altium Designer {$3}" old_key old_guid tmp
    old_key="$(tr -d '\r' < "$src/build.txt" | sed -n 's/^build_key=//p')"
    old_guid="$(grep -o '[0-9A-Fa-f-]\{36\}' <<< "$old_key" | head -1)"
    [[ -n "$old_guid" ]] || { echo "no build key in $src/build.txt" >&2; return 1; }
    if [[ -f "$src/hkcu.reg" ]]; then
        tmp="$(mktemp -d)"
        {
            echo 'Windows Registry Editor Version 5.00'
            echo
            # only that build's keys, renamed to this install's GUID
            iconv -f UTF-16LE -t UTF-8 "$src/hkcu.reg" | tr -d '\r' \
                | awk -v g="$old_guid" '/^\[/ { keep = index($0, g) > 0 } keep' | no_license_keys | sed "s/$old_guid/$guid/g"
        } > "$tmp/prefs.utf8.reg"
        sed 's/$/\r/' "$tmp/prefs.utf8.reg" | iconv -f UTF-8 -t UTF-16LE > "$tmp/body.reg"
        { printf '\xff\xfe'; cat "$tmp/body.reg"; } > "$tmp/prefs.reg"
        WINEPREFIX="$p" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' \
            wine reg import "$(zpath "$tmp/prefs.reg")" /reg:64 >/dev/null 2>&1 \
            || { rm -rf "$tmp"; echo "couldn't import the preferences" >&2; return 1; }
        echo "Preferences of $old_key"
        create_drive_paths "$p" "$tmp/prefs.utf8.reg"
        set_open_path "$p" "$key"
        set_recovery_path "$p" "$key"
        set_history_path "$p" "$key"
        # imported preferences carry their own splash setting
        [[ "$DISABLE_SPLASH" -ne 1 ]] || WINEPREFIX="$p" no_splash "$key"
        rm -rf "$tmp"
    fi
    # not recovery backups (Recovery/ in older archives)
    if [[ -n "$(find "$src/settings" -mindepth 1 -maxdepth 1 ! -iname Recovery 2>/dev/null)" ]]; then
        mkdir -p "$p/drive_c/users/$USER/AppData/Roaming/Altium/$key"
        find "$src/settings" -mindepth 1 -maxdepth 1 ! -iname Recovery \
            -exec cp -r {} "$p/drive_c/users/$USER/AppData/Roaming/Altium/$key/" \;
        echo "Settings: $(ls "$src/settings" | grep -vix recovery | paste -sd, - | sed 's/,/, /g')"
    fi
    if [[ -n "$(ls -A "$src/userdata" 2>/dev/null)" ]]; then
        mkdir -p "$p/drive_c/ProgramData/Altium/$key/UserData"
        cp -r "$src/userdata/." "$p/drive_c/ProgramData/Altium/$key/UserData/"
        echo "User data: $(ls "$src/userdata" | paste -sd, - | sed 's/,/, /g')"
    fi
}

# Turns off Altium's splash screen for a build ("Altium Designer {GUID}") in the current WINEPREFIX.
no_splash() {   # <build key>
    wine reg add "HKCU\\Software\\Altium\\$1\\DesignExplorer\\Preferences\\Client\\Client Preferences" \
        /v "Suppress Startup Screen" /t REG_SZ /d 1 /f >/dev/null 2>&1
}

# Versions of all Altium Designer builds registered in a prefix, one per line (e.g. 17.1.9.592). Older
# versions record it as FullBuild/Build, newer ones also as Version.
altium_versions() {   # <prefix>
    awk '/^\[Software\\\\Altium\\\\Builds\\\\Altium Designer \{/ { if (v != "") print v; on = 1; v = ""; f = ""; b = ""; next }
         /^\[/ { if (on && (f != "" || b != "" || v != "")) print (f != "" ? f : b != "" ? b : v); on = 0; f = b = v = ""; next }
         on && /^"FullBuild"="/ { f = $0; sub(/^"FullBuild"="/, "", f); sub(/"$/, "", f) }
         on && /^"Build"="/ { b = $0; sub(/^"Build"="/, "", b); sub(/"$/, "", b) }
         on && /^"Version"="/ { v = $0; sub(/^"Version"="/, "", v); sub(/"$/, "", v) }
         END { if (on && (f != "" || b != "" || v != "")) print (f != "" ? f : b != "" ? b : v) }' "$1/system.reg" 2>/dev/null
}

# Wine prefixes under the home folder (folders with system.reg and drive_c), one per line.
detect_prefixes() {
    find "$HOME" -maxdepth 4 \( -name .cache -o -name node_modules -o -name .git \) -prune \
        -o -name system.reg -printf '%h\n' 2>/dev/null | while read -r d; do
            [[ ! -d "$d/drive_c" ]] || printf '%s\n' "$d"
        done | sort -u
}

[[ -n "$PREFIX" ]] || PREFIX="$(installed_prefix)"

# ~/.wine-altium<NN> for the Altium version in an installer's name (as the menu's prefix field does)
installer_prefix() {   # <installer>
    if [[ "$(basename "${1,,}")" =~ designer[^0-9]{0,12}([0-9]{2})([^0-9]|$) ]]; then
        echo "$HOME/.wine-altium${BASH_REMATCH[1]}"
    else
        echo "$HOME/.wine-altium"
    fi
}

# Linux path -> Z:\path
zpath() { printf 'Z:%s' "$(tr / '\\' <<< "$1")"; }

# Prints "Version<TAB>GUID<TAB>ProgramsInstallPath" for each Altium Designer build in a prefix's system.reg.
all_builds() {   # <prefix>
    awk '
        /^\[Software\\\\Altium\\\\Builds\\\\Altium Designer \{/ {
            match($0, /\{[0-9A-Fa-f-]+\}/); guid = substr($0, RSTART + 1, RLENGTH - 2); v = ""; p = ""; done = 0; next
        }
        /^\[/ { guid = "" }
        guid != "" && /^"Version"=/ { v = $0; sub(/^"Version"="/, "", v); sub(/"$/, "", v) }
        guid != "" && /^"ProgramsInstallPath"=/ { p = $0; sub(/^"ProgramsInstallPath"="/, "", p); sub(/"$/, "", p); gsub(/\\\\/, "\\", p) }
        guid != "" && v != "" && p != "" && !done { print v "\t" guid "\t" p; done = 1 }
    ' "$1/system.reg" 2>/dev/null
}

# Prints "GUID<TAB>ProgramsInstallPath" for the build <GUID> if given, else the newest version.
find_build() {   # <prefix> [GUID]
    all_builds "$1" | awk -F'\t' -v want="${2:-}" 'want == "" || toupper($2) == toupper(want)' | sort -V | tail -1 | cut -f2-
}

# Version of the build <GUID> in <prefix> (e.g. 21.5.1.42)
build_version() {   # <prefix> <GUID>
    K="[Software\\\\Altium\\\\Builds\\\\Altium Designer {$2}]" awk \
        'index(toupper($0), toupper(ENVIRON["K"])) == 1 { on = 1; next } /^\[/ { on = 0 }
         on && /^"Version"="/ { v = $0; sub(/^"Version"="/, "", v); sub(/"$/, "", v); print v; exit }' "$1/system.reg"
}

# Sets AD_MAJOR and the names that follow it.
set_version() {   # <version>
    AD_MAJOR="${1%%.*}"
    DATA_DIR="${DATA_DIR_OPT:-${XDG_DATA_HOME:-$HOME/.local/share}/altium$AD_MAJOR}"
    DATA_DIR="$(realpath -m "$(expand_path "$DATA_DIR")")"
}

# ---------------------------------------------------------------- uninstall
#
# Removes the Wine prefix and the Linux desktop integration (file types, menu entry, launcher, icons).
# Keeps DATA_DIR (settings, logs, ProgramData, license; symlinked from the prefix, so deleting the
# prefix only removes the links) and the build cache.

# Processes (other than wineserver) running in a prefix.
prefix_processes() {
    local p="$1" pid
    for pid in $(pgrep -u "$(id -u)" 2>/dev/null); do
        # Some processes' environments aren't readable even for the same user; skip those.
        { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | grep -qxF "WINEPREFIX=$p" || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == wineserver ]] && continue
        tr '\0' ' ' < "/proc/$pid/cmdline"
        echo
    done
}

# Sets AD_MAJOR and DATA_DIR for the prefix's Altium (or the launcher that runs it), and LAUNCHER_PREFIX
# to the prefix the altium<NN> launcher runs.
uninstall_version() {   # <prefix>
    local p="$1" build l
    build="$(find_build "$p")"
    if [[ -n "$build" ]]; then
        set_version "$(build_version "$p" "${build%%$'\t'*}")"
    else
        for l in "$HOME"/.local/bin/altium[0-9]*; do
            grep -qxF "export WINEPREFIX=\"$p\"" "$l" 2>/dev/null && set_version "${l##*altium}" && break
        done
    fi
    LAUNCHER_PREFIX=""
    [[ -z "$AD_MAJOR" ]] || LAUNCHER_PREFIX="$(sed -n 's/^export WINEPREFIX="\(.*\)"$/\1/p' "$HOME/.local/bin/altium$AD_MAJOR" 2>/dev/null || true)"
}

uninstall_summary() {   # <prefix>
    local p="$1"
    uninstall_version "$p"
    echo "Remove:"
    echo "  - Wine prefix $p"
    if [[ -z "$AD_MAJOR" ]]; then
        :
    elif [[ -z "$LAUNCHER_PREFIX" || "$LAUNCHER_PREFIX" == "$p" ]]; then
        echo "  - Altium file types and document icons, default-app entries (restoring earlier choices)"
        echo "  - Altium menu entry, desktop icon, altium$AD_MAJOR launcher and app icon"
    else
        echo "  (the altium$AD_MAJOR launcher and file types belong to $LAUNCHER_PREFIX and are kept)"
    fi
    echo "Keep:"
    [[ -z "$DATA_DIR" ]] || echo "  - $DATA_DIR (settings, logs, ProgramData, license)"
    echo "  - $CACHE_DIR (Wine source and built d2d1.dll)"
}

do_uninstall() {   # <prefix> <already confirmed: 0|1>
    local p="$1" confirmed="$2" running
    [[ -f "$p/system.reg" && -d "$p/drive_c" ]] || die "$p doesn't look like a Wine prefix; not removing it"
    [[ "$p" != / && "$p" != "$HOME" && "$p" != "$(realpath -m "$HOME")" ]] || die "refusing to remove $p"
    running="$(prefix_processes "$p")"
    [[ -z "$running" ]] || die "programs are still running in $p; close Altium first:
$running"

    if [[ "$confirmed" -ne 1 && "$ASSUME_YES" -ne 1 ]]; then
        uninstall_summary "$p"
        confirm "Uninstall?" || die "aborted"
    fi

    WINEPREFIX="$p" wineserver -k 2>/dev/null || true
    uninstall_version "$p"
    if [[ -z "$AD_MAJOR" ]]; then
        :
    elif [[ -z "$LAUNCHER_PREFIX" || "$LAUNCHER_PREFIX" == "$p" ]]; then
        "$SCRIPT_DIR/install-desktop.sh" --version "$AD_MAJOR" --uninstall "$p"
    else
        info "Keeping the launcher and file types; they belong to $LAUNCHER_PREFIX"
    fi
    info "Removing $p"
    # Data folders inside the prefix are symlinks to DATA_DIR; rm -rf removes the links, not their targets.
    chmod -R u+rwX "$p" 2>/dev/null || true
    rm -rf "$p"
    info "Uninstalled. Kept ${DATA_DIR:+$DATA_DIR and }$CACHE_DIR."
}

# ---------------------------------------------------------------- interactive settings

# ---- settings.yml

setting() {   # <key>
    local v
    v="$(sed -n "s/^$1: *//p" "$SETTINGS_FILE" 2>/dev/null | head -1)"
    if [[ "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; v="${v//\'\'/\'}"; fi
    printf '%s' "$v"
}
setting_list() {   # <key>; one item per line
    local v
    sed -n "/^$1:/,/^[^ ]/s/^  - *//p" "$SETTINGS_FILE" 2>/dev/null | while IFS= read -r v; do
        if [[ "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; v="${v//\'\'/\'}"; fi
        printf '%s\n' "$v"
    done
}
bool_setting() {   # <key> <default 0|1>
    case "$(setting "$1")" in true) echo 1 ;; false) echo 0 ;; *) echo "$2" ;; esac
}
yaml_bool() { [[ "$1" -eq 1 ]] && echo true || echo false; }
yaml_str() { local q="'"; printf "'%s'" "${1//$q/$q$q}"; }

save_settings() {   # interactive_settings' fields
    cat > "$SETTINGS_FILE.new" <<EOF
# Saved by setup.sh
installer: $(yaml_str "$inst_field")
prefix: $(yaml_str "$pfx_field")
desktop_icon: $(yaml_bool "$DESKTOP_ICON")
disable_splash: $(yaml_bool "$DISABLE_SPLASH")
license: $(yaml_str "$lic_field")
activation_key: $(yaml_str "$code_field")
user_data: $(yaml_str "$userdata_field")
drives:
$(for d in ${DRIVES[@]+"${DRIVES[@]}"}; do echo "  - $(yaml_str "$d")"; done)
EOF
    mv "$SETTINGS_FILE.new" "$SETTINGS_FILE"
}

# Activation code from Altium's license file naming (..._XXXX-XXXX.alf), if present.
code_from_name() { basename "$1" | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' | tail -1 || true; }

expand_path() { local p="$1"; [[ "$p" != "~"* ]] || p="$HOME${p:1}"; printf '%s' "$p"; }

# The interactive screens are drawn by src/tui.py: whiptail-style boxes without buttons, each listing
# its keys along the bottom.
tui() { python3 "$SCRIPT_DIR/src/tui.py" "$@" 3>&1 1>&2; }
list_menu() { tui menu "$@"; }    # <title> <text> [options] -- <tag> <item> ...; prints "select TAG"/"delete TAG"
ui_message() { tui message "$1" "$2" >/dev/null || true; }    # <title> <text>
ui_confirm() { tui confirm "$1" "$2" >/dev/null; }           # <title> <text>; y succeeds, n/Esc fails

can_browse() { [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null; }

# ui_pick <file|dir> <title> <current> [zenity --file-filter args...]: graphical file chooser. Prints the path.
ui_pick() {
    local kind="$1" title="$2" cur="$3" args
    shift 3
    args=(--file-selection --title="$title")
    [[ "$kind" != dir ]] || args+=(--directory)
    [[ -z "$cur" ]] || args+=(--filename="$cur")
    zenity "${args[@]}" "$@" 2>/dev/null
}

# path_input <file|dir|newdir|installer>[?] <title> <text> <current> [zenity --file-filter args...]
# Text field for a path (~ works); with "?", an empty field is accepted too (prints nothing).
# "newdir" accepts a folder that may not exist yet; "installer" accepts a .zip or .exe file. PATH_NOTE, if set, is shown in red under the text. Ctrl+O opens the file chooser (when zenity is available) and returns
# to the field with the chosen path. Prints the path once it names an existing file/folder.
path_input() {
    local kind="$1" title="$2" text="$3" cur="$4" res path browse=()
    shift 4
    ! can_browse || browse=(--browse)
    while true; do
        res="$(tui input "$title" "$text" "$cur" ${browse[@]+"${browse[@]}"} ${PATH_NOTE:+--note "$PATH_NOTE"})" || return 1
        path="$(expand_path "${res#* }")"
        if [[ "$res" == browse\ * ]]; then
            # Start the chooser in the folder typed so far (or its parent, for a folder not created yet).
            [[ -z "$path" || -e "$path" ]] || path="$(dirname "$path")"
            [[ ! -d "$path" ]] || path="${path%/}/"
            cur="$(ui_pick "$([[ ${kind%\?} == *dir ]] && echo dir || echo file)" "$title" "${path:-$HOME/}" "$@")" || cur="${res#* }"
            continue
        fi
        [[ "$kind" != *\? || -n "${res#* }" ]] || return 0
        case "${kind%\?}" in
            file) [[ ! -f "$path" ]] || { realpath "$path"; return 0; } ;;
            dir) [[ ! -d "$path" ]] || { realpath "$path"; return 0; } ;;
            newdir)
                if [[ -n "$path" && ! -e "$path" || -d "$path" ]]; then
                    realpath -m "$path"
                    return 0
                fi
                [[ -z "$path" ]] || { ui_message "$title" "Not a folder: $path"; cur="${res#* }"; continue; }
                ;;
            installer)
                if [[ -f "$path" && "${path,,}" =~ \.(zip|exe)$ ]]; then
                    realpath "$path"
                    return 0
                fi
                if [[ -e "$path" ]]; then
                    ui_message "$title" "Not a .zip or .exe file: $path"
                    cur="${res#* }"
                    continue
                fi
                ;;
        esac
        ui_message "$title" "Not found: ${path:-(empty)}"
        cur="${res#* }"
    done
}

DOS_DEVICES='HKLM\System\CurrentControlSet\Control\Session Manager\DOS Devices'

# Drive mappings stored in the registry instead ("M:"="\\??\\C:\\lib" under DOS Devices), as "M:=C:\lib".
registry_drives() {   # <prefix>
    awk 'index($0, "[") == 1 { on = (index($0, "[System\\\\CurrentControlSet\\\\Control\\\\Session Manager\\\\DOS Devices]") == 1); next }
         on && /^"[A-Za-z]:"="/ {
             v = substr($0, 7); sub(/"$/, "", v); gsub(/\\\\/, "\\", v); sub(/^\\\?\?\\/, "", v)
             print toupper(substr($0, 2, 2)) "=" v
         }' "$1/system.reg" 2>/dev/null
}

# Drive mappings of a prefix, as "M:=/linux/path" lines: dosdevices/<letter>: symlinks (like winecfg's
# Drives tab; C: is the prefix's own drive_c, "d::" entries are raw devices), and registry mappings,
# resolved to the Linux folder they end up at.
prefix_drives() {   # <prefix>
    local p="$1" l letter win drive
    for l in "$p"/dosdevices/[a-y]:; do
        [[ -L "$l" && "$(basename "$l")" != c: ]] || continue
        printf '%s=%s\n' "$(basename "${l^^}")" "$(readlink "$l")"
    done
    while IFS='=' read -r letter win; do
        [[ ! -L "$p/dosdevices/${letter,,}" ]] || continue
        [[ "$win" =~ ^[A-Za-z]: ]] || continue
        drive="${win:0:1}"
        printf '%s=%s\n' "$letter" "$(realpath -m "$(DRIVE_C="$(realpath -m "$p/dosdevices/${drive,,}:")" winpath "C:${win:2}")")"
    done < <(registry_drives "$p")
}

# Makes the prefix's drive mappings match DRIVES. With <sync> 1, mappings not in DRIVES are removed.
# Registry mappings for the letters involved are deleted; each mapping becomes a dosdevices symlink.
apply_drives() {   # <prefix> <sync>
    local p="$1" letter target d regs
    regs="$(registry_drives "$p" | cut -d= -f1)"
    if [[ "$2" -eq 1 ]]; then
        while IFS='=' read -r letter target; do
            [[ " ${DRIVES[*]+${DRIVES[*]}} " != *" $letter="* ]] || continue
            rm -f "$p/dosdevices/${letter,,}"
            echo "Removed drive $letter (was $target)"
        done < <(prefix_drives "$p")
    fi
    for d in ${DRIVES[@]+"${DRIVES[@]}"}; do
        letter="${d%%=*}" target="${d#*=}"
        [[ -d "$target" ]] || echo "warning: drive $letter: $target doesn't exist (yet)"
        ln -sfn "$target" "$p/dosdevices/${letter,,}"
        echo "Drive $letter -> $target"
    done
    for letter in $regs; do
        [[ "$2" -eq 1 || " ${DRIVES[*]+${DRIVES[*]}} " == *" $letter="* ]] || continue
        WINEPREFIX="$p" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' \
            wine reg delete "$DOS_DEVICES" /v "$letter" /f >/dev/null 2>&1 || true
    done
}

drive_letter_menu() {   # <current letter or ""> ; prints e.g. "M:"
    local cur="$1" letter used items=() d res
    for letter in D E F G H I J K L M N O P Q R S T U V W X Y; do
        used=""
        for d in ${DRIVES[@]+"${DRIVES[@]}"}; do
            [[ "${d%%:*}" != "$letter" || "$letter:" == "$cur" ]] || used=1
        done
        [[ -n "$used" ]] || items+=("$letter:" "$letter:\\")
    done
    res="$(list_menu "Drive letter" "Windows drive letter for the mapping:" --default "${cur:-M:}" -- "${items[@]}")" || return 1
    printf '%s' "${res#select }"
}

drives_menu() {
    local res i d letter path items default=""
    while true; do
        items=()
        for i in "${!DRIVES[@]}"; do
            d="${DRIVES[$i]}"
            items+=("$i" "${d%%=*}\\  ->  ${d#*=}")
        done
        items+=(add "Add new mapping")
        res="$(list_menu "Drive mappings" "Map Windows drive letter to a Linux folder
(Eg, M:\\ -> ~/library-altium)" --min-width 83 --deletable ${#DRIVES[@]} --del "delete mapping" ${default:+--default "$default"} \
            -- "${items[@]}")" || return 0
        default="${res#* }"
        case "$res" in
            "select add")
                letter="$(drive_letter_menu "")" || continue
                path="$(path_input dir "Drive $letter" "Linux folder for drive $letter, e.g. ~/library-altium:" "")" || continue
                DRIVES+=("$letter=$path")
                default=$(( ${#DRIVES[@]} - 1 ))
                ;;
            delete\ *)
                unset "DRIVES[$default]"
                DRIVES=(${DRIVES[@]+"${DRIVES[@]}"})
                ;;
            select\ *)
                i="$default" d="${DRIVES[$default]}"
                res="$(list_menu "Drive ${d%%=*}" "${d%%=*}\\  ->  ${d#*=}" -- \
                    folder "Change the Linux folder" letter "Change the drive letter" remove "Remove this mapping")" || continue
                case "$res" in
                    "select folder")
                        path="$(path_input dir "Drive ${d%%=*}" "Linux folder for drive ${d%%=*}:" "${d#*=}")" || continue
                        DRIVES[$i]="${d%%=*}=$path"
                        ;;
                    "select letter")
                        letter="$(drive_letter_menu "${d%%=*}")" || continue
                        DRIVES[$i]="$letter=${d#*=}"
                        ;;
                    "select remove")
                        unset "DRIVES[$i]"
                        DRIVES=(${DRIVES[@]+"${DRIVES[@]}"})
                        ;;
                esac
                ;;
        esac
    done
}

# The "Register file types" screen: a checkbox per file type in desktop/filetypes.txt (the two Gerber
# MIME types share one), checked as last chosen, or all of them the first time. The choice is saved
# where install-desktop.sh reads it (filetypes.list), so later runs register the same types.
choose_filetypes() {
    local list="$FILETYPES_LIST" items=() type ico desc exts on label res i
    local -a chosen
    while IFS=$'\t' read -r type ico desc exts; do
        [[ -n "$type" && "$type" != \#* && "$type" != application/vnd.gerber ]] || continue
        on=1
        [[ ! -f "$list" ]] || grep -qxF "$type" "$list" || on=0
        if [[ "$type" == application/x-gerber ]]; then
            label="Gerber files (.GBR, .GTL, .GBL, ...)"
        else
            label="$desc (.${exts// /, .})"
        fi
        items+=("$type" "$on" "$label")
    done < "$SCRIPT_DIR/desktop/filetypes.txt"
    while true; do
        res="$(tui checklist "Register file types" "" register -- "${items[@]}")" || return 1
        mapfile -t chosen <<< "$res"
        ui_confirm "Register file types" "Confirm file type registration?" && break
        # keep the choices for the next round
        for (( i = 0; i < ${#items[@]}; i += 3 )); do
            printf '%s\n' "${chosen[@]:1}" | grep -qxF "${items[i]}" && items[i + 1]=1 || items[i + 1]=0
        done
    done
    mkdir -p "$(dirname "$list")"
    printf '%s\n' "${chosen[@]:1}" | sed '/^$/d' > "$list"
    ! grep -qxF application/x-gerber "$list" || echo application/vnd.gerber >> "$list"
}

# Copies LICENSE into the install's license folder (ProgramData\Altium\<build>_Security, which setup
# links to DATA_DIR/license) and makes ACTIVATION_CODE (default: from the file name, which Altium gives
# as ..._XXXX-XXXX.alf) the license Altium uses at startup, without choosing it in License Management.
apply_license() {   # <prefix> <build GUID>
    local p="$1" key="Altium Designer {$2}" dir dst code="$ACTIVATION_CODE"
    dir="$p/drive_c/ProgramData/Altium/${key}_Security"
    mkdir -p "$dir"
    dst="$dir/$(basename "$LICENSE")"
    if [[ ! -e "$dst" || "$(readlink -f "$LICENSE")" != "$(readlink -f "$dst")" ]]; then
        rm -f "$dst"
        cp "$LICENSE" "$dst"
    fi
    echo "License file: $(readlink -f "$dir")/$(basename "$LICENSE")"
    [[ -n "$code" ]] || code="$(code_from_name "$LICENSE")"
    if [[ -n "$code" ]]; then
        WINEPREFIX="$p" WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d' wine reg add \
            "HKCU\\Software\\Altium\\$key\\DesignExplorer\\NetworkLicenseUsage" /v ActivationCode0 /d "$code" /f >/dev/null
        echo "Activation key $code set as the license Altium uses"
    fi
}

# For the menu's "Register file types": runs install-desktop.sh for the Altium install in PREFIX (launcher,
# menu entry, the file types chosen in filetypes.list) and shows the result.
register_filetypes() {   # <build (find_build output)>
    local title="Register file types" build="$1" pfx out
    [[ -n "$PREFIX" ]] || { ui_message "$title" "No wine prefix selected."; return 1; }
    pfx="$(realpath -m "$(expand_path "$PREFIX")")"
    if [[ -z "$build" ]]; then
        ui_message "$title" "Altium isn't installed in $pfx yet. Run Altium Installer does this as part of the setup."
        return 1
    fi
    if out="$("$SCRIPT_DIR/install-desktop.sh" --version "$AD_MAJOR" "$pfx" "$(DRIVE_C="$pfx/drive_c" winpath "${build#*$'\t'}")" 2>&1)"; then
        out="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$out")"
        # counted like the checkboxes (the two Gerber MIME types are one)
        out="$(grep '^warning:' <<< "$out"; sed -n 's/.*; \([0-9]*\) file types registered.*/\1/p' <<< "$out" | {
            read -r n; grep -qxF application/vnd.gerber "$FILETYPES_LIST" \
                2>/dev/null && n=$((n - 1)); echo "Registered $n file types."; })"
        ui_message "$title" "$out"
    else
        ui_message "$title" "Failed:
$(sed 's/\x1b\[[0-9;]*m//g' <<< "$out" | tail -5)"
        return 1
    fi
}

# The "Select existing wine prefix" screen: a path field and the detected prefixes. A folder that
# doesn't exist yet is accepted too (setup creates the prefix). Prints the chosen folder.
select_prefix() {
    local res path items=() plain=() d v
    # Prefixes with Altium first, labelled with the installed versions.
    while read -r d; do
        [[ -n "$d" ]] || continue
        v="$(altium_versions "$d" | paste -sd, - | sed 's/,/, /g')"
        if [[ -n "$v" ]]; then
            items+=("$d" "$d"$'\t'"(Altium $v installed)")
        else
            plain+=("$d" "$d")
        fi
    done < <(detect_prefixes)
    items+=(${plain[@]+"${plain[@]}"})
    path="${PREFIX:-$HOME/.wine-altium}"
    while true; do
        res="$(tui pick "Select existing wine prefix" "Wine prefix path" "$path" "Detected wine prefixes" \
            $(can_browse && echo --browse) -- ${items[@]+"${items[@]}"})" || return 1
        path="${res#* }"
        res="${res%% *}"
        d="$(expand_path "$path")"
        if [[ "$res" == browse ]]; then
            [[ -z "$d" || -e "$d" ]] || d="$(dirname "$d")"
            [[ ! -d "$d" ]] || d="${d%/}/"
            d="$(ui_pick dir "Wine prefix" "${d:-$HOME/}")" && path="$d"
            continue
        fi
        if [[ -z "$d" ]]; then
            ui_message "Select existing wine prefix" "Enter a folder for the Wine prefix."
        elif [[ -e "$d" && ! -d "$d" ]]; then
            ui_message "Select existing wine prefix" "Not a folder: $path"
        else
            realpath -m "$d"
            return 0
        fi
    done
}

interactive_settings() {
    local choice="" build path pfx pfx_warn d code res fields i rc loaded_from="(not loaded)"
    # What was typed in the Run Altium Installer box, kept when it's left with Esc
    local inst_field="$INSTALLER" pfx_field=""
    # ... and in the License file box
    local lic_field="$LICENSE" code_field="$ACTIVATION_CODE" userdata_field="$WINDOWS_EXPORT"
    # Command-line values; settings.yml fills the rest unless the prefix has Altium.
    local cli=("$INSTALLER" "$LICENSE" "$ACTIVATION_CODE" "$WINDOWS_EXPORT" "$DESKTOP_ICON" "$DISABLE_SPLASH") fields_from=""
    local loaded_drives="${DRIVES[*]}" saved_drives=()
    mapfile -t saved_drives < <(setting_list drives)
    CLI_DRIVES=()
    for path in ${DRIVES[@]+"${DRIVES[@]}"}; do CLI_DRIVES+=("${path^}"); done
    SYNC_DRIVES=1
    while true; do
        # Show the prefix's current drive mappings (plus any --drive), unless they were edited here.
        if [[ "$loaded_from" != "$(expand_path "$PREFIX")" && "${DRIVES[*]}" == "$loaded_drives" ]]; then
            loaded_from="$(expand_path "$PREFIX")"
            DRIVES=()
            if [[ -n "$loaded_from" && -d "$loaded_from/dosdevices" ]]; then
                mapfile -t DRIVES < <(prefix_drives "$loaded_from")
            else
                DRIVES=(${saved_drives[@]+"${saved_drives[@]}"})   # prefix not created yet
            fi
            for path in ${CLI_DRIVES[@]+"${CLI_DRIVES[@]}"}; do
                for i in "${!DRIVES[@]}"; do [[ "${DRIVES[$i]:0:1}" != "${path:0:1}" ]] || unset "DRIVES[$i]"; done
                DRIVES=(${DRIVES[@]+"${DRIVES[@]}"} "$path")
            done
            loaded_drives="${DRIVES[*]}"
        fi
        build=""
        [[ -z "$PREFIX" || ! -f "$(expand_path "$PREFIX")/system.reg" ]] || build="$(find_build "$(expand_path "$PREFIX")")"
        [[ -z "$build" ]] || set_version "$(build_version "$(expand_path "$PREFIX")" "${build%%$'\t'*}")"
        d=settings
        [[ -z "$build" ]] || d=prefix
        if [[ "$fields_from" != "$d" ]]; then
            fields_from="$d"
            inst_field="${cli[0]}" pfx_field="" lic_field="${cli[1]}" code_field="${cli[2]}" userdata_field="${cli[3]}"
            LICENSE="${cli[1]}" ACTIVATION_CODE="${cli[2]}" WINDOWS_EXPORT="${cli[3]}"
            DESKTOP_ICON="${cli[4]}" DISABLE_SPLASH="${cli[5]}"
            if [[ -z "$build" ]]; then
                [[ -n "$inst_field" ]] || inst_field="$(setting installer)"
                pfx_field="$(setting prefix)"
                # saved files that no longer exist are left out
                path="$(setting license)"
                if [[ -z "$lic_field" && -f "$(expand_path "$path")" ]]; then
                    lic_field="$path" code_field="$(setting activation_key)"
                    LICENSE="$(realpath "$(expand_path "$path")")" ACTIVATION_CODE="$code_field"
                fi
                path="$(setting user_data)"
                if [[ -z "$userdata_field" && -z "$PREFS_PREFIX" && -f "$(expand_path "$path")" ]]; then
                    userdata_field="$path"
                    WINDOWS_EXPORT="$(realpath "$(expand_path "$path")")"
                fi
                [[ "$CLI_SET" == *desktop_icon* ]] || DESKTOP_ICON="$(bool_setting desktop_icon "$DESKTOP_ICON")"
                [[ "$CLI_SET" == *disable_splash* ]] || DISABLE_SPLASH="$(bool_setting disable_splash "$DISABLE_SPLASH")"
            fi
        fi
        [[ -n "$build" ]] || save_settings

        choice="$(list_menu "Altium Linux Installer" "Wine prefix: ${PREFIX:-<none>}" \
            --esc quit ${choice:+--default "$choice"} -- \
            deps      "Install dependencies" \
            install   "Run Altium Installer" \
            prefix    "Select existing wine prefix" \
            license   "License file" \
            drives    "Drive mappings" \
            filetypes "Register file types" \
            import    "Import user data" \
            export    "Export user data" \
            offline   "Prepare offline install" \
            uninstall "Uninstall")" || die "cancelled"
        choice="${choice#select }"

        case "$choice" in
            prefix)
                path="$(select_prefix)" || continue
                PREFIX="$path"
                ;;
            license)
                # File and activation key; the key is filled in from the file name (..._XXXX-XXXX.alf).
                # Esc keeps what was entered (for Run Altium Installer); only Enter applies it to an
                # existing install.
                path="$lic_field" code="$code_field"
                while true; do
                    res="$(tui form "License file" $(can_browse && echo --browse) --code-from-path --no-box \
                        --after "NOTE: No license file required if using cloud license/install" -- \
                        text "License file (.alf)" "$path" text "Activation key" "$code")" && rc=0 || rc=$?
                    mapfile -t fields <<< "$res"
                    path="${fields[1]:-}" code="${fields[2]:-}"
                    lic_field="$path" code_field="$code"
                    if [[ $rc -ne 0 ]]; then
                        if [[ -z "$path" ]]; then
                            LICENSE="" ACTIVATION_CODE=""
                        elif [[ -f "$(expand_path "$path")" ]]; then
                            LICENSE="$(realpath "$(expand_path "$path")")" ACTIVATION_CODE="$code"
                        fi
                        continue 2
                    fi
                    if [[ "${fields[0]}" == browse ]]; then
                        res="$(expand_path "$path")"
                        [[ -z "$res" || -e "$res" ]] || res="$(dirname "$res")"
                        [[ ! -d "$res" ]] || res="${res%/}/"
                        res="$(ui_pick file "License file" "${res:-$HOME/}" \
                            --file-filter="Altium license (*.alf) | *.alf *.ALF" --file-filter="All files | *")" && path="$res"
                        continue
                    fi
                    if [[ -z "$path" ]]; then
                        LICENSE="" ACTIVATION_CODE=""
                        break
                    fi
                    if [[ -f "$(expand_path "$path")" ]]; then
                        LICENSE="$(realpath "$(expand_path "$path")")" ACTIVATION_CODE="$code"
                        # With Altium in the selected prefix, apply it now; otherwise Run Altium Installer does.
                        if [[ -n "$build" ]]; then
                            if res="$(apply_license "$(realpath -m "$(expand_path "$PREFIX")")" "${build%%$'\t'*}" 2>&1)"; then
                                ui_message "License file" "$res"
                            else
                                ui_message "License file" "Couldn't apply the license:
$res"
                            fi
                        fi
                        break
                    fi
                    ui_message "License file" "Not found: $path"
                done
                ;;
            drives)
                drives_menu
                path="$(realpath -m "$(expand_path "${PREFIX:-/nonexistent}")")"
                if [[ "${DRIVES[*]}" != "$loaded_drives" && -f "$path/system.reg" ]]; then
                    ui_message "Drive mappings" "Saved to $path:

$(apply_drives "$path" 1 2>&1)"
                    loaded_drives="${DRIVES[*]}"
                fi
                ;;
            filetypes)
                choose_filetypes || continue
                register_filetypes "$build" || continue
                REGISTER_FILETYPES=1
                ;;
            import)
                # Imported now if the selected prefix has Altium, otherwise by Run Altium Installer.
                path="$userdata_field"
                while true; do
                    res="$(tui form "Import user data" $(can_browse && echo --browse) --no-box -- \
                        text "User data archive path" "$path")" && rc=0 || rc=$?
                    mapfile -t fields <<< "$res"
                    path="${fields[1]:-}"
                    userdata_field="$path"
                    [[ $rc -eq 0 ]] || continue 2
                    d="$(expand_path "$path")"
                    if [[ "${fields[0]}" == browse ]]; then
                        [[ -z "$d" || -e "$d" ]] || d="$(dirname "$d")"
                        [[ ! -d "$d" ]] || d="${d%/}/"
                        d="$(ui_pick file "User data archive" "${d:-$HOME/}" --file-filter="Zip (*.zip) | *.zip *.ZIP")" && path="$d"
                        continue
                    fi
                    [[ -f "$d" ]] || { ui_message "Import user data" "Not found: ${path:-(empty)}"; continue; }
                    d="$(realpath "$d")"
                    pfx="$(realpath -m "$(expand_path "${PREFIX:-/nonexistent}")")"
                    if [[ -z "$build" ]]; then
                        WINDOWS_EXPORT="$d" PREFS_FROM_EXPORT=1 PREFS_PREFIX=""
                        break
                    fi
                    if [[ -n "$(prefix_processes "$pfx")" ]]; then
                        ui_message "Import user data" "Close Altium first."
                        continue
                    fi
                    code="$(mktemp -d)"
                    if res="$(unpack_user_data "$d" "$code" 2>&1 && import_user_data "$code" "$pfx" "${build%%$'\t'*}" 2>&1)"; then
                        ui_message "Import user data" "Imported into $pfx:
$res"
                    else
                        ui_message "Import user data" "Couldn't import $path:
$res"
                    fi
                    rm -rf "$code"
                    break
                done
                ;;
            export)
                pfx="$(realpath -m "$(expand_path "${PREFIX:-/nonexistent}")")"
                if [[ -z "$build" ]]; then
                    ui_message "Export user data" "No Altium Designer in the selected wine prefix."
                    continue
                fi
                # A zip per build, named like export-windows.ps1's
                local v guid name zip out="" ts
                ts="$(date +%Y%m%d-%H%M%S)"
                while IFS=$'\t' read -r v guid _; do
                    name="${v%%.*}"
                    [[ "$(all_builds "$pfx" | cut -d. -f1 | grep -cx "$name")" -le 1 ]] || name="$v"
                    zip="$SCRIPT_DIR/exported-user-data/altium$name-user-data_$ts.zip"
                    code="$(mktemp -d)"
                    if res="$(export_user_data "$pfx" "$guid" "$code" 2>&1)" && mkdir -p "$(dirname "$zip")" \
                            && (cd "$code" && zip -qr "$zip" .) 2>/dev/null; then
                        out+="Exported to $zip"$'\n'
                    else
                        out+="Couldn't export Altium $v: $res"$'\n'
                    fi
                    rm -rf "$code"
                done < <(all_builds "$pfx")
                ui_message "Export user data" "${out%$'\n'}"
                ;;
            deps)
                plan_deps
                res="$(deps_summary)"
                if [[ -z "$res" ]]; then
                    ui_message "Install dependencies" "All dependencies are installed."
                    continue
                fi
                code="Confirm actions?"
                ! grep -qv '^- Download winetricks' <<< "$res" || code+=" (uses sudo)"
                tui confirm "Install dependencies" "$res" --head "$code" >/dev/null || continue
                # normal screen, for sudo
                printf '%s' "${RMCUP:-}"
                if (install_deps 1); then res="Dependencies installed."; else res="Not complete; see the terminal output."; fi
                printf '%s' "${SMCUP:-}"
                ui_message "Install dependencies" "$res"
                ;;
            offline)
                tui confirm "Prepare offline install" "- Download Wine $WINE_VERSION_EXPECTED source
- Download DXVK $DXVK_VERSION
- Download winetricks $WINETRICKS_VERSION
- Download winetricks packages (Microsoft runtimes and fonts)
- Save to $OFFLINE_DIR (about 1.7 GB)

Required apt packages:
winehq-stable $WINE_VERSION_EXPECTED (from WineHQ, amd64 and i386) $(echo $APT_PACKAGES)" --head "Confirm actions?" \
                    --red "Required apt packages:" \
                    --warn "NOTE: Run 'sudo dpkg --add-architecture i386' before installing i386 wine package" >/dev/null || continue
                # shown on the normal screen, since downloads can take a while
                printf '%s' "${RMCUP:-}"
                if prepare_offline; then res="Done: $OFFLINE_DIR ($(du -sh "$OFFLINE_DIR" | cut -f1))"; else res="Not complete; see the terminal output."; fi
                printf '%s' "${SMCUP:-}"
                ui_message "Prepare offline install" "$res"
                ;;
            uninstall)
                [[ -n "$PREFIX" ]] || { ui_message "Uninstall" "No wine prefix selected."; continue; }
                path="$(realpath -m "$(expand_path "$PREFIX")")"
                if [[ ! -f "$path/system.reg" ]]; then
                    ui_message "Uninstall" "$path isn't a Wine prefix; nothing to uninstall."
                    continue
                fi
                tui confirm "Uninstall" "$(uninstall_summary "$path")

Uninstall?" --red "  - Wine prefix $path" >/dev/null || continue
                UNINSTALL=1
                UNINSTALL_CONFIRMED=1
                break
                ;;
            install)
                # The installer is required unless the chosen prefix already has Altium; the prefix field
                # follows the installer's name (Altium 21 -> ~/.wine-altium21) until it's edited, with red
                # notes when it names an existing prefix or one with Altium.
                path="$inst_field" pfx="$pfx_field"
                while true; do
                    res="$(tui form "Run Altium Installer" --prefix-from-installer \
                        --tested "$TESTED_VERSIONS" \
                        $(can_browse && echo --browse) -- \
                        text "Altium installer path (offline *.zip or online *.exe)" "$path" \
                        text "Wine prefix (auto-filled based on installer name)" "$pfx" \
                        check "Create desktop icon" "$DESKTOP_ICON" \
                        check "Disable Altium splash screen" "$DISABLE_SPLASH")" && rc=0 || rc=$?
                    mapfile -t fields <<< "$res"
                    path="${fields[1]:-}" pfx="${fields[2]:-}" DESKTOP_ICON="${fields[3]:-$DESKTOP_ICON}"
                    DISABLE_SPLASH="${fields[4]:-$DISABLE_SPLASH}"
                    inst_field="$path" pfx_field="$pfx"
                    [[ $rc -eq 0 ]] || continue 2
                    res="$(expand_path "$path")"
                    if [[ "${fields[0]}" == browse ]]; then
                        [[ -z "$res" || -e "$res" ]] || res="$(dirname "$res")"
                        [[ ! -d "$res" ]] || res="${res%/}/"
                        res="$(ui_pick file "Altium installer" "${res:-$HOME/}" \
                            --file-filter="Altium installer (*.zip, *.exe) | *.zip *.ZIP *.exe *.EXE")" && path="$res"
                        continue
                    fi
                    d="$(expand_path "$pfx")"
                    if [[ -z "$d" ]]; then
                        ui_message "Run Altium Installer" "Enter a folder for the Wine prefix."
                        continue
                    elif [[ -e "$d" && ! -d "$d" ]]; then
                        ui_message "Run Altium Installer" "Not a folder: $pfx"
                        continue
                    fi
                    d="$(realpath -m "$d")"
                    build=""
                    [[ ! -f "$d/system.reg" ]] || build="$(find_build "$d")"
                    if [[ -z "$path" && -n "$build" ]]; then
                        res=""
                    elif [[ -f "$res" && "${res,,}" =~ \.(zip|exe)$ ]]; then
                        res="$(realpath "$res")"
                    elif [[ -e "$res" ]]; then
                        ui_message "Run Altium Installer" "Not a .zip or .exe file: $path"
                        continue
                    else
                        ui_message "Run Altium Installer" "Not found: ${path:-(empty)}"
                        continue
                    fi
                    # n goes back to the box with the entries kept
                    code="$(missing_deps | paste -sd' ' -)"
                    if [[ -n "$code" ]]; then
                        tui confirm "Run Altium Installer" "WARNING: Missing dependencies:
$code

Continue anyway?" --red "WARNING: Missing dependencies:" >/dev/null || continue
                        SKIP_DEPS=1
                    else
                        SKIP_DEPS=0
                    fi
                    # An existing prefix gets Altium's dependencies too (the winetricks step skips what it has).
                    if [[ ! -f "$d/system.reg" ]]; then
                        code="- Create wine prefix $d" pfx_warn=""
                    elif [[ -n "$res" ]]; then
                        code="- Install Altium's dependencies in existing wine prefix $d"
                        pfx_warn="WARNING: Altium and dependencies will be installed in the existing wine prefix $d"
                    else
                        code="- Update wine prefix $d" pfx_warn=""
                    fi
                    # Altium launched from the installer's last page would run before the fixes are in place.
                    if [[ -n "$res" ]]; then
                        pfx_warn="${pfx_warn:+$pfx_warn

}WARNING: At the end of the Altium installer, uncheck \"Run Altium Designer\".
Leaving it checked will run Altium without necessary compatibility patches"
                    fi
                    tui confirm "Run Altium Installer" "$code${res:+
- Run Altium installer}" --head "Confirm actions?" ${pfx_warn:+--warn "$pfx_warn"} >/dev/null || continue
                    PREFIX="$d" INSTALLER="$res"
                    [[ -z "$res" ]] || RUN_INSTALLER=1
                    break
                done
                save_settings
                if [[ "${INSTALLER,,}" == *.exe && ! -d "$(dirname "$INSTALLER")/Altium Cache" ]]; then
                    ui_message "Online installer" "This looks like Altium's online installer. It downloads Altium during \
setup and needs network access and an Altium account sign-in. It hasn't been tested under Wine; the \
offline installer (OfflineSetup_Altium_Designer_Public_21_5_1.zip) is known to work."
                fi
                break
                ;;
        esac
    done
}

if [[ -z "$INTERACTIVE" ]]; then
    INTERACTIVE=0
    [[ ! -t 0 || ! -t 1 ]] || INTERACTIVE=1
fi
if [[ "$INTERACTIVE" -eq 1 ]]; then
    command -v python3 >/dev/null || die "the interactive setup needs python3 (sudo apt install python3); or use --non-interactive"
    # All menus share one alternate screen: each tui.py run uses a copy of the terminal description
    # without the codes that switch to and from it, so the shell's screen doesn't flash in between.
    TUI_TERMINFO="$(mktemp -d)"
    if infocmp -x 2>/dev/null | sed -E 's/(smcup|rmcup)=[^,]*,//g' | tic -x -o "$TUI_TERMINFO" - 2>/dev/null; then
        RMCUP="$(tput rmcup 2>/dev/null || true)"     # read now: on Esc, setup exits inside the menus
        SMCUP="$(tput smcup 2>/dev/null || true)"
        tput smcup 2>/dev/null || true
        trap 'printf "%s" "$RMCUP"; rm -rf "$TUI_TERMINFO"' EXIT
        TERMINFO="$TUI_TERMINFO" interactive_settings
        printf '%s' "$RMCUP"
        trap - EXIT
    else
        interactive_settings
    fi
    rm -rf "$TUI_TERMINFO"
fi

if [[ "$INTERACTIVE" -eq 0 && "$PREFIX_GIVEN" -eq 0 && -n "$INSTALLER" ]]; then
    PREFIX="$(installer_prefix "$INSTALLER")"
fi
[[ -n "$PREFIX" ]] || PREFIX="$HOME/.wine-altium"
if [[ "$UNINSTALL" -eq 1 ]]; then
    do_uninstall "$(realpath -m "$(expand_path "$PREFIX")")" "$UNINSTALL_CONFIRMED"
    exit 0
fi

# ---------------------------------------------------------------- validate settings

PREFIX="$(realpath -m "$(expand_path "$PREFIX")")"
if [[ -z "$INSTALLER" ]]; then
    [[ -f "$PREFIX/system.reg" && -n "$(find_build "$PREFIX")" ]] \
        || die "no installer given and Altium Designer isn't installed in $PREFIX (use --installer)"
else
    [[ -f "$INSTALLER" && "${INSTALLER,,}" =~ \.(zip|exe)$ ]] || die "--installer must be a .zip or .exe file: $INSTALLER"
    INSTALLER="$(realpath "$INSTALLER")"
fi
[[ -z "$WINDOWS_EXPORT" || -f "$WINDOWS_EXPORT" ]] || die "not found: $WINDOWS_EXPORT"
[[ -z "$PREFS_PREFIX" || -f "$PREFS_PREFIX/system.reg" ]] || die "not a Wine prefix: $PREFS_PREFIX"
[[ -z "$WINDOWS_EXPORT" || -z "$PREFS_PREFIX" || "$PREFS_FROM_EXPORT" -eq 0 ]] \
    || die "use either --user-data or --prefs-from-prefix, not both"
[[ -z "$LICENSE" || -f "$LICENSE" ]] || die "not found: $LICENSE"
[[ -z "$WINDOWS_EXPORT" ]] || WINDOWS_EXPORT="$(realpath "$WINDOWS_EXPORT")"
[[ -z "$PREFS_PREFIX" ]] || PREFS_PREFIX="$(realpath "$PREFS_PREFIX")"
[[ -z "$LICENSE" ]] || LICENSE="$(realpath "$LICENSE")"
[[ -z "$PREFS_PREFIX" || "$PREFS_PREFIX" != "$PREFIX" ]] || die "--prefs-from-prefix can't be the prefix being set up"
for i in "${!DRIVES[@]}"; do
    d="${DRIVES[$i]}"
    [[ "$d" =~ ^[A-Za-z]:\\?=.+ ]] || die "--drive expects 'M:=/linux/folder', got '$d'"
    letter="${d:0:1}"
    [[ "${letter^^}" != C && "${letter^^}" != Z ]] || die "drive ${letter^^}: is Wine's own; choose another letter"
    DRIVES[$i]="${letter^^}:=$(realpath -m "$(expand_path "${d#*=}")")"
done
[[ -z "$(printf '%s\n' ${DRIVES[@]+"${DRIVES[@]}"} | cut -c1 | sort | uniq -d)" ]] || die "a drive letter is mapped twice"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (sudo is used where needed)"
[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || die "needs a graphical session (the installer opens windows)"

# winemenubuilder would turn Windows file associations (Altium's, .NET's) into Linux desktop entries
# and MIME types (dozens of wine-extension-*.desktop files); keep it off for everything this script runs.
export WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES='winemenubuilder.exe=d'
DRIVE_C="$PREFIX/drive_c"

# ---------------------------------------------------------------- packages

if [[ "$SKIP_DEPS" -eq 0 ]]; then
    install_deps
fi
command -v wine >/dev/null || die "wine isn't installed (menu: Install dependencies)"

WINE_VERSION="$(wine --version)"
WINE_VERSION="${WINE_VERSION#wine-}"
WINE_VERSION="${WINE_VERSION%% *}"
info "Wine $WINE_VERSION"
if [[ "$WINE_VERSION" != "$WINE_VERSION_EXPECTED" ]]; then
    warn "the Direct2D patch was made for Wine $WINE_VERSION_EXPECTED; it may not apply to $WINE_VERSION"
fi

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

EXPORT=""
if [[ -n "$WINDOWS_EXPORT" ]]; then
    EXPORT="$WORK/export"
    info "Unpacking user data $(basename "$WINDOWS_EXPORT")"
    unpack_user_data "$WINDOWS_EXPORT" "$EXPORT" || die "can't use $WINDOWS_EXPORT"
fi

# ---------------------------------------------------------------- prefix

if [[ ! -f "$PREFIX/system.reg" ]]; then
    info "Creating Wine prefix $PREFIX"
    # Skip the Wine Mono/Gecko install prompts; .NET 4.8 replaces Mono and Gecko isn't needed.
    WINEDLLOVERRIDES='mscoree=d;mshtml=d;winemenubuilder.exe=d' wineboot -i
    wineserver -w
fi
# Drives right away, so a failed install keeps them.
apply_drives "$PREFIX" "$SYNC_DRIVES" | while read -r line; do
    case "$line" in warning:*) warn "${line#warning: }" ;; *) info "$line" ;; esac
done

# Disable winemenubuilder in the registry before winetricks: some verbs replace WINEDLLOVERRIDES, and
# .NET/VC++ register file types (.chm, .hlp, .xaml, ...) that winemenubuilder turns into Linux menu entries.
wine reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /d '' /f >/dev/null

WT_LOG="$PREFIX/winetricks.log"
[[ ! -d "$OFFLINE_DIR/winetricks" ]] || export W_CACHE="$OFFLINE_DIR/winetricks"
for verb in win10 $WINETRICKS_VERBS; do
    if [[ "$verb" != win10 ]] && grep -qx "$verb" "$WT_LOG" 2>/dev/null; then
        continue
    fi
    info "winetricks $verb"
    winetricks -q "$verb"
done
winetricks -q win10   # some verbs switch the Windows version while installing

# ---------------------------------------------------------------- DXVK
#
# Direct3D on Vulkan (the PCB editor uses Direct3D 11). A pinned release rather than winetricks' dxvk
# verb, which asks GitHub for the newest version every time (so it can't work offline, and the
# version changes underneath). Installed like winetricks does: the DLLs plus native overrides.

if [[ "$(cat "$PREFIX/.altium-setup-dxvk" 2>/dev/null)" != "$DXVK_VERSION" ]]; then
    info "Installing DXVK $DXVK_VERSION"
    DXVK_TAR="$(fetch "dxvk-$DXVK_VERSION.tar.gz" "$(dxvk_url)" "$DXVK_SHA256")" || die "couldn't get DXVK $DXVK_VERSION"
    tar xzf "$DXVK_TAR" -C "$WORK"
    for d in dxgi d3d9 d3d10core d3d11; do
        cp "$WORK/dxvk-$DXVK_VERSION/x64/$d.dll" "$DRIVE_C/windows/system32/"
        cp "$WORK/dxvk-$DXVK_VERSION/x32/$d.dll" "$DRIVE_C/windows/syswow64/"
        wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native /f >/dev/null
    done
    echo "$DXVK_VERSION" > "$PREFIX/.altium-setup-dxvk"
fi

# The native 64-bit msxml6 from winetricks fails to load; Wine's builtin works.
wine reg add 'HKCU\Software\Wine\DllOverrides' /v '*msxml6' /d builtin /f >/dev/null

# ---------------------------------------------------------------- fonts
#
# Wine resolves a replaced name to the Linux font for GDI and DirectWrite. Microsoft's GDI+ (winetricks
# gdiplus) reads its font list from the registry and doesn't see replacements; the only GDI+ request
# seen without a match is Arial Narrow, with no visible effect.

while IFS='=' read -r from to; do
    wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "$from" /d "$to" /f >/dev/null
done <<< "$FONT_REPLACEMENTS"
info "Windows UI fonts mapped to free Linux fonts (Segoe UI -> Open Sans, ...)"

# ---------------------------------------------------------------- altium installer

BUILD="$(find_build "$PREFIX")"
if [[ -z "$BUILD" || "$RUN_INSTALLER" -eq 1 ]]; then
    [[ -n "$INSTALLER" ]] || die "no installer given"
    # the version in the installer's name (21.5.1, or just 21 for the online installer)
    if [[ "$(basename "${INSTALLER,,}")" =~ designer[^0-9]{0,12}([0-9]+([_.][0-9]+){0,2}) ]]; then
        INSTALLER_VERSION="${BASH_REMATCH[1]//_/.}"
        [[ " $TESTED_VERSIONS " == *" $INSTALLER_VERSION "* ]] \
            || warn "Altium $INSTALLER_VERSION not tested with this installer (tested: $TESTED_VERSIONS)"
    else
        warn "Altium version unknown (compatibility is uncertain)"
    fi
    UNPACKED=""
    if [[ "${INSTALLER,,}" == *.exe ]]; then
        # Online installer, or the setup .exe of an unpacked offline installer (uses "Altium Cache" next to it).
        INSTALLER_DIR="$(dirname "$INSTALLER")"
        SETUP_EXE="$INSTALLER"
        [[ -d "$INSTALLER_DIR/Altium Cache" ]] \
            || warn "online installer: it downloads Altium and needs network access and an Altium account; untested under Wine"
    elif [[ "${INSTALLER,,}" == *.zip ]]; then
        INSTALLER_DIR="$CACHE_DIR/installer"
        UNPACKED=1
        info "Unpacking $(basename "$INSTALLER") into $INSTALLER_DIR"
        rm -rf "$INSTALLER_DIR"
        mkdir -p "$INSTALLER_DIR"
        unzip -q "$INSTALLER" -d "$INSTALLER_DIR" || die "failed to unpack $INSTALLER"
        chmod -R u+rwX "$INSTALLER_DIR"
        SETUP_EXE="$(find "$INSTALLER_DIR" -maxdepth 1 -iname 'AltiumDesigner*Setup.exe' | head -1)"
    else
        die "unsupported installer (expected a .zip or .exe file): $INSTALLER"
    fi
    [[ -n "$SETUP_EXE" && -f "$SETUP_EXE" ]] || die "no AltiumDesigner*Setup.exe found for $INSTALLER"

    # Altium's splash is always on top, and the dialogs of its first start open behind it, so it looks
    # stuck if Altium is launched from the installer's last page. The setting that turns the splash
    # off belongs to the install (its key has the build's GUID, which the installer creates), so it's
    # set while the installer runs: as soon as the new build is registered, before that last page.
    builds() {
        wine reg query 'HKLM\Software\Altium\Builds' 2>/dev/null | tr -d '\r' | grep -o 'Altium Designer {[^}]*}' || true
    }
    new_builds() { comm -13 <(sort <<< "$BUILDS_BEFORE") <(builds | sort); }
    BUILDS_BEFORE="$(builds)"

    info "Running the Altium installer. Complete it in its window."
    echo "    The default install folder works. At the end, either leave Altium unlaunched or close it"
    echo "    once it has started; setup continues after all of the installer's processes exit."
    (cd "$INSTALLER_DIR" && wine "$(basename "$SETUP_EXE")") &
    INSTALLER_PID=$!
    SPLASH_OFF=$(( 1 - DISABLE_SPLASH ))
    while [[ $SPLASH_OFF -eq 0 ]] && kill -0 "$INSTALLER_PID" 2>/dev/null; do
        while read -r key; do
            [[ -n "$key" ]] && no_splash "$key" && SPLASH_OFF=1
        done < <(new_builds)
        sleep 1
    done
    wait "$INSTALLER_PID" || true
    wineserver -w
    [[ -z "$UNPACKED" ]] || rm -rf "$INSTALLER_DIR"

    NEW_BUILD="$(new_builds | grep -o '[0-9A-Fa-f-]\{36\}' | head -1 || true)"
    BUILD="$(find_build "$PREFIX" "$NEW_BUILD")"
    [[ -n "$BUILD" ]] || die "no Altium Designer build registered after the installer; was it completed?"
fi
GUID="${BUILD%%$'\t'*}"
BUILD_KEY="Altium Designer {$GUID}"
AD_DIR="$(winpath "${BUILD#*$'\t'}")"
[[ -f "$AD_DIR/X2.EXE" ]] || die "X2.EXE not found in $AD_DIR"
AD_VERSION="$(build_version "$PREFIX" "$GUID")"
set_version "$AD_VERSION"
info "Altium $AD_VERSION installed: $BUILD_KEY in $AD_DIR"

# ---------------------------------------------------------------- user data
#
# Altium keys its settings by the install's GUID, which a new install doesn't share with the source,
# so the source's preferences are imported under the new GUID (import_user_data).

if [[ -n "$EXPORT" && "$PREFS_FROM_EXPORT" -eq 1 ]]; then
    info "Importing user data ($(tr -d '\r' < "$EXPORT/build.txt" | sed -n 's/^build_key=//p'))"
    import_user_data "$EXPORT" "$PREFIX" "$GUID" | while read -r line; do info "  $line"; done
elif [[ -n "$PREFS_PREFIX" ]]; then
    SRC_BUILD="$(find_build "$PREFS_PREFIX")"
    [[ -n "$SRC_BUILD" ]] || die "no Altium Designer build in $PREFS_PREFIX"
    info "Importing user data from $PREFS_PREFIX (Altium Designer {${SRC_BUILD%%$'\t'*}})"
    export_user_data "$PREFS_PREFIX" "${SRC_BUILD%%$'\t'*}" "$WORK/prefs-prefix" || die "couldn't read $PREFS_PREFIX"
    import_user_data "$WORK/prefs-prefix" "$PREFIX" "$GUID" | while read -r line; do info "  $line"; done
fi

# ---------------------------------------------------------------- window decorations
#
# Altium draws its own title bar, but adds a caption style to its main window when maximized. Wine
# then asks the window manager for a title bar as well, and the two fight over the window size
# (flicker, jumping). Decorated=N (Altium only) keeps the window manager's decorations off. The
# resize frame Altium keeps when maximized is hidden by the msimg32 stand-in below.

wine reg add 'HKCU\Software\Wine\AppDefaults\X2.EXE\X11 Driver' /v Decorated /d N /f >/dev/null

# ---------------------------------------------------------------- default document and recovery paths

set_open_path "$PREFIX" "$BUILD_KEY" | while read -r line; do info "$line"; done
set_recovery_path "$PREFIX" "$BUILD_KEY" | while read -r line; do info "$line"; done

# ---------------------------------------------------------------- splash screen
#
# Altium's splash screen is always on top, so dialogs shown during startup (e.g. "Default Document
# Path ... does not exist") open underneath it and the splash looks stuck. Altium's own "Suppress
# startup screen" preference turns the splash off. Set (again) after the preferences import, which
# could carry "0".

if [[ "$DISABLE_SPLASH" -eq 1 ]]; then
    no_splash "$BUILD_KEY"
    info "Splash screen turned off (so startup dialogs aren't hidden behind it)"
fi

# ---------------------------------------------------------------- data folders outside the prefix
#
# Altium's per-install folders are moved to DATA_DIR and symlinked from the prefix, so they survive a
# prefix rebuild and keep the same paths across installs (each install has its own GUID):
#   settings     AppData\Roaming\Altium\<build>        (DXP.RCS, .dft defaults, view configs, recovery)
#   local        AppData\Local\Altium\<build>          (logs, caches)
#   programdata  ProgramData\Altium\<build>             (extensions, user data, caches)
#   license      ProgramData\Altium\<build>_Security    (license files)
# Files already in DATA_DIR win; files only in the prefix are added without overwriting.

wineserver -w
relocate() {   # <folder in prefix> <name in DATA_DIR>
    local src="$1" dst="$DATA_DIR/$2"
    if [[ -L "$src" ]]; then
        [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]] || warn "$src is a symlink to somewhere else; leaving it"
        return 0
    fi
    mkdir -p "$(dirname "$src")" "$DATA_DIR"
    if [[ -d "$dst" ]]; then
        if [[ -d "$src" ]]; then
            # No-clobber copy; coreutils >= 9.3 warns about -n and wants --update=none.
            if cp --help 2>/dev/null | grep -q -- '--update\[=UPDATE\]'; then
                cp -a --update=none "$src/." "$dst/"
            else
                cp -an "$src/." "$dst/"
            fi
            rm -rf "$src"
        fi
    elif [[ -d "$src" ]]; then
        mv "$src" "$dst"
    else
        mkdir -p "$dst"
    fi
    ln -s "$dst" "$src"
}
info "Data folders: $DATA_DIR"
relocate "$DRIVE_C/users/$USER/AppData/Roaming/Altium/$BUILD_KEY" settings
relocate "$DRIVE_C/users/$USER/AppData/Local/Altium/$BUILD_KEY" local
# The extension registry is install-specific (its paths contain the install's GUID): the new install's
# copy replaces one left by an earlier install, which Altium would otherwise find invalid and empty,
# disabling all extensions ("Could not start Vault Explorer").
EXT_REG="Extensions/ExtensionsRegistry.xml"
NEW_EXT_REG=""
if [[ ! -L "$DRIVE_C/ProgramData/Altium/$BUILD_KEY" && -f "$DRIVE_C/ProgramData/Altium/$BUILD_KEY/$EXT_REG" ]]; then
    NEW_EXT_REG="$WORK/ExtensionsRegistry.xml"
    cp -p "$DRIVE_C/ProgramData/Altium/$BUILD_KEY/$EXT_REG" "$NEW_EXT_REG"
fi
relocate "$DRIVE_C/ProgramData/Altium/$BUILD_KEY" programdata
[[ -z "$NEW_EXT_REG" ]] || cp -p "$NEW_EXT_REG" "$DATA_DIR/programdata/$EXT_REG"
# Repair paths pointing at another install's GUID.
if [[ -f "$DATA_DIR/programdata/$EXT_REG" ]] \
        && grep -qE "Altium Designer \{[0-9A-Fa-f-]{36}\}" "$DATA_DIR/programdata/$EXT_REG" \
        && grep -E "Altium Designer \{[0-9A-Fa-f-]{36}\}" "$DATA_DIR/programdata/$EXT_REG" | grep -qvF "$BUILD_KEY"; then
    sed -i -E "s/Altium Designer \{[0-9A-Fa-f-]{36}\}/$BUILD_KEY/g" "$DATA_DIR/programdata/$EXT_REG"
    info "Updated extension paths in $EXT_REG for $BUILD_KEY"
fi
relocate "$DRIVE_C/ProgramData/Altium/${BUILD_KEY}_Security" license

# ---------------------------------------------------------------- license
#
# Altium lists the .alf files in its license folder; NetworkLicenseUsage\ActivationCode0 is the license
# it uses automatically at startup.

if [[ -n "$LICENSE" ]]; then
    apply_license "$PREFIX" "$GUID" | while read -r line; do info "$line"; done
fi

# ---------------------------------------------------------------- simbeor (impedance calculations)
#
# Simbeor's license check decrypts with BCryptDecrypt(BCRYPT_PAD_NONE), which Wine doesn't implement.
# A bcrypt.dll stand-in in Altium's folder, selected for X2.EXE only, loads Wine's real bcrypt.dll and
# forwards every export to it, except raw RSA decryption, which it does itself. simbeor_sdk.dll is
# left unmodified. The stand-in's jump stubs are generated from the installed Wine's bcrypt exports.

WINE_BCRYPT="$(dirname "$(readlink -f "$(command -v wine)")")/../lib/wine/x86_64-windows/bcrypt.dll"
[[ -f "$WINE_BCRYPT" ]] || WINE_BCRYPT="$(find /opt /usr/lib -path '*x86_64-windows/bcrypt.dll' 2>/dev/null | head -1 || true)"
[[ -f "$WINE_BCRYPT" ]] || die "can't find Wine's 64-bit bcrypt.dll"

info "Building the bcrypt.dll stand-in"
mkdir -p "$WORK/bcrypt"
"$SCRIPT_DIR/src/gen-bcrypt-exports.sh" "$WINE_BCRYPT" "$WORK/bcrypt" >/dev/null
x86_64-w64-mingw32-gcc -O2 -shared -I"$WORK/bcrypt" -o "$WORK/bcrypt/bcrypt.dll" "$SCRIPT_DIR/src/bcrypt.c" \
    "$WORK/bcrypt/bcrypt-thunks.S" "$WORK/bcrypt/bcrypt.def" -Wl,--kill-at -static-libgcc
cp "$WORK/bcrypt/bcrypt.dll" "$AD_DIR/bcrypt.dll"
wine reg add 'HKCU\Software\Wine\AppDefaults\X2.EXE\DllOverrides' /v bcrypt /d 'native,builtin' /f >/dev/null

# ---------------------------------------------------------------- direct2d (schematic editor)
#
# Patched Wine d2d1.dll, used only by X2.EXE (app-specific override), loaded as native from
# system32 and the Altium folder. The "Wine builtin DLL" marker is cleared so Wine doesn't
# substitute its own copy.

# (named after the Wine version and the patch, so a changed patch is rebuilt)
D2D1_DLL="$CACHE_DIR/d2d1-$WINE_VERSION-$(sha256sum "$SCRIPT_DIR/src/d2d1-altium.patch" | cut -c1-12).dll"
if [[ ! -f "$D2D1_DLL" ]]; then
    info "Building patched d2d1.dll for Wine $WINE_VERSION"
    mkdir -p "$CACHE_DIR"
    TARBALL="$(fetch "wine-$WINE_VERSION.tar.xz" "$(wine_source_url "$WINE_VERSION")" \
        "$( [[ "$WINE_VERSION" != "$WINE_VERSION_EXPECTED" ]] || echo "$WINE_SRC_SHA256")")" \
        || die "couldn't get the Wine $WINE_VERSION source"
    tar xf "$TARBALL" -C "$WORK"
    patch -d "$WORK/wine-$WINE_VERSION" -p1 < "$SCRIPT_DIR/src/d2d1-altium.patch" \
        || die "the Direct2D patch doesn't apply to Wine $WINE_VERSION"
    mkdir -p "$WORK/build"
    (
        cd "$WORK/build"
        "../wine-$WINE_VERSION/configure" --enable-win64 --without-x --without-freetype --without-gstreamer \
            --without-cups --without-sane --without-krb5 --without-vulkan --without-opencl --without-pcap \
            --without-usb --without-v4l2 --without-gphoto --without-pulse --without-alsa --without-oss \
            --without-dbus --without-wayland --without-gnutls --without-sdl --without-udev --without-netapi \
            --without-unwind --without-ffmpeg > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
        make -j"$(nproc)" dlls/d2d1/x86_64-windows/d2d1.dll > make.log 2>&1 || { tail -20 make.log; exit 1; }
    ) || die "building d2d1.dll failed"
    cp "$WORK/build/dlls/d2d1/x86_64-windows/d2d1.dll" "$WORK/d2d1.dll"
    MARKER="$(dd if="$WORK/d2d1.dll" bs=1 skip=64 count=16 status=none)"
    [[ "$MARKER" == "Wine builtin DLL" ]] || die "Wine builtin marker not found in the built d2d1.dll"
    dd if=/dev/zero of="$WORK/d2d1.dll" bs=1 seek=64 count=16 conv=notrunc status=none
    mv "$WORK/d2d1.dll" "$D2D1_DLL"
fi

SYS32="$DRIVE_C/windows/system32"
BACKUP="$PREFIX/.altium-setup-backup"
mkdir -p "$BACKUP"
[[ -f "$BACKUP/d2d1.dll" ]] || cp -p "$SYS32/d2d1.dll" "$BACKUP/d2d1.dll"
cp "$D2D1_DLL" "$SYS32/d2d1.dll"
cp "$D2D1_DLL" "$AD_DIR/d2d1.dll"
wine reg add 'HKCU\Software\Wine\AppDefaults\X2.EXE\DllOverrides' /v d2d1 /d native /f >/dev/null

# ---------------------------------------------------------------- msimg32 (hover icon artifacts)
#
# Wine's AlphaBlend doesn't saturate when a source pixel's color exceeds its alpha, so Altium's
# hover icons (gear, cloud, sign-in) get red/yellow edge pixels. This AlphaBlend saturates like
# Windows for that case and otherwise passes through to gdi32; used only by X2.EXE. It also hides the
# frame of Altium's maximized main window (see "window decorations" above).

info "Building msimg32.dll"
x86_64-w64-mingw32-gcc -O2 -shared -o "$WORK/msimg32.dll" "$SCRIPT_DIR/src/msimg32.c" "$SCRIPT_DIR/src/msimg32.def" \
    -lgdi32 -luser32 -Wl,--kill-at -static-libgcc
[[ -f "$BACKUP/msimg32.dll" ]] || cp -p "$SYS32/msimg32.dll" "$BACKUP/msimg32.dll"
cp "$WORK/msimg32.dll" "$SYS32/msimg32.dll"
cp "$WORK/msimg32.dll" "$AD_DIR/msimg32.dll"
wine reg add 'HKCU\Software\Wine\AppDefaults\X2.EXE\DllOverrides' /v msimg32 /d native /f >/dev/null

# ---------------------------------------------------------------- links and drives

for l in ${LINKS[@]+"${LINKS[@]}"}; do
    win="${l%%=*}" target="${l#*=}"
    dst="$(winpath "$win")"
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        rmdir "$dst" 2>/dev/null || { warn "$win exists and isn't empty; not linking it"; continue; }
    fi
    mkdir -p "$(dirname "$dst")"
    ln -sfn "$(realpath -m "$target")" "$dst"
    info "$win -> $target"
done

wineserver -w

# ---------------------------------------------------------------- launcher, menu entry, file types

DESKTOP_ARGS=()
[[ "$REGISTER_FILETYPES" -eq 1 ]] || DESKTOP_ARGS+=(--no-filetypes)
[[ "$DESKTOP_ICON" -eq 0 ]] || DESKTOP_ARGS+=(--desktop-icon)
"$SCRIPT_DIR/install-desktop.sh" --version "$AD_MAJOR" ${DESKTOP_ARGS[@]+"${DESKTOP_ARGS[@]}"} "$PREFIX" "$AD_DIR"
LAUNCHER="$HOME/.local/bin/altium$AD_MAJOR"

info "Done. Start Altium with: $LAUNCHER (or from the menu)"
