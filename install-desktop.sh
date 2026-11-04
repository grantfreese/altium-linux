#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later
# Installs the Altium launcher, menu entry, icons and file associations for the current user.
# Called by setup.sh; can also be run on its own.
#
# Usage: ./install-desktop.sh [--version N] [--no-filetypes] [--desktop-icon] PREFIX AD_DIR
#        ./install-desktop.sh [--version N] --desktop-icon-only
#        ./install-desktop.sh [--version N] --uninstall [PREFIX]
#   PREFIX          Wine prefix (e.g. ~/.wine-altium21)
#   AD_DIR          Linux path of the Altium program folder in the prefix (contains X2.EXE)
#   --version N     Altium major version (default 21): names the launcher altiumN, the menu entry
#                   altiumN.desktop, and so on
#   --no-filetypes  don't register Linux file types/icons for Altium (removes them if registered before);
#                   the launcher, menu entry and Altium's own Open-dialog icons are still set up.
#                   Otherwise the types listed in ~/.local/share/altium-linux/filetypes.list (MIME types, one
#                   per line; written by setup.sh's "Register file types" screen) are registered, or all
#                   of them if there's no such list; types not in it are unregistered.
#   --desktop-icon  also put an Altium icon on the desktop (a copy of the menu entry; an existing one
#                   is kept up to date either way)
#   --desktop-icon-only
#                   only create the desktop icon, from the installed menu entry
#   --uninstall     remove everything this script installs: file types and document icons (restoring
#                   previously chosen default apps), menu entry, desktop icon, launcher, app icon; with
#                   PREFIX, also Wine-generated wine-extension-*.desktop entries pointing at that prefix
#
# The desktop entry's StartupWMClass matches Altium's window class (x2.exe), so the panel/dock can
# associate the running window with it (needed for pinning). File types are listed in
# desktop/filetypes.txt; each gets a MIME type, Altium's document icon, and Altium as default handler.
# This is the freedesktop.org mechanism used by GNOME, Cinnamon, KDE, Xfce, MATE, Budgie, LXDE and
# LXQt; only the cache refresh differs per environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: $0 [--version N] [--no-filetypes] [--desktop-icon] PREFIX AD_DIR | $0 [--version N] --desktop-icon-only | $0 [--version N] --uninstall [PREFIX]"
MODE=install
VERSION=21
REGISTER_FILETYPES=1
DESKTOP_ICON=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --no-filetypes) REGISTER_FILETYPES=0 ;;
        --desktop-icon) DESKTOP_ICON=1 ;;
        --desktop-icon-only) MODE=desktop-icon ;;
        --uninstall) MODE=uninstall ;;
        --version) VERSION="${2:?$USAGE}"; shift ;;
        *) echo "$USAGE" >&2; exit 1 ;;
    esac
    shift
done
[[ "$VERSION" =~ ^[0-9]+$ ]] || { echo "--version expects a major version, e.g. 21" >&2; exit 1; }
NAME="altium$VERSION"
if [[ "$MODE" == install ]]; then
    PREFIX="$(realpath "${1:?$USAGE}")"
    AD_DIR="$(realpath "${2:?$USAGE}")"
    [[ -f "$AD_DIR/X2.EXE" ]] || { echo "X2.EXE not found in $AD_DIR" >&2; exit 1; }
else
    PREFIX="${1:+$(realpath -m "$1")}"
    AD_DIR=""
fi

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
ICON_DIR="$DATA/icons/hicolor"
LAUNCHER="$HOME/.local/bin/$NAME"
DESKTOP_FILE="$DATA/applications/$NAME.desktop"
DESKTOP_ICON_FILE="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")/$NAME.desktop"
MIME_FILE="$DATA/mime/packages/$NAME.xml"
MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
# User-chosen default apps that Altium replaced, restored if the file types are unregistered later.
PREV_DEFAULTS="$DATA/$NAME/previous-defaults.list"
# The file types to register (MIME types); all in desktop/filetypes.txt if this doesn't exist.
SELECTED_TYPES="$DATA/altium-linux/filetypes.list"
DOC_ICONS="$AD_DIR/System/DocumentIcons"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stop opening these types with Altium: remove $NAME.desktop from their defaults and associations,
# and restore the default apps they had before (recorded in PREV_DEFAULTS).
drop_defaults() {   # <MIME type> ...
    local t t_re app
    for t in "$@"; do
        t_re="$(sed 's/[.]/\\./g' <<< "$t")"
        if [[ -f "$MIMEAPPS" ]]; then
            # Drop "type=$NAME.desktop" defaults; strip $NAME.desktop from association lists.
            sed -i -e "/^${t_re//\//\\/}=$NAME\.desktop;\?$/d" \
                -e "/^${t_re//\//\\/}=/s/$NAME\.desktop;\?//" \
                -e "/^${t_re//\//\\/}=$/d" "$MIMEAPPS"
        fi
        if [[ -f "$PREV_DEFAULTS" ]]; then
            app="$(sed -n "s/^${t_re//\//\\/}=//p" "$PREV_DEFAULTS" | head -1)"
            [[ -z "$app" ]] || xdg-mime default "$app" "$t"
            sed -i "/^${t_re//\//\\/}=/d" "$PREV_DEFAULTS"
        fi
    done
}

# Undo a file type registration: MIME definitions, document icons, Altium as default handler.
remove_filetypes() {
    [[ -f "$MIME_FILE" ]] || return 0
    info "Removing Altium file types and document icons"
    mapfile -t old_types < <(sed -n 's/.*<mime-type type="\([^"]*\)".*/\1/p' "$MIME_FILE")
    rm -f "$MIME_FILE"
    update-mime-database "$DATA/mime" >/dev/null 2>&1 || warn "update-mime-database failed"
    find "$ICON_DIR" -path "*/mimetypes/$NAME-*.png" -delete 2>/dev/null || true
    [[ ! -f "$MIMEAPPS" ]] || cp -p "$MIMEAPPS" "$TMP/mimeapps.list.bak"
    drop_defaults ${old_types[@]+"${old_types[@]}"}
    rm -f "$PREV_DEFAULTS"
}

# Menu, MIME and icon caches; only the method differs per desktop environment.
refresh_caches() {
    update-desktop-database "$DATA/applications" 2>/dev/null || true
    DE="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}"
    case "${DE,,}" in
        *kde*|*plasma*)
            # KDE caches menus and MIME associations in ksycoca.
            if command -v kbuildsycoca6 >/dev/null; then
                kbuildsycoca6 >/dev/null 2>&1 || true
            elif command -v kbuildsycoca5 >/dev/null; then
                kbuildsycoca5 >/dev/null 2>&1 || true
            fi
            ;;
        *gnome*|*unity*|*ubuntu*|*cinnamon*|*mate*|*xfce*|*budgie*|*lxde*|*lxqt*|*pantheon*)
            # These watch ~/.local/share/applications and the MIME database; only the icon cache needs refreshing.
            ;;
        *)
            warn "unrecognized desktop environment '$DE'; menu changes may only show after logging out and back in"
            ;;
    esac
    if command -v gtk-update-icon-cache >/dev/null; then
        gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true
    fi
}

# A copy of the menu entry on the desktop. File managers only launch desktop files that are executable
# and, in Nemo/Nautilus, marked trusted.
install_desktop_icon() {
    [[ -f "$DESKTOP_FILE" ]] || { warn "no menu entry ($DESKTOP_FILE) to copy to the desktop"; return 1; }
    mkdir -p "$(dirname "$DESKTOP_ICON_FILE")"
    cp "$DESKTOP_FILE" "$DESKTOP_ICON_FILE"
    chmod +x "$DESKTOP_ICON_FILE"
    gio set "$DESKTOP_ICON_FILE" metadata::trusted true 2>/dev/null || true
    info "Desktop icon: $DESKTOP_ICON_FILE"
}

if [[ "$MODE" == desktop-icon ]]; then
    install_desktop_icon
    exit
fi

# ---------------------------------------------------------------- uninstall

if [[ "$MODE" == uninstall ]]; then
    remove_filetypes
    info "Removing menu entry, desktop icon, launcher and application icon"
    rm -f "$DESKTOP_FILE" "$LAUNCHER"
    # Only our own desktop icon (a copy of the menu entry), not a file the user put there.
    ! grep -qxF "Exec=$LAUNCHER %F" "$DESKTOP_ICON_FILE" 2>/dev/null || rm -f "$DESKTOP_ICON_FILE"
    find "$ICON_DIR" -path "*/apps/$NAME.png" -delete 2>/dev/null || true
    if [[ -n "$PREFIX" ]]; then
        n=0
        for f in "$DATA"/applications/wine-extension-*.desktop; do
            # Exec=env "WINEPREFIX=/path/to/prefix" wine start ...
            [[ -f "$f" ]] && grep -qF -e "WINEPREFIX=$PREFIX\"" -e "WINEPREFIX=$PREFIX " "$f" || continue
            rm -f "$f"
            n=$((n + 1))
        done
        [[ $n -eq 0 ]] || info "Removed $n Wine-generated wine-extension entries for $PREFIX"
    fi
    refresh_caches
    exit 0
fi

# ---------------------------------------------------------------- launcher
#
# Converts file arguments to Windows paths, so files opened from the file manager reach Altium.

mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
export WINEPREFIX="$PREFIX"
export WINEDEBUG="\${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="winemenubuilder.exe=d"
for arg in "\$@"; do
    shift
    if [ -e "\$arg" ]; then
        arg="\$(winepath -w "\$arg" 2>/dev/null || printf '%s' "\$arg")"
    fi
    set -- "\$@" "\$arg"
done
cd "$AD_DIR" && exec wine X2.EXE "\$@"
EOF
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------- icons

# install_ico <file.ico> <context: apps|mimetypes> <icon name>
# Installs every size in the .ico; where a size appears at several bit depths, the deepest wins.
install_ico() {
    local ico="$1" context="$2" name="$3" out="$TMP/ico-$3" png size
    rm -rf "$out"
    mkdir -p "$out"
    icotool -x -o "$out/" "$ico" 2>/dev/null || { warn "can't extract icons from $ico"; return 0; }
    # icotool names files <name>_<index>_<w>x<h>x<bpp>.png; sort by bit depth so the deepest is copied last.
    while read -r png; do
        size="$(basename "$png" .png | sed -n 's/.*_\([0-9]\+\)x[0-9]\+x[0-9]\+$/\1/p')"
        [[ -n "$size" ]] || continue
        mkdir -p "$ICON_DIR/${size}x${size}/$context"
        cp "$png" "$ICON_DIR/${size}x${size}/$context/$name.png"
    done < <(ls "$out"/*.png 2>/dev/null | awk -F'x' '{print $NF+0 "\t" $0}' | sort -n | cut -f2-)
}

info "Installing application icon"
wrestool -x -t 14 -n MAINICON -o "$TMP/x2.ico" "$AD_DIR/X2.EXE"
install_ico "$TMP/x2.ico" apps "$NAME"

# ---------------------------------------------------------------- file types

selected() { [[ ! -f "$SELECTED_TYPES" ]] || grep -qxF "$1" "$SELECTED_TYPES"; }

MIME_TYPES=()
ICO_FOR_EXTS=()
while IFS=$'\t' read -r type ico desc exts; do
    [[ -z "$type" || "$type" == \#* ]] && continue
    ICO_FOR_EXTS+=("$ico"$'\t'"$exts")
    [[ "$REGISTER_FILETYPES" -eq 0 ]] || ! selected "$type" || MIME_TYPES+=("$type")
done < "$SCRIPT_DIR/desktop/filetypes.txt"
[[ ${#MIME_TYPES[@]} -gt 0 ]] || REGISTER_FILETYPES=0

if [[ "$REGISTER_FILETYPES" -eq 1 ]]; then
    # Types registered before but not selected now go back to their earlier default apps.
    unselected=()
    if [[ -f "$MIME_FILE" ]]; then
        while read -r t; do
            selected "$t" || unselected+=("$t")
        done < <(sed -n 's/.*<mime-type type="\([^"]*\)".*/\1/p' "$MIME_FILE")
    fi
    info "Installing file types and document icons"
    mkdir -p "$(dirname "$MIME_FILE")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">'
        while IFS=$'\t' read -r type ico desc exts; do
            [[ -z "$type" || "$type" == \#* ]] && continue
            selected "$type" || continue
            icon="$NAME-$(basename "$ico" .ico | tr '[:upper:]_' '[:lower:]-')"
            if [[ -f "$DOC_ICONS/$ico" ]]; then
                install_ico "$DOC_ICONS/$ico" mimetypes "$icon" >&2
            else
                warn "missing $DOC_ICONS/$ico"
            fi
            echo "  <mime-type type=\"$type\">"
            # Types that already exist elsewhere (Gerber) keep their own description.
            [[ "$type" != application/x-altium-* ]] || echo "    <comment>$desc</comment>"
            echo "    <icon name=\"$icon\"/>"
            # Also the generic icon: otherwise GIO's icon list ends in application-x-generic, which icon
            # themes provide and GTK picks before reaching this icon in hicolor.
            echo "    <generic-icon name=\"$icon\"/>"
            for e in $exts; do
                echo "    <glob pattern=\"*.${e,,}\" weight=\"60\"/>"
            done
            echo '  </mime-type>'
        done < "$SCRIPT_DIR/desktop/filetypes.txt"
        echo '</mime-info>'
    } > "$TMP/$NAME.xml"
    mv "$TMP/$NAME.xml" "$MIME_FILE"
    update-mime-database "$DATA/mime" >/dev/null 2>&1 || warn "update-mime-database failed"
    drop_defaults ${unselected[@]+"${unselected[@]}"}
else
    remove_filetypes
fi

# ---------------------------------------------------------------- Windows-side document icons
#
# Point each extension's ProgID DefaultIcon at the same DocumentIcons file, so Altium's own Open dialog
# shows the same icons. (A copied install can have DefaultIcon values pointing into the Windows
# Installer cache of another product.)

info "Setting document icons in the prefix registry"
DOC_ICONS_WIN="$(WINEPREFIX="$PREFIX" WINEDEBUG=-all winepath -w "$DOC_ICONS" 2>/dev/null)"
# Extension -> ProgID, read from the registry file (one wine call per extension took about a minute).
declare -A EXT_PROGID=()
while IFS=$'\t' read -r e progid; do
    EXT_PROGID[$e]="$progid"
done < <(awk 'index($0, "[Software\\\\Classes\\\\.") == 1 {
                  e = $0; sub(/^\[Software\\\\Classes\\\\\./, "", e); sub(/\].*/, "", e); next }
              /^\[/ { e = "" }
              e != "" && /^@="/ { v = $0; sub(/^@="/, "", v); sub(/"$/, "", v); print tolower(e) "\t" v; e = "" }' \
        "$PREFIX/system.reg")
declare -A PROGID_DONE=()
{
    echo REGEDIT4
    for entry in "${ICO_FOR_EXTS[@]}"; do
        ico="${entry%%$'\t'*}"
        for e in ${entry#*$'\t'}; do
            progid="${EXT_PROGID[${e,,}]:-}"
            [[ -n "$progid" && -z "${PROGID_DONE[$progid]:-}" ]] || continue
            PROGID_DONE[$progid]=1
            printf '\n[HKEY_LOCAL_MACHINE\\Software\\Classes\\%s\\DefaultIcon]\n@="%s"\n' \
                "$progid" "${DOC_ICONS_WIN//\\/\\\\}\\\\$ico"
        done
    done
} > "$TMP/doc-icons.reg"
# /reg:64: the 64-bit registry view, where 64-bit Altium looks
WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
    wine reg import "$(WINEPREFIX="$PREFIX" WINEDEBUG=-all winepath -w "$TMP/doc-icons.reg")" /reg:64 >/dev/null 2>&1 \
    || warn "couldn't set the document icons in the prefix registry"
info "Updated ${#PROGID_DONE[@]} ProgIDs"

# ---------------------------------------------------------------- menu entry

info "Installing menu entry"
mkdir -p "$(dirname "$DESKTOP_FILE")"
MIME_LIST=""
[[ ${#MIME_TYPES[@]} -eq 0 ]] || MIME_LIST="$(printf '%s;' "${MIME_TYPES[@]}")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Altium Designer $VERSION
Comment=PCB design (Wine)
Exec=$LAUNCHER %F
Icon=$NAME
StartupWMClass=x2.exe
StartupNotify=true
Terminal=false
Categories=Development;Electronics;
EOF
[[ -z "$MIME_LIST" ]] || echo "MimeType=$MIME_LIST" >> "$DESKTOP_FILE"
desktop-file-validate "$DESKTOP_FILE" || warn "desktop entry failed validation"

# Make Altium the default for these types (only these types; other defaults are left alone). The
# user's own default for each type is recorded first, to be restored if the type is unregistered.
mkdir -p "$(dirname "$PREV_DEFAULTS")"
touch "$PREV_DEFAULTS"
if [[ -f "$MIMEAPPS" ]]; then
    for t in ${MIME_TYPES[@]+"${MIME_TYPES[@]}"}; do
        grep -q "^$(sed 's/[.]/\\./g' <<< "$t")=" "$PREV_DEFAULTS" && continue
        # first entry in [Default Applications], if not Altium
        app="$(awk -v t="$t" '/^\[/{sec=$0} sec=="[Default Applications]" && index($0, t "=")==1 {
            sub(/^[^=]*=/, ""); split($0, a, ";"); print a[1]; exit }' "$MIMEAPPS")"
        [[ -z "$app" || "$app" == "$NAME.desktop" ]] || echo "$t=$app" >> "$PREV_DEFAULTS"
    done
fi
for t in ${MIME_TYPES[@]+"${MIME_TYPES[@]}"}; do
    xdg-mime default "$(basename "$DESKTOP_FILE")" "$t"
done

[[ "$DESKTOP_ICON" -eq 0 && ! -f "$DESKTOP_ICON_FILE" ]] || install_desktop_icon

refresh_caches
info "Desktop environment: $DE; ${#MIME_TYPES[@]} file types registered (menu entry: $DESKTOP_FILE)"
