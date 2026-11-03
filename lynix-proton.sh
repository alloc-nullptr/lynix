#!/usr/bin/env bash
# lynix-proton.sh - standalone Linux launcher for UI.exe
#
# Runs a user-supplied UI.exe (Lynx) through GE-Proton or GDK-Proton.
# UI.exe is NOT included, copied, downloaded, or embedded by this script.
# The user selects their own UI.exe on first run.
#
# No Steam installation is required.  If no Proton build is installed, the
# launcher can download GE-Proton or GDK-Proton into its own private folder.
#
# WebView2 and the Microsoft Visual C++ runtime are installed inside the
# private Proton prefix automatically.
#
# Usage:
#   ./lynix-proton.sh
#   ./lynix-proton.sh --select
#   ./lynix-proton.sh --proton /path/to/GE-Proton10-25
#   ./lynix-proton.sh --download-proton ge
#   ./lynix-proton.sh --setup
#   ./lynix-proton.sh --status
#   ./lynix-proton.sh --install-desktop
#
# This script is intentionally self-contained (one file).  It uses only
# standard Linux utilities plus curl/wget and an optional zenity/kdialog GUI.

set -Eeuo pipefail

APP_NAME="Lynix Proton Wrapper"
APP_ID="lynix-proton"

# BASH_SOURCE is empty when the script is piped to bash, for example:
#   curl -fsSL <url-to-this-script> | bash
# In that case there is no on-disk script path; prompts use /dev/tty below.
SELF_SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SELF_SOURCE" ] && [ -f "$SELF_SOURCE" ]; then
  SCRIPT_PATH="$(readlink -f -- "$SELF_SOURCE")"
  SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
else
  SCRIPT_PATH=""
  SCRIPT_DIR="$PWD"
fi
PROG_NAME="${SELF_SOURCE##*/}"
[ -n "$PROG_NAME" ] || PROG_NAME="lynix-proton.sh"

DATA_DIR="${LYNIX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$APP_ID}"
CONFIG_DIR="${LYNIX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$APP_ID}"
CONFIG_FILE="$CONFIG_DIR/config"
PROTON_ROOT="$DATA_DIR/proton"
PREFIX_DIR="$DATA_DIR/prefix"
CACHE_DIR="$DATA_DIR/cache"
LOG_DIR="$DATA_DIR/logs"
FAKE_STEAM="$DATA_DIR/steam-client"
LOG_FILE="$LOG_DIR/launcher.log"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_ID.desktop"

GUI=""
NO_GUI=0
DEBUG=0
NO_LAUNCH=0
FORCE_SELECT=0
FORCE_SETUP=0
RESET=0
SHOW_STATUS=0
INSTALL_DESKTOP=0
UNINSTALL=0
PURGE=0
PROTON_ARG=""
PROTON_DL=""
EXE_ARG=""
PASSTHRU=()

usage() {
  cat <<EOF
$APP_NAME

A standalone launcher for a user-supplied UI.exe (Lynx), running it through
GE-Proton or GDK-Proton.  UI.exe is not included with this script.

Usage:
  $PROG_NAME [options] [-- UI.exe arguments...]
  curl -fsSL <url-to-this-script> | bash -s -- [options]

Options:
  -h, --help                 Show this help and exit
  --select, --change-exe     Select UI.exe again (file picker)
  --exe PATH                 Use PATH as UI.exe for this and future runs
  --proton PATH              Use the Proton build in PATH
  --download-proton FLAVOR   Download GDK-Proton (gdk) or GE-Proton (ge)
  --setup                    Select UI.exe, install Proton/runtimes, do not launch
  --status                   Show the current configuration and exit
  --install-desktop          Create an application-menu shortcut and exit
  --uninstall                Remove the shortcut and wrapper settings
  --purge                    With --uninstall, also delete the private prefix,
                             downloaded Proton builds and cached installers
  --no-gui                   Never use zenity/kdialog; prompt in the terminal
  --debug                    Keep Proton/Wine logs and verbose output
  --reset                    Forget the saved UI.exe/Proton choices, then run
  --version                  Print the version and exit

Environment:
  LYNIX_DATA_DIR             Override private data folder
                             (default: \$XDG_DATA_HOME/lynix-proton)
  LYNIX_CONFIG_DIR           Override settings folder
                             (default: \$XDG_CONFIG_HOME/lynix-proton)
  LYNIX_PROTON               Use this Proton folder without saving it
  LYNIX_SCRIPT_URL           URL of this script; lets --install-desktop save
                             a copy when the script was run from a pipe

Notes:
  * The script can be piped directly from curl.  Prompts are read from the
    controlling terminal, so stdin remains the script itself.
  * UI.exe is licensed software and is deliberately not bundled here.
  * No Steam installation is required.  Steam Proton installs are used when
    found, otherwise a private GDK-Proton/GE-Proton build is downloaded.
  * WebView2 and the Visual C++ runtime are installed into the private prefix.
  * First setup can take several minutes and needs ~3 GB of free disk space.

Logs:
  $LOG_FILE
EOF
}

say()  { printf '%s\n' "$*"; }
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
have() { command -v "$1" >/dev/null 2>&1; }

TTY_FD=""

init_tty() {
  # When bash reads the script from a pipe, fd 0 is the script, not the user.
  # Prompt through /dev/tty so a "curl -fsSL ... | bash" run stays interactive.
  TTY_FD=""
  if [ -r /dev/tty ] && { true </dev/tty; } 2>/dev/null; then
    TTY_FD="/dev/tty"
  elif [ -t 0 ]; then
    TTY_FD="/dev/stdin"
  fi
}

read_tty() {
  local __var="$1" __line=""
  [ -n "$TTY_FD" ] || return 1
  IFS= read -r __line <"$TTY_FD" || __line=""
  printf -v "$__var" '%s' "$__line"
  return 0
}

gui_init() {
  [ "$NO_GUI" -eq 0 ] || return 0
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    return 0
  fi
  if have zenity; then
    GUI="zenity"
  elif have kdialog; then
    GUI="kdialog"
  elif have yad; then
    GUI="yad"
  fi
}

gui_info() {
  local text="${1//\\n/$'\n'}"
  case "$GUI" in
    zenity) zenity --info --title="$APP_NAME" --text="$text" --width=460 >/dev/null 2>&1 || true ;;
    kdialog) kdialog --title "$APP_NAME" --msgbox "$text" >/dev/null 2>&1 || true ;;
    yad) yad --info --title="$APP_NAME" --text="$text" --width=460 >/dev/null 2>&1 || true ;;
    *) printf '%s\n' "$text" ;;
  esac
}

gui_error() {
  local text="${1//\\n/$'\n'}"
  case "$GUI" in
    zenity) zenity --error --title="$APP_NAME" --text="$text" --width=460 >/dev/null 2>&1 || true ;;
    kdialog) kdialog --title "$APP_NAME" --error "$text" >/dev/null 2>&1 || true ;;
    yad) yad --error --title="$APP_NAME" --text="$text" --width=460 >/dev/null 2>&1 || true ;;
    *) printf 'ERROR: %s\n' "$text" >&2 ;;
  esac
}

gui_yesno() {
  local text="${1//\\n/$'\n'}"
  local answer=""
  case "$GUI" in
    zenity) zenity --question --title="$APP_NAME" --text="$text" --width=460 ;;
    kdialog) kdialog --title "$APP_NAME" --yesno "$text" ;;
    yad) yad --question --title="$APP_NAME" --text="$text" --width=460 ;;
    *)
      [ -n "$TTY_FD" ] || return 1
      printf '%s\nContinue? [y/N] ' "$text" >&2
      read_tty answer || answer=""
      case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

gui_pick_file() {
  local start="$1"
  case "$GUI" in
    zenity)
      zenity --file-selection --title="Select UI.exe" \
        --filename="$start/" \
        --file-filter="Windows executable (*.exe) | *.exe" \
        --file-filter="All files | *"
      ;;
    kdialog)
      kdialog --title "Select UI.exe" \
        --getopenfilename "$start" "*.exe|Windows executable"
      ;;
    yad)
      yad --file-selection --title="Select UI.exe" --filename="$start/"
      ;;
    *) return 1 ;;
  esac
}

gui_pick_dir() {
  local start="$1"
  case "$GUI" in
    zenity) zenity --file-selection --directory --title="Select Proton folder" --filename="$start/" ;;
    kdialog) kdialog --title "Select Proton folder" --getexistingdirectory "$start" ;;
    yad) yad --file-selection --directory --title="Select Proton folder" --filename="$start/" ;;
    *) return 1 ;;
  esac
}

gui_progress_start() {
  local text="${1//\\n/$'\n'}"
  case "$GUI" in
    zenity)
      zenity --progress --pulsate --no-cancel \
        --title="$APP_NAME" --text="$text" --width=420 </dev/null >/dev/null 2>&1 &
      PROGRESS_PID=$!
      ;;
    kdialog)
      # kdialog has no non-blocking progress dialog; use a passive popup if available.
      if have notify-send; then
        notify-send "$APP_NAME" "$text" >/dev/null 2>&1 || true
      fi
      PROGRESS_PID=""
      ;;
    yad)
      yad --progress --pulsate --no-cancel \
        --title="$APP_NAME" --text="$text" --width=420 </dev/null >/dev/null 2>&1 &
      PROGRESS_PID=$!
      ;;
    *) PROGRESS_PID="" ;;
  esac
}

gui_progress_stop() {
  if [ -n "${PROGRESS_PID:-}" ]; then
    kill "$PROGRESS_PID" >/dev/null 2>&1 || true
    wait "$PROGRESS_PID" >/dev/null 2>&1 || true
    PROGRESS_PID=""
  fi
}

die() {
  local msg="$1"
  log "ERROR: $msg"
  if [ -n "$GUI" ]; then
    gui_error "$msg"
  else
    printf 'ERROR: %s\n' "${msg//\\n/$'\n'}" >&2
  fi
  exit 1
}

init_dirs() {
  mkdir -p "$CONFIG_DIR" "$PROTON_ROOT" "$PREFIX_DIR" "$CACHE_DIR" "$LOG_DIR" "$FAKE_STEAM/steamapps/common"
  : >"$LOG_FILE"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || true
}

load_config() {
  EXE_PATH=""
  PROTON_DIR=""
  [ -f "$CONFIG_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      EXE_PATH) EXE_PATH="$val" ;;
      PROTON_DIR) PROTON_DIR="$val" ;;
    esac
  done <"$CONFIG_FILE"
}

save_config() {
  local tmp="$CONFIG_FILE.tmp.$$"
  mkdir -p "$CONFIG_DIR"
  {
    [ -n "${EXE_PATH:-}" ] && printf 'EXE_PATH=%s\n' "$EXE_PATH"
    [ -n "${PROTON_DIR:-}" ] && printf 'PROTON_DIR=%s\n' "$PROTON_DIR"
  } >"$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

proton_valid() {
  [ -n "${1:-}" ] || return 1
  [ -x "$1/proton" ] && [ -d "$1/files" ]
}

proton_version() {
  local dir="$1" raw first second
  if [ -f "$dir/version" ]; then
    raw="$(tr -d '\r\n' <"$dir/version")"
    first="${raw%% *}"
    second="${raw#* }"
    if [[ "$first" =~ ^[0-9]+$ ]] && [ "$second" != "$raw" ]; then
      printf '%s' "$second"
    else
      printf '%s' "$raw"
    fi
  else
    basename -- "$dir"
  fi
}

find_proton_candidates() {
  local -a bases=(
    "$PROTON_ROOT"
    "$HOME/.local/share/Steam/compatibilitytools.d"
    "$HOME/.steam/steam/compatibilitytools.d"
    "$HOME/.steam/root/compatibilitytools.d"
    "$HOME/.local/share/Steam/steamapps/common"
    "$HOME/.steam/steam/steamapps/common"
    "$HOME/.steam/root/steamapps/common"
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common"
    "/usr/share/steam/compatibilitytools.d"
    "/usr/share/steam/steamapps/common"
    "/usr/local/share/steam/compatibilitytools.d"
    "/usr/local/share/steam/steamapps/common"
  )
  local base dir
  local -A seen=()
  for base in "${bases[@]}"; do
    [ -d "$base" ] || continue
    for dir in "$base"/*; do
      [ -d "$dir" ] || continue
      proton_valid "$dir" || continue
      case "$(basename -- "$dir")" in
        *SteamLinuxRuntime*|*EasyAntiCheat*) continue ;;
      esac
      [ -n "${seen[$dir]:-}" ] && continue
      seen[$dir]=1
      printf '%s\n' "$dir"
    done
  done
}

arg_value() {
  # arg_value OPTION VALUE...
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    die "Option $1 needs a value."
  fi
  printf '%s' "$2"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) printf '%s\n' "$APP_NAME 1.0.0"; exit 0 ;;
      --select|--change-exe) FORCE_SELECT=1 ;;
      --exe)
        EXE_ARG="$(arg_value "$1" "${2:-}")"
        shift
        ;;
      --proton)
        PROTON_ARG="$(arg_value "$1" "${2:-}")"
        shift
        ;;
      --download-proton)
        PROTON_DL="$(arg_value "$1" "${2:-}")"
        shift
        case "$PROTON_DL" in
          gdk|ge) ;;
          *) die "--download-proton expects 'gdk' or 'ge'." ;;
        esac
        ;;
      --setup) FORCE_SETUP=1; NO_LAUNCH=1 ;;
      --no-launch) NO_LAUNCH=1 ;;
      --status) SHOW_STATUS=1; NO_LAUNCH=1 ;;
      --install-desktop) INSTALL_DESKTOP=1; NO_LAUNCH=1 ;;
      --uninstall) UNINSTALL=1; NO_LAUNCH=1 ;;
      --purge) PURGE=1 ;;
      --no-gui) NO_GUI=1 ;;
      --debug) DEBUG=1 ;;
      --reset) RESET=1 ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do PASSTHRU+=("$1"); shift; done
        break
        ;;
      -*)
        die "Unknown option: $1 (use --help)"
        ;;
      *)
        PASSTHRU+=("$1")
        ;;
    esac
    shift
  done
}

validate_exe() {
  local path="$1"
  [ -f "$path" ] && [ -r "$path" ] || return 1
  local magic
  magic="$(LC_ALL=C head -c 2 -- "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "4d5a" ]
}

select_exe() {
  local chosen="${EXE_ARG:-}"
  local start="$HOME"
  [ -f "$SCRIPT_DIR/UI.exe" ] && start="$SCRIPT_DIR"

  if [ -n "$chosen" ]; then
    chosen="$(readlink -f -- "$chosen")"
    validate_exe "$chosen" || die "That file is not a readable Windows executable:\n$chosen"
    EXE_PATH="$chosen"
    save_config
    log "Selected UI.exe: $EXE_PATH"
    return 0
  fi

  while :; do
    if [ "$GUI" != "" ]; then
      chosen="$(gui_pick_file "$start" 2>/dev/null || true)"
    else
      printf 'Select the UI.exe file (drag it here or type its path):\n> ' >&2
      read_tty chosen || die "No terminal is available to ask for UI.exe.\nRun again with --exe /path/to/UI.exe."
    fi

    [ -n "$chosen" ] || die "No UI.exe was selected."
    chosen="${chosen#file://}"
    chosen="$(readlink -f -- "$chosen")"
    if validate_exe "$chosen"; then
      EXE_PATH="$chosen"
      save_config
      log "Selected UI.exe: $EXE_PATH"
      gui_info "Selected UI.exe:\n$EXE_PATH"
      return 0
    fi
    gui_error "That file does not look like a Windows .exe:\n$chosen\n\nPlease select UI.exe again."
    start="$(dirname -- "$chosen")"
  done
}

ensure_exe() {
  if [ -n "${EXE_ARG:-}" ]; then
    select_exe
    return 0
  fi
  if [ "$RESET" -eq 1 ]; then
    EXE_PATH=""
    PROTON_DIR=""
    rm -f "$CONFIG_FILE"
  fi
  if [ "$FORCE_SELECT" -eq 1 ] || [ -z "${EXE_PATH:-}" ] || ! validate_exe "${EXE_PATH:-}"; then
    if [ -n "${EXE_PATH:-}" ] && ! validate_exe "$EXE_PATH"; then
      gui_error "The previously selected UI.exe is no longer available:\n$EXE_PATH\n\nPlease select it again."
      EXE_PATH=""
    fi
    select_exe
  fi
}

choose_proton_dir() {
  local chosen
  if [ "$GUI" != "" ]; then
    chosen="$(gui_pick_dir "$HOME" 2>/dev/null || true)"
  else
    printf 'Path to a Proton folder (containing the "proton" executable):\n> ' >&2
    read_tty chosen || die "No terminal is available to ask for a Proton folder.\nRun again with --proton /path/to/Proton."
  fi
  [ -n "$chosen" ] || die "No Proton folder was selected."
  chosen="$(readlink -f -- "$chosen")"
  proton_valid "$chosen" || die "This folder is not a Proton build (no executable 'proton' and 'files' folder):\n$chosen"
  PROTON_DIR="$chosen"
  save_config
}

download_file() {
  local url="$1" dest="$2" label="$3" min_size="${4:-1024}"
  local part="$dest.part.$$"
  local size=0 rc=0

  if [ -f "$dest" ]; then
    size="$(wc -c <"$dest" 2>/dev/null || printf '0')"
    if [ "$size" -ge "$min_size" ]; then
      log "Using cached $label: $dest"
      return 0
    fi
    rm -f "$dest"
  fi

  mkdir -p "$(dirname -- "$dest")"
  rm -f "$part"
  log "Downloading $label from $url"
  if [ -z "$GUI" ]; then
    printf 'Downloading %s...\n' "$label" >&2
  fi
  gui_progress_start "Downloading $label...\nThis can take a few minutes."

  if have curl; then
    if [ "$GUI" != "" ]; then
      curl -fsSL --retry 3 --connect-timeout 30 -o "$part" "$url" >>"$LOG_FILE" 2>&1 || rc=$?
    else
      curl -fsSL --retry 3 --connect-timeout 30 -o "$part" "$url" || rc=$?
    fi
  elif have wget; then
    wget -O "$part" "$url" >>"$LOG_FILE" 2>&1 || rc=$?
  else
    gui_progress_stop
    die "curl or wget is required to download $label."
  fi

  gui_progress_stop
  if [ "$rc" -ne 0 ] || [ ! -f "$part" ]; then
    rm -f "$part"
    die "Download failed: $label\nURL: $url\nSee $LOG_FILE for details."
  fi
  size="$(wc -c <"$part" 2>/dev/null || printf '0')"
  if [ "$size" -lt "$min_size" ]; then
    rm -f "$part"
    die "Downloaded file is too small: $label\nURL: $url"
  fi
  mv -f "$part" "$dest"
  log "Downloaded $label ($size bytes) to $dest"
}

github_asset_url() {
  local repo="$1" pattern="$2"
  local api="https://api.github.com/repos/$repo/releases/latest"
  local json="" rc=0

  if have curl; then
    json="$(curl -fsSL --retry 2 --connect-timeout 20 \
      -H 'User-Agent: lynix-proton-wrapper' \
      -H 'Accept: application/vnd.github+json' "$api" 2>>"$LOG_FILE")" || rc=$?
  elif have wget; then
    json="$(wget -qO- --header='User-Agent: lynix-proton-wrapper' \
      --header='Accept: application/vnd.github+json' "$api" 2>>"$LOG_FILE")" || rc=$?
  else
    die "curl or wget is required to download Proton."
  fi
  [ "$rc" -eq 0 ] && [ -n "$json" ] || return 1

  if have jq; then
    printf '%s' "$json" | jq -r --arg p "$pattern" \
      '.assets[] | select(.name | test($p)) | .browser_download_url' 2>/dev/null | head -n 1
  else
    printf '%s' "$json" \
      | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed 's/.*"\(https[^"]*\)".*/\1/' \
      | grep -E "$pattern" \
      | head -n 1
  fi
}

install_proton_archive() {
  local archive="$1" label="$2"
  local tmp top src dest

  tmp="$(mktemp -d "$PROTON_ROOT/.extract.XXXXXX")"
  gui_progress_start "Extracting $label...\nThis can take a minute."
  if ! tar -xzf "$archive" -C "$tmp" >>"$LOG_FILE" 2>&1; then
    gui_progress_stop
    rm -rf "$tmp"
    die "Could not extract $label. The download may be corrupt."
  fi
  gui_progress_stop

  top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -n "$top" ] && [ "$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
    src="$top"
    dest="$PROTON_ROOT/$(basename -- "$top")"
  else
    src="$tmp"
    dest="$PROTON_ROOT/${label// /-}"
  fi

  if ! proton_valid "$src"; then
    rm -rf "$tmp"
    die "The downloaded $label archive does not contain a Proton build."
  fi

  rm -rf "$dest"
  mv -- "$src" "$dest"
  rm -rf "$tmp"
  proton_valid "$dest" || die "Failed to install $label at:\n$dest"

  PROTON_DIR="$dest"
  save_config
  log "Installed $label at $dest ($(proton_version "$dest"))"
  gui_info "$label is ready.\n\nVersion: $(proton_version "$dest")\nFolder: $dest"
}

download_proton() {
  local flavor="$1"
  local repo pattern label url asset min_size
  case "$flavor" in
    gdk)
      repo="Weather-OS/GDK-Proton"
      pattern='\.tar\.gz$'
      label="GDK-Proton"
      min_size=$((100 * 1024 * 1024))
      ;;
    ge)
      repo="GloriousEggroll/proton-ge-custom"
      pattern='x86_64\.tar\.gz$'
      label="GE-Proton"
      min_size=$((100 * 1024 * 1024))
      ;;
    *) die "Unknown Proton flavor: $flavor" ;;
  esac

  url="$(github_asset_url "$repo" "$pattern" || true)"
  [ -n "$url" ] || die "Could not find the latest $label release on GitHub.\nCheck your internet connection, or pass --proton PATH with an existing Proton folder."
  asset="${url##*/}"
  log "Latest $label asset: $asset"
  download_file "$url" "$CACHE_DIR/$asset" "$asset" "$min_size"
  install_proton_archive "$CACHE_DIR/$asset" "${asset%.tar.gz}"
}

ensure_proton() {
  if [ -n "${PROTON_ARG:-}" ]; then
    PROTON_ARG="$(readlink -f -- "$PROTON_ARG" 2>/dev/null || printf '%s' "$PROTON_ARG")"
    proton_valid "$PROTON_ARG" || die "Not a valid Proton folder:\n$PROTON_ARG"
    PROTON_DIR="$PROTON_ARG"
    save_config
    return 0
  fi

  if [ -n "${LYNIX_PROTON:-}" ]; then
    LYNIX_PROTON="$(readlink -f -- "$LYNIX_PROTON" 2>/dev/null || printf '%s' "$LYNIX_PROTON")"
    proton_valid "$LYNIX_PROTON" || die "LYNIX_PROTON is not a valid Proton folder:\n$LYNIX_PROTON"
    PROTON_DIR="$LYNIX_PROTON"
    return 0
  fi

  if [ -n "$PROTON_DL" ]; then
    download_proton "$PROTON_DL"
    return 0
  fi

  if proton_valid "${PROTON_DIR:-}"; then
    return 0
  fi

  local candidates gdk ge first
  candidates="$(find_proton_candidates || true)"
  if [ -n "$candidates" ]; then
    gdk="$(printf '%s\n' "$candidates" | grep '/GDK-Proton' | head -n 1 || true)"
    ge="$(printf '%s\n' "$candidates" | grep '/GE-Proton' | head -n 1 || true)"
    first="${gdk:-${ge:-$(printf '%s\n' "$candidates" | head -n 1)}}"
    PROTON_DIR="$first"
    save_config
    log "Auto-selected Proton: $PROTON_DIR ($(proton_version "$PROTON_DIR"))"
    return 0
  fi

  if [ "$GUI" != "" ]; then
    gui_info "No Proton build was found.\n\n$APP_NAME can download one into its private folder.\nNo Steam installation is needed."
    if gui_yesno "Download GDK-Proton now?\n\nAbout 500 MB download, then about 1.5 GB extracted."; then
      download_proton gdk
    elif gui_yesno "Download GE-Proton instead?\n\nAbout 540 MB download, then about 1.6 GB extracted."; then
      download_proton ge
    else
      choose_proton_dir
    fi
    return 0
  fi

  if [ -z "$TTY_FD" ]; then
    die "No Proton build was found and no terminal is available to ask.\nInstall Proton in a standard location or run:\n  $PROG_NAME --proton /path/to/Proton"
  fi

  printf 'No Proton build was found.\n' >&2
  printf 'Download GDK-Proton (~500 MB)? [Y/n] ' >&2
  local answer=""
  read_tty answer || answer=""
  case "${answer:-y}" in
    y|Y|yes|YES|'') download_proton gdk; return 0 ;;
  esac
  printf 'Download GE-Proton instead (~540 MB)? [Y/n] ' >&2
  read_tty answer || answer=""
  case "${answer:-y}" in
    y|Y|yes|YES|'') download_proton ge; return 0 ;;
  esac
  choose_proton_dir
}

ensure_prefix() {
  mkdir -p "$PREFIX_DIR" "$FAKE_STEAM/steamapps/common"
  chmod 700 "$PREFIX_DIR" 2>/dev/null || true
}

proton_env() {
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="$FAKE_STEAM"
  export STEAM_COMPAT_DATA_PATH="$PREFIX_DIR"
  export PROTON_LOG=1
  export PROTON_LOG_DIR="$LOG_DIR"
  if [ "$DEBUG" -eq 1 ]; then
    export WINEDEBUG="${WINEDEBUG:-+timestamp,+pid,+seh}"
  else
    export WINEDEBUG="${WINEDEBUG:--all}"
  fi
  mkdir -p "$LOG_DIR"
}

run_installer() {
  local exe="$1"
  shift
  local dir name
  dir="$(dirname -- "$exe")"
  name="$(basename -- "$exe")"
  log "Running installer: $exe $*"
  proton_env
  ( cd "$dir" && "$PROTON_DIR/proton" run "$name" "$@" ) </dev/null >>"$LOG_FILE" 2>&1
}

vc_runtime_version() {
  local reg="$PREFIX_DIR/pfx/system.reg"
  [ -f "$reg" ] || return 1
  awk '
    /^\[Software\\\\Microsoft\\\\VisualStudio\\\\14\.0\\\\VC\\\\Runtimes\\\\x64\]/ { found=1; next }
    found && /^\[/ { exit }
    found && /"Version"/ {
      line=$0
      sub(/.*"Version"="?/, "", line)
      sub(/".*/, "", line)
      print line
      exit
    }
  ' "$reg" 2>/dev/null
}

version_ge_14_51() {
  local ver="$1" major minor
  ver="${ver#v}"
  major="${ver%%.*}"
  ver="${ver#*.}"
  minor="${ver%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$major" -gt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -ge 51 ]; }
}

vc_runtime_ok() {
  local ver
  ver="$(vc_runtime_version || true)"
  [ -n "$ver" ] && version_ge_14_51 "$ver"
}

webview2_installed() {
  local root="$PREFIX_DIR/pfx/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
  local root64="$PREFIX_DIR/pfx/drive_c/Program Files/Microsoft/EdgeWebView/Application"
  if [ -d "$root" ] && find "$root" -maxdepth 3 -name msedgewebview2.exe -print -quit | grep -q .; then
    return 0
  fi
  if [ -d "$root64" ] && find "$root64" -maxdepth 3 -name msedgewebview2.exe -print -quit | grep -q .; then
    return 0
  fi
  return 1
}

ensure_vcredist() {
  if vc_runtime_ok; then
    log "Visual C++ runtime is present: $(vc_runtime_version)"
    return 0
  fi

  local url="https://aka.ms/vc14/vc_redist.x64.exe"
  local installer="$CACHE_DIR/vc_redist.x64.exe"
  download_file "$url" "$installer" "Microsoft Visual C++ runtime" $((5 * 1024 * 1024))

  gui_progress_start "Installing the Microsoft Visual C++ runtime..."
  if ! run_installer "$installer" /install /quiet /norestart; then
    gui_progress_stop
    # A failed setup can still mean "already installed"; check before giving up.
    if ! vc_runtime_ok; then
      die "The Visual C++ runtime installer failed.\nSee $LOG_FILE for details."
    fi
  fi
  gui_progress_stop
  sleep 1
  if ! vc_runtime_ok; then
    die "The Visual C++ runtime was installed, but its version could not be verified.\nSee $LOG_FILE for details."
  fi
  log "Installed Visual C++ runtime: $(vc_runtime_version)"
}

ensure_webview2() {
  if webview2_installed; then
    log "WebView2 runtime is present."
    return 0
  fi

  local url="https://go.microsoft.com/fwlink/?linkid=2124701"
  local installer="$CACHE_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  download_file "$url" "$installer" "Microsoft Edge WebView2 runtime" $((100 * 1024 * 1024))

  gui_progress_start "Installing the Microsoft Edge WebView2 runtime...\nThis can take a few minutes."
  if ! run_installer "$installer" /silent /install; then
    gui_progress_stop
    if ! webview2_installed; then
      die "The WebView2 runtime installer failed.\nSee $LOG_FILE for details."
    fi
  fi
  gui_progress_stop
  sleep 1
  if ! webview2_installed; then
    die "The WebView2 runtime was not found after installation.\nSee $LOG_FILE for details."
  fi
  log "Installed WebView2 runtime."
}

set_webview2_policy() {
  # Software rendering avoids several WebView2/Wine presentation bugs.
  # The policy is local to this private prefix.
  local reg="$PREFIX_DIR/pfx/system.reg"
  if [ -f "$reg" ] && grep -a -q 'AdditionalBrowserArguments' "$reg" 2>/dev/null; then
    return 0
  fi
  log "Setting WebView2 policy for the private prefix."
  proton_env
  "$PROTON_DIR/proton" runinprefix "C:\\windows\\system32\\reg.exe" add \
    "HKLM\\SOFTWARE\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments" \
    /v "*" /t REG_SZ /d "--disable-gpu" /f </dev/null >>"$LOG_FILE" 2>&1 || true
  "$PROTON_DIR/proton" runinprefix "C:\\windows\\system32\\reg.exe" add \
    "HKLM\\SOFTWARE\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments" \
    /v "UI.exe" /t REG_SZ /d "--disable-gpu" /f </dev/null >>"$LOG_FILE" 2>&1 || true
}

ensure_runtimes() {
  ensure_prefix
  ensure_vcredist
  ensure_webview2
  set_webview2_policy
}

show_status() {
  printf '%s\n' "$APP_NAME"
  printf '  UI.exe:   %s\n' "${EXE_PATH:-<not selected>}"
  if [ -n "${PROTON_DIR:-}" ] && proton_valid "$PROTON_DIR"; then
    printf '  Proton:   %s (%s)\n' "$(proton_version "$PROTON_DIR")" "$PROTON_DIR"
  else
    printf '  Proton:   <not selected>\n'
  fi
  printf '  Prefix:   %s\n' "$PREFIX_DIR"
  if [ -d "$PREFIX_DIR/pfx" ]; then
    printf '  VC++:     %s\n' "$(vc_runtime_version 2>/dev/null || echo 'unknown')"
    if webview2_installed; then
      printf '  WebView2: installed\n'
    else
      printf '  WebView2: missing\n'
    fi
  else
    printf '  Prefix:   not created yet\n'
  fi
  printf '  Log:      %s\n' "$LOG_FILE"
  printf '  Settings: %s\n' "$CONFIG_FILE"
}

resolve_script_copy() {
  # A desktop entry needs a persistent path.  Normal runs already have one;
  # "curl -fsSL ... | bash" runs do not, so optionally fetch and keep a copy.
  if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    printf '%s' "$SCRIPT_PATH"
    return 0
  fi
  local copy="$DATA_DIR/$APP_ID.sh"
  if [ -f "$copy" ]; then
    printf '%s' "$copy"
    return 0
  fi
  if [ -n "${LYNIX_SCRIPT_URL:-}" ]; then
    download_file "$LYNIX_SCRIPT_URL" "$copy" "$PROG_NAME" 1024
    chmod +x "$copy" 2>/dev/null || true
    printf '%s' "$copy"
    return 0
  fi
  return 1
}

install_desktop_entry() {
  local self appdir
  if ! self="$(resolve_script_copy)"; then
    die "The application-menu shortcut needs a saved copy of this script.\n\nSave lynix-proton.sh to a file and run:\n  ./lynix-proton.sh --install-desktop\n\nWhen using curl, set LYNIX_SCRIPT_URL to the script URL."
  fi
  appdir="$(dirname -- "$DESKTOP_FILE")"
  mkdir -p "$appdir"
  cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Lynx (Proton)
Comment=Run a user-supplied UI.exe through GE-Proton or GDK-Proton
Exec="$self"
Icon=wine
Terminal=false
Categories=Development;Utility;
StartupNotify=true
StartupWMClass=UI.exe
EOF
  chmod +x "$DESKTOP_FILE" 2>/dev/null || true
  if have update-desktop-database; then
    update-desktop-database "$appdir" >/dev/null 2>&1 || true
  fi
  log "Installed desktop entry: $DESKTOP_FILE"
  gui_info "Application-menu shortcut created:\nLynx (Proton)\n\nIt will use the UI.exe and Proton choice saved by this wrapper."
  printf 'Installed %s\n' "$DESKTOP_FILE"
}

uninstall_wrapper() {
  local purged=0
  rm -f "$DESKTOP_FILE"
  rm -f "$CONFIG_FILE"
  if [ "$PURGE" -eq 1 ]; then
    if gui_yesno "Delete the private Proton prefix, downloaded Proton builds and cached installers?\n\nThis does NOT touch UI.exe or any Steam installation.\n\nFolder: $DATA_DIR"; then
      rm -rf "$DATA_DIR"
      purged=1
    fi
  fi
  gui_info "Removed the shortcut and wrapper settings."
  printf 'Removed %s\n' "$DESKTOP_FILE"
  printf 'Removed %s\n' "$CONFIG_FILE"
  if [ "$purged" -eq 1 ]; then
    printf 'Removed private data at %s\n' "$DATA_DIR"
  else
    printf 'Wrapper data kept at %s\n' "$DATA_DIR"
  fi
}

app_is_running() {
  # Look for the actual UI.exe process belonging to this private prefix.
  # Wine keeps helper processes around, so match the first argument and the
  # prefix environment rather than any process that merely mentions UI.exe.
  local envf pid first
  for envf in /proc/[0-9]*/environ; do
    [ -r "$envf" ] || continue
    pid="${envf#/proc/}"
    pid="${pid%/environ}"
    [ "$pid" = "$$" ] && continue
    grep -Fzxq "STEAM_COMPAT_DATA_PATH=$PREFIX_DIR" "$envf" 2>/dev/null || continue
    first="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | head -n 1)"
    case "$first" in
      UI.exe|UI.EXE|*[\\/]UI.exe|*[\\/]UI.EXE)
        printf '%s' "$pid"
        return 0
        ;;
    esac
  done
  return 1
}

clean_stale_app_state() {
  # UI.exe writes a small IPC endpoint at startup.  If a previous run was
  # killed, those files survive and a later launch may exit with status 5.
  local appdir="$PREFIX_DIR/pfx/drive_c/Lynx"
  rm -f "$appdir/mcp/endpoint.json" "$appdir/port"
}

launch_app() {
  [ -f "$EXE_PATH" ] || die "UI.exe was not found:\n$EXE_PATH"
  [ -x "$PROTON_DIR/proton" ] || die "Proton was not found:\n$PROTON_DIR"

  local running_pid
  if running_pid="$(app_is_running)"; then
    log "Lynx is already running (prefix pid $running_pid); not launching a second instance."
    if have wmctrl; then
      wmctrl -a "Lynx" >/dev/null 2>&1 || true
    elif have xdotool && [ -n "${DISPLAY:-}" ]; then
      xdotool search --name "^Lynx$" windowactivate >/dev/null 2>&1 || true
    fi
    gui_info "Lynx is already running with this wrapper.\n\nIf its window is hidden, open it from the tray icon."
    return 0
  fi

  clean_stale_app_state

  proton_env
  log "Launching $EXE_PATH with $(proton_version "$PROTON_DIR") from $PROTON_DIR"
  if have notify-send; then
    notify-send "$APP_NAME" "Starting Lynx..." >/dev/null 2>&1 || true
  fi

  local rc=0
  local exe_dir exe_name
  exe_dir="$(dirname -- "$EXE_PATH")"
  exe_name="$(basename -- "$EXE_PATH")"
  set +e
  # Proton launches through its internal steam.exe shim.  It must receive a
  # name relative to the working directory, not an absolute Unix path, or the
  # app may start in a broken state and exit shortly afterwards.
  ( cd "$exe_dir" && "$PROTON_DIR/proton" run "$exe_name" "${PASSTHRU[@]}" ) </dev/null >>"$LOG_FILE" 2>&1
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    local tailtext
    tailtext="$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)"
    log "UI.exe/Proton exited with status $rc"
    gui_error "Lynx/Proton exited with status $rc.\n\nLast log lines:\n$tailtext\n\nFull log:\n$LOG_FILE"
    exit "$rc"
  fi
  log "UI.exe exited normally."
}

main() {
  parse_args "$@"
  gui_init
  init_tty

  if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_wrapper
    return 0
  fi

  init_dirs
  load_config

  if [ "$SHOW_STATUS" -eq 1 ]; then
    show_status
    return 0
  fi

  if [ "$INSTALL_DESKTOP" -eq 1 ]; then
    install_desktop_entry
    return 0
  fi

  ensure_exe
  ensure_proton
  ensure_runtimes

  if [ "$NO_LAUNCH" -eq 1 ]; then
    local launch_hint
    if [ -n "$SCRIPT_PATH" ]; then
      launch_hint="$SCRIPT_PATH"
    else
      launch_hint="curl -fsSL <script-url> | bash"
    fi
    show_status
    gui_info "Setup is complete.\n\nUI.exe:\n$EXE_PATH\n\nProton:\n$(proton_version "$PROTON_DIR")\n\nYou can now launch Lynx with:\n$launch_hint"
    return 0
  fi

  launch_app
}

main "$@"
