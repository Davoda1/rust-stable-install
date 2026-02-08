#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Davoda1
#
# updater-tester — Tester for Rust and Fastfetch updater scripts
# POSIX sh; no system modifications; temp-only; full report.
#
# What this script validates:
#   - Local prerequisites + safe fallbacks (tools, temp workspace, downloader)
#   - Upstream "shape" assumptions used by:
#       * rust-stable-install
#       * update-fastfetch
#   - Reachability of relevant endpoints and assets (HTTP HEAD)
#   - Best-effort integrity cues (hash format checks, optional magic-byte checks)
#
# Selection:
#   --rust|--cargo          Rust only
#   --fastfetch|--fetch     Fastfetch only
#   (default: both; mutually exclusive selection flags)
#
# Colors:
#   Only inside [OK]/[WARN]/[ERR] brackets
#   Disabled if stdout not TTY, NO_COLOR is set, or --no-color
#
# Exit codes (bitmask; 0 means “no ERR”):
#   0   OK/WARN only
#   1   Self/infra ERR (tools/tmp/downloader/internet endpoints)
#   2   Rust ERR
#   4   Fastfetch ERR
#   64  Usage error
#   128 Internal tester error (shouldn’t happen)
#
# Notes:
#   - The script is intentionally non-destructive: it only downloads into /tmp and cleans up on exit.
#   - Some "deep" checks (magic bytes via HTTP Range) are best-effort:
#       * If curl is unavailable or the server/CDN does not support Range, the check is skipped (INFO/OK).
#       * A magic mismatch is WARN (can be caused by redirects/proxies), not a hard ERR.

set -eu

SELF_VERSION="1.2.0"
COUNTER=0

# ---------- Pre-scan argv for --no-color ----------
FLAG_NO_COLOR=0
for _a in "$@"; do
    case "$_a" in
        --no-color) FLAG_NO_COLOR=1 ;;
    esac
done
unset _a

# ---------- Colors (ONLY status brackets) ----------
# Enable colors if:
# - stdout is a TTY
# - NO_COLOR env var is NOT set (any value disables)
# - --no-color flag not used
if [ -t 1 ] && [ "${NO_COLOR+x}" != "x" ] && [ "$FLAG_NO_COLOR" -eq 0 ]; then
    RESET="$(printf '\033[0m')"
    BOLD="$(printf '\033[1m')"
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    CYAN="$(printf '\033[36m')"
else
    RESET=""; BOLD=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

# ---------- Output helpers ----------
say() { printf "%s\n" "$*"; }

_ok_br()   { printf "[%s OK %s]" "$GREEN" "$RESET"; }
_warn_br() { printf "[%sWARN%s]" "$YELLOW" "$RESET"; }
_err_br()  { printf "[%sERR %s]" "$RED" "$RESET"; }

# ---------- Dotted lines (status blocks on the LEFT) ----------
LEFT_COL_WIDTH=32
DOTS="........................................"

# Prints: [OK]  - <label padded> .... <message>
_dot_line() {
    _br="$1"      # already-colored bracket string
    _label="$2"
    _msg="$3"

    printf "%s  - %-*s %s" "$_br" "$LEFT_COL_WIDTH" "$_label" "$DOTS"
    if [ -n "$_msg" ]; then
        printf " %s" "$_msg"
    fi
    printf "\n"
}

dot_ok()   { _dot_line "$(_ok_br)"   "$1" "${2:-}"; }
dot_warn() { _dot_line "$(_warn_br)" "$1" "${2:-}"; }
dot_err()  { _dot_line "$(_err_br)"  "$1" "${2:-}" >&2; }

# ---------- Tool checks ----------
need() { command -v "$1" >/dev/null 2>&1; }

# ---------- Temp handling ----------
TMPDIR_BASE="/tmp"
TMPDIR=""

cleanup() {
    [ -n "$TMPDIR" ] && rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

mk_tmpdir() {
    # Prefer mktemp -d; fallback to PID-based dir
    if need mktemp; then
        TMPDIR="$(mktemp -d "${TMPDIR_BASE}/updater-tester.XXXXXX" 2>/dev/null || true)"
    fi
    if [ -z "$TMPDIR" ]; then
        TMPDIR="${TMPDIR_BASE}/updater-tester.$$"
        (umask 077 && mkdir -p "$TMPDIR") 2>/dev/null || true
    fi
    [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]
}

# ---------- Downloader selection ----------
DL_BIN=""
HAS_CURL=0
HAS_WGET2=0
HAS_WGET=0

select_downloader() {
    if need curl; then HAS_CURL=1; fi
    if need wget2; then HAS_WGET2=1; fi
    if need wget; then HAS_WGET=1; fi

    # Ranked: curl > wget2 > wget (matches typical updater preference)
    if [ "$HAS_CURL" -eq 1 ]; then DL_BIN="curl"; return 0; fi
    if [ "$HAS_WGET2" -eq 1 ]; then DL_BIN="wget2"; return 0; fi
    if [ "$HAS_WGET" -eq 1 ]; then DL_BIN="wget"; return 0; fi
    return 1
}

# fetch_stdout DL URL
fetch_stdout() {
    _dl="$1"; _url="$2"
    case "$_dl" in
        curl)  curl -fsSL --connect-timeout 7 --max-time 25 "$_url" ;;
        wget2) wget2 -qO- --https-only --timeout=25 "$_url" ;;
        wget)  wget  -qO- --https-only --timeout=25 "$_url" ;;
        *)     return 1 ;;
    esac
}

# fetch_to_file DL URL OUT
fetch_to_file() {
    _dl="$1"; _url="$2"; _out="$3"
    case "$_dl" in
        curl)  curl -fsSL --connect-timeout 7 --max-time 35 -o "$_out" "$_url" ;;
        wget2) wget2 -q --https-only --timeout=35 -O "$_out" "$_url" ;;
        wget)  wget  -q --https-only --timeout=35 -O "$_out" "$_url" ;;
        *)     return 1 ;;
    esac
}

# head_code DL URL -> prints 3-digit code or 000
head_code() {
    _dl="$1"; _url="$2"
    case "$_dl" in
        curl)
            curl -sS -L -o /dev/null -I --connect-timeout 7 --max-time 20 -w '%{http_code}' "$_url" 2>/dev/null || printf "000"
            ;;
        wget2)
            wget2 -q --spider --server-response --timeout=20 "$_url" 2>&1 \
                | awk '/^  *HTTP\/[0-9.]+/{print $2; exit} END{}' \
                | awk 'NF{print; exit} END{if(NR==0)print "000"}'
            ;;
        wget)
            wget -q --spider --server-response --timeout=20 "$_url" 2>&1 \
                | awk '/^  *HTTP\/[0-9.]+/{print $2; exit} END{}' \
                | awk 'NF{print; exit} END{if(NR==0)print "000"}'
            ;;
        *)
            printf "000"
            ;;
    esac
}

# Best-effort: HTTP Range fetch (bytes START-END) into OUT.
# Uses curl if available (even if DL_BIN is not curl), because wget spider/range behavior varies.
range_to_file() {
    _url="$1"; _out="$2"; _start="$3"; _end="$4"
    if need curl; then
        curl -fsSL --connect-timeout 7 --max-time 25 -H "Range: bytes=${_start}-${_end}" -o "$_out" "$_url" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Extract latest GitHub release tag from /releases/latest redirect (fallback path)
# prints tag (e.g. "2.40.4") or empty
get_latest_tag_from_redirect() {
    _dl="$1"; _url="$2"
    case "$_dl" in
        curl)
            curl -sI --connect-timeout 7 --max-time 20 "$_url" 2>/dev/null \
                | awk 'tolower($1)=="location:"{print $2}' \
                | tail -n 1 \
                | sed 's/[[:space:]\r]//g' \
                | awk -F'/tag/' 'NF>1{print $2}'
            ;;
        wget2)
            wget2 -q --spider --server-response --timeout=20 "$_url" 2>&1 \
                | awk 'tolower($1)=="location:"{print $2}' \
                | tail -n 1 \
                | sed 's/[[:space:]\r]//g' \
                | awk -F'/tag/' 'NF>1{print $2}'
            ;;
        wget)
            wget -q --spider --server-response --timeout=20 "$_url" 2>&1 \
                | awk 'tolower($1)=="location:"{print $2}' \
                | tail -n 1 \
                | sed 's/[[:space:]\r]//g' \
                | awk -F'/tag/' 'NF>1{print $2}'
            ;;
        *)
            printf ""
            ;;
    esac
}

usage() {
    say "${BOLD}updater-tester${RESET} — Tester for Rust/Fastfetch updaters"
    say ""
    say "${BOLD}Usage:${RESET}"
    say "  updater-tester                       ${CYAN}Test both Rust and Fastfetch${RESET}"
    say "  updater-tester --rust|--cargo        ${CYAN}Test Rust only${RESET}"
    say "  updater-tester --fastfetch|--fetch   ${CYAN}Test Fastfetch only${RESET}"
    say "  updater-tester -h|--help             ${CYAN}Show help${RESET}"
    say "  updater-tester -v|--version          ${CYAN}Show versions${RESET}"
    say "  updater-tester --no-color            ${CYAN}Disable colors${RESET}"
    say ""
    say "${BOLD}What it does:${RESET}"
    say "  • Self checks   ............. tools + tmp + downloader + endpoint reachability"
    say "  • Rust checks   ............. manifest parse (version/url/sha) + asset reachability + optional magic"
    say "  • Fastfetch     ............. API/tag discovery + .deb assets + SHA presence/format + optional magic"
    say "  • Summary       ............. list checked URLs/codes + section statuses"
    say ""
    say "${BOLD}Exit codes (bitmask):${RESET}"
    say "  0   OK/WARN only"
    say "  1   Self/infra ERR"
    say "  2   Rust ERR"
    say "  4   Fastfetch ERR"
    say "  64  Usage error"
    say "  128 Internal tester error"
}

print_version() {
    say "updater-tester ${SELF_VERSION}"
    if need rustc; then
        _rv="$(rustc --version 2>/dev/null || true)"
        [ -n "$_rv" ] && say "rustc: $_rv" || say "rustc: present but failed to run"
    else
        say "rustc: not found in PATH"
    fi
    if need cargo; then
        _cv="$(cargo --version 2>/dev/null || true)"
        [ -n "$_cv" ] && say "cargo: $_cv" || say "cargo: present but failed to run"
    else
        say "cargo: not found in PATH"
    fi
    if need fastfetch; then
        _fv="$(fastfetch --version 2>/dev/null | awk 'NR==1{print; exit}' || true)"
        [ -n "$_fv" ] && say "fastfetch: $_fv" || say "fastfetch: present but failed to run"
    else
        say "fastfetch: not found in PATH"
    fi
}

# ---------- Args ----------
DO_RUST=0
DO_FASTFETCH=0
HELP=0
VERSION=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rust|--cargo) DO_RUST=1 ;;
        --fastfetch|--fetch) DO_FASTFETCH=1 ;;
        -h|--help) HELP=1 ;;
        -v|--version) VERSION=1 ;;
        --no-color) : ;; # already pre-scanned; keep accepted
        -*)
            dot_err "Args" "Unknown option: $1"
            usage
            exit 64
            ;;
        *)
            dot_err "Args" "No positional arguments allowed: $1"
            usage
            exit 64
            ;;
    esac
    shift
done

if [ "$HELP" -eq 1 ]; then usage; exit 0; fi
if [ "$VERSION" -eq 1 ]; then print_version; exit 0; fi

if [ "$DO_RUST" -eq 1 ] && [ "$DO_FASTFETCH" -eq 1 ]; then
    dot_err "Args" "Cannot specify both Rust and Fastfetch selection flags"
    usage
    exit 64
fi

if [ "$DO_RUST" -eq 0 ] && [ "$DO_FASTFETCH" -eq 0 ]; then
    DO_RUST=1
    DO_FASTFETCH=1
fi

# ---------- Exit bitmask ----------
EXIT_MASK=0
mask_set() { EXIT_MASK=$((EXIT_MASK | $1)); }

# ---------- URL bookkeeping ----------
INTERNET_URL_GH="https://github.com/"
INTERNET_URL_API="https://api.github.com/"
INTERNET_URL_RUST="https://static.rust-lang.org/"
CODE_GH=""
CODE_API=""
CODE_RUST=""

RUST_MANIFEST_URL="https://static.rust-lang.org/dist/channel-rust-stable.toml"
RUST_MANIFEST_CODE=""
RUST_ASSET_URL=""
RUST_ASSET_CODE=""
RUST_HASH=""
RUST_FMT="unknown"     # xz|gz|unknown

FF_REPO_SLUG="fastfetch-cli/fastfetch"
FF_API_URL="https://api.github.com/repos/${FF_REPO_SLUG}/releases/latest"
FF_API_CODE=""
FF_LATEST_PAGE="https://github.com/${FF_REPO_SLUG}/releases/latest"
FF_REL_PAGE_URL=""
FF_REL_PAGE_CODE=""
FF_ASSET_URL=""
FF_ASSET_CODE=""
FF_ASSET_URL_POLY=""
FF_ASSET_CODE_POLY=""

# ==========================================================
# 1) Self checks
# ==========================================================

COUNTER=$((COUNTER + 1))
say "${BOLD}==============================${RESET}"
say "${BOLD}$COUNTER) Self checks${RESET}"
say "${BOLD}==============================${RESET}"

# Core tools used throughout (hard requirements for meaningful output)
BASE_TOOLS="uname awk grep sed cat head cut rm mkdir"
for t in $BASE_TOOLS; do
    if need "$t"; then
        dot_ok "Tool: $t" "available"
    else
        dot_err "Tool: $t" "missing"
        mask_set 1
    fi
done

# Optional parsing/helpers (these improve diagnostics; missing does not necessarily break updaters)
if need tr; then dot_ok "Tool: tr" "available"; else dot_warn "Tool: tr" "missing (some checks may be skipped)"; fi
if need wc; then dot_ok "Tool: wc" "available"; else dot_warn "Tool: wc" "missing (some checks may be skipped)"; fi

# Optional deep-check tool
if need od; then
    dot_ok "Tool: od" "available (enables magic checks)"
else
    dot_ok "Tool: od" "missing (magic checks skipped)"
fi

# Hash tool (informational)
if need sha256sum; then
    dot_ok "Tool: sha256sum" "available"
elif need shasum; then
    dot_warn "Tool: sha256sum" "missing (fallback: shasum -a 256 available)"
else
    dot_warn "Tool: sha256sum" "missing (hash verification may fail)"
fi

if mk_tmpdir; then
    dot_ok "Temp dir" "$TMPDIR"
else
    dot_err "Temp dir" "failed under ${TMPDIR_BASE}"
    exit 1
fi

if select_downloader; then
    dot_ok "Downloader" "selected: $DL_BIN"
    # Also acceptable options (info, no warning spam)
    if [ "$DL_BIN" = "curl" ]; then
        [ "$HAS_WGET2" -eq 1 ] && dot_ok "Downloader alt" "wget2 available"
        [ "$HAS_WGET" -eq 1 ] && dot_ok "Downloader alt" "wget available"
    elif [ "$DL_BIN" = "wget2" ]; then
        [ "$HAS_WGET" -eq 1 ] && dot_ok "Downloader alt" "wget available"
    fi
else
    dot_err "Downloader" "need curl/wget2/wget"
    exit 1
fi

if [ "$DO_RUST" -eq 1 ]; then
    if need rust-stable-install; then
        dot_ok "Rust updater" "rust-stable-install in PATH"
    else
        dot_warn "Rust updater" "not in PATH: rust-stable-install"
    fi
fi

if [ "$DO_FASTFETCH" -eq 1 ]; then
    if need update-fastfetch; then
        dot_ok "Fastfetch updater" "update-fastfetch in PATH"
    else
        dot_warn "Fastfetch updater" "not in PATH: update-fastfetch"
    fi
fi

# Endpoint reachability (representative)
CODE_GH="$(head_code "$DL_BIN" "$INTERNET_URL_GH")"
case "$CODE_GH" in
    2??|3??) dot_ok "Internet: github.com" "HTTP $CODE_GH" ;;
    *)       dot_err "Internet: github.com" "HTTP $CODE_GH"; mask_set 1 ;;
esac

CODE_API="$(head_code "$DL_BIN" "$INTERNET_URL_API")"
case "$CODE_API" in
    2??|3??) dot_ok "Internet: api.github.com" "HTTP $CODE_API" ;;
    *)       dot_err "Internet: api.github.com" "HTTP $CODE_API"; mask_set 1 ;;
esac

CODE_RUST="$(head_code "$DL_BIN" "$INTERNET_URL_RUST")"
case "$CODE_RUST" in
    2??|3??) dot_ok "Internet: static.rust-lang.org" "HTTP $CODE_RUST" ;;
    *)       dot_err "Internet: static.rust-lang.org" "HTTP $CODE_RUST"; mask_set 1 ;;
esac

# ==========================================================
# 2) Rust checks
# ==========================================================
if [ "$DO_RUST" -eq 1 ]; then
    say ""
    COUNTER=$((COUNTER + 1))
    say "${BOLD}==============================${RESET}"
    say "${BOLD}$COUNTER) Rust checks${RESET}"
    say "${BOLD}==============================${RESET}"

    # Tools the Rust updater is likely to need (informational but useful)
    RUST_TOOLS="bash id tar"
    for t in $RUST_TOOLS; do
        if need "$t"; then
            dot_ok "Rust tool: $t" "available"
        else
            dot_err "Rust tool: $t" "missing"
            mask_set 2
        fi
    done

    # Delete backend expectations (trash preferred; rm fallback)
    if need trash; then
        dot_ok "Delete backend" "trash available"
    else
        dot_ok "Delete backend" "trash missing (rm fallback expected)"
    fi

    if need trash-empty; then
        dot_ok "trash-empty" "available"
    else
        if need trash; then
            dot_warn "trash-empty" "missing (trash present; incomplete backend)"
        else
            dot_ok "trash-empty" "n/a"
        fi
    fi

    if need rm; then
        dot_ok "rm" "available"
    else
        dot_err "rm" "missing"
        mask_set 2
    fi

    OS="$(uname -s 2>/dev/null || printf "unknown")"
    ARCH="$(uname -m 2>/dev/null || printf "unknown")"

    if [ "$OS" = "Linux" ]; then
        dot_ok "OS" "$OS"
    else
        dot_err "OS" "$OS unsupported"
        mask_set 2
    fi

    TRIPLE=""
    case "$ARCH" in
        x86_64|amd64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) TRIPLE="aarch64-unknown-linux-gnu" ;;
        i686|i386)     TRIPLE="i686-unknown-linux-gnu" ;;
        armv7l|armv7|armhf) TRIPLE="armv7-unknown-linux-gnueabihf" ;;
        *)             TRIPLE="" ;;
    esac

    if [ -n "$TRIPLE" ]; then
        dot_ok "Triple" "$TRIPLE"
    else
        dot_err "Arch" "$ARCH unsupported (no triple mapping)"
        mask_set 2
    fi

    RUST_MANIFEST_CODE="$(head_code "$DL_BIN" "$RUST_MANIFEST_URL")"
    if [ "$RUST_MANIFEST_CODE" = "200" ]; then
        dot_ok "Rust manifest" "reachable (HTTP $RUST_MANIFEST_CODE)"
    else
        dot_err "Rust manifest" "HTTP $RUST_MANIFEST_CODE"
        mask_set 2
    fi

    if [ "$RUST_MANIFEST_CODE" = "200" ] && [ -n "$TRIPLE" ]; then
        TMP_MANIFEST="${TMPDIR}/channel-rust-stable.toml"

        if fetch_to_file "$DL_BIN" "$RUST_MANIFEST_URL" "$TMP_MANIFEST"; then
            dot_ok "Fetch manifest" "ok"
        else
            dot_err "Fetch manifest" "failed"
            mask_set 2
        fi

        # Optional: basic "shape" check (matches the older script's intent)
        if [ -s "$TMP_MANIFEST" ]; then
            grep -Eq '^\[pkg\.rust\]' "$TMP_MANIFEST" 2>/dev/null \
                && dot_ok "Manifest shape" "[pkg.rust] present" \
                || { dot_err "Manifest shape" "missing [pkg.rust]"; mask_set 2; }
            grep -Eq '^[[:space:]]*version[[:space:]]*=' "$TMP_MANIFEST" 2>/dev/null \
                && dot_ok "Manifest shape" "version key present" \
                || { dot_err "Manifest shape" "missing version key"; mask_set 2; }
        else
            dot_err "Manifest file" "empty/missing after download"
            mask_set 2
        fi

        if [ -f "$TMP_MANIFEST" ]; then
            PARSED="$(awk -v tgt="$TRIPLE" '
                function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
                function unq(s){ s=trim(s); sub(/^"/,"",s); sub(/"$/,"",s); return s }
                BEGIN { in_pkg=0; in_tgt=0; ver=""; url=""; hash=""; url_f=""; hash_f="" }
                /^\[pkg\.rust\]$/ { in_pkg=1; next }
                /^\[pkg\.rust\./ && $0 !~ /^\[pkg\.rust\]$/ { in_pkg=0 }
                in_pkg && ver=="" && /version[ \t]*=/ { sub(/^.*=/,""); ver=unq($0); split(ver,a," "); ver=a[1] }
                /^\[pkg\.rust\.target\./ { in_tgt = (index($0, tgt) > 0) ? 1 : 0; next }
                /^\[/ && $0 !~ /^\[pkg\.rust\.target\./ { in_tgt=0 }
                in_tgt && url==""   && /xz_url[ \t]*=/  { sub(/^.*=/,""); url=unq($0) }
                in_tgt && url_f=="" && /url[ \t]*=/     { sub(/^.*=/,""); url_f=unq($0) }
                in_tgt && hash==""  && /xz_hash[ \t]*=/ { sub(/^.*=/,""); hash=unq($0) }
                in_tgt && hash_f==""&& /hash[ \t]*=/    { sub(/^.*=/,""); hash_f=unq($0) }
                END {
                    if (url=="" && url_f!="") url=url_f
                    if (hash=="" && hash_f!="") hash=hash_f
                    print ver
                    print url
                    print hash
                }
            ' "$TMP_MANIFEST")"

            RUST_VER="$(printf "%s\n" "$PARSED" | head -n 1)"
            RUST_ASSET_URL="$(printf "%s\n" "$PARSED" | head -n 2 | tail -n 1)"
            RUST_HASH="$(printf "%s\n" "$PARSED" | tail -n 1)"

            if [ -n "$RUST_VER" ]; then
                dot_ok "Manifest version" "$RUST_VER"
            else
                dot_err "Manifest version" "missing"
                mask_set 2
            fi

            if [ -n "$RUST_ASSET_URL" ]; then
                dot_ok "Manifest asset URL" "parsed"

                # POSIX-safe suffix check (rust-stable-install typically accepts .tar.xz or .tar.gz)
                case "$RUST_ASSET_URL" in
                    *.tar.xz|*.tar.gz) dot_ok "Asset suffix" "expected (.tar.xz/.tar.gz)" ;;
                    *)                 dot_warn "Asset suffix" "unexpected (updater may fail)" ;;
                esac

                case "$RUST_ASSET_URL" in
                    *.tar.xz*) RUST_FMT="xz" ;;
                    *.tar.gz*) RUST_FMT="gz" ;;
                    *)         RUST_FMT="unknown" ;;
                esac

                echo "$RUST_ASSET_URL" | grep -Fq "$TRIPLE" \
                    && dot_ok "Asset triple" "present" \
                    || dot_warn "Asset triple" "not in URL"

                RUST_ASSET_CODE="$(head_code "$DL_BIN" "$RUST_ASSET_URL")"
                case "$RUST_ASSET_CODE" in
                    2??|3??) dot_ok "Rust asset" "reachable (HTTP $RUST_ASSET_CODE)" ;;
                    *)       dot_err "Rust asset" "HTTP $RUST_ASSET_CODE"; mask_set 2 ;;
                esac
            else
                dot_err "Manifest asset URL" "missing"
                mask_set 2
            fi

            if [ -n "$RUST_HASH" ]; then
                echo "$RUST_HASH" | grep -Eq '^[0-9a-fA-F]{64}$' \
                    && dot_ok "Asset hash" "64-hex (SHA256)" \
                    || { dot_err "Asset hash" "not 64-hex"; mask_set 2; }
            else
                dot_err "Asset hash" "missing"
                mask_set 2
            fi

            # Optional deep check: verify archive magic bytes via Range (best-effort).
            # - Requires curl (for Range) and od (for magic decoding).
            # - Mismatches are WARN, because redirects/proxies can interfere.
            if [ -n "$RUST_ASSET_URL" ] && [ "$RUST_FMT" != "unknown" ]; then
                if need curl; then
                    dot_ok "Range support" "curl available"
                else
                    dot_ok "Range support" "curl missing (magic check skipped)"
                fi

                if need curl && need od; then
                    SNIP="${TMPDIR}/rust.asset.snip"
                    if range_to_file "$RUST_ASSET_URL" "$SNIP" 0 15; then
                        dot_ok "Magic check" "fetched first bytes (Range)"
                        if [ "$RUST_FMT" = "xz" ]; then
                            # xz magic: FD 37 7A 58 5A 00
                            MAGIC="$(od -An -tx1 -N6 "$SNIP" 2>/dev/null | tr -d ' \n' 2>/dev/null || true)"
                            case "$MAGIC" in
                                fd377a585a00*) dot_ok "Magic xz" "header looks correct" ;;
                                *)             dot_warn "Magic xz" "header mismatch (proxy/redirect?)" ;;
                            esac
                        elif [ "$RUST_FMT" = "gz" ]; then
                            # gzip magic: 1F 8B
                            MAGIC="$(od -An -tx1 -N2 "$SNIP" 2>/dev/null | tr -d ' \n' 2>/dev/null || true)"
                            case "$MAGIC" in
                                1f8b*) dot_ok "Magic gz" "header looks correct" ;;
                                *)     dot_warn "Magic gz" "header mismatch (proxy/redirect?)" ;;
                            esac
                        fi
                    else
                        dot_ok "Magic check" "Range fetch unavailable (skipped)"
                    fi
                else
                    dot_ok "Magic check" "missing curl/od (skipped)"
                fi
            fi
        fi
    fi
fi

# ==========================================================
# 3) Fastfetch checks
# ==========================================================
if [ "$DO_FASTFETCH" -eq 1 ]; then
    say ""
    COUNTER=$((COUNTER + 1))
    say "${BOLD}==============================${RESET}"
    say "${BOLD}$COUNTER) Fastfetch checks${RESET}"
    say "${BOLD}==============================${RESET}"

    if need dpkg; then
        dot_ok "Fastfetch tool: dpkg" "available"
    else
        dot_warn "Fastfetch tool: dpkg" "missing (install step may fail)"
    fi

    if need dpkg-query; then
        dot_ok "Fastfetch tool: dpkg-query" "available"
    else
        dot_ok "Fastfetch tool: dpkg-query" "missing (package version checks skipped)"
    fi

    UNAME_M="$(uname -m 2>/dev/null || printf "unknown")"
    ARCH_TOKEN=""
    case "$UNAME_M" in
        x86_64|amd64)  ARCH_TOKEN="amd64" ;;
        aarch64|arm64) ARCH_TOKEN="aarch64" ;;
        armv7l|armv7|armhf) ARCH_TOKEN="armv7l" ;;
        riscv64)       ARCH_TOKEN="riscv64" ;;
        i686|i386)     ARCH_TOKEN="i686" ;;
        *)             ARCH_TOKEN="" ;;
    esac

    if [ -n "$ARCH_TOKEN" ]; then
        dot_ok "Arch token" "$ARCH_TOKEN"
    else
        dot_err "Arch" "$UNAME_M unsupported"
        mask_set 4
    fi

    ASSET_NAME="fastfetch-linux-${ARCH_TOKEN}.deb"
    ASSET_NAME_POLY="fastfetch-linux-${ARCH_TOKEN}-polyfilled.deb"

    FF_API_CODE="$(head_code "$DL_BIN" "$FF_API_URL")"
    if [ "$FF_API_CODE" = "200" ]; then
        dot_ok "Fastfetch API" "reachable (HTTP $FF_API_CODE)"
    else
        dot_warn "Fastfetch API" "HTTP $FF_API_CODE (fallback via redirect possible)"
    fi

    LATEST_JSON=""
    LATEST_VER=""

    if [ "$FF_API_CODE" = "200" ]; then
        LATEST_JSON="$(fetch_stdout "$DL_BIN" "$FF_API_URL" 2>/dev/null || true)"
        [ -n "$LATEST_JSON" ] && dot_ok "Fetch API JSON" "ok" || dot_warn "Fetch API JSON" "empty/failed"
    fi

    if [ -n "$LATEST_JSON" ]; then
        LATEST_VER="$(printf "%s\n" "$LATEST_JSON" | awk -F'"' '/"tag_name"[ ]*:/ {print $4; exit}')"
        if [ -n "$LATEST_VER" ]; then
            dot_ok "Latest tag" "$LATEST_VER"
        else
            dot_err "Latest tag" "missing in JSON"
            mask_set 4
        fi
    else
        # Fallback: parse /releases/latest redirect for tag, then query tag JSON
        LATEST_VER="$(get_latest_tag_from_redirect "$DL_BIN" "$FF_LATEST_PAGE" 2>/dev/null || true)"
        if [ -n "$LATEST_VER" ]; then
            dot_ok "Latest tag" "redirect -> $LATEST_VER"
            TAG_JSON_URL="https://api.github.com/repos/${FF_REPO_SLUG}/releases/tags/${LATEST_VER}"
            TAG_JSON_CODE="$(head_code "$DL_BIN" "$TAG_JSON_URL")"
            if [ "$TAG_JSON_CODE" = "200" ]; then
                LATEST_JSON="$(fetch_stdout "$DL_BIN" "$TAG_JSON_URL" 2>/dev/null || true)"
                [ -n "$LATEST_JSON" ] && dot_ok "Fetch tag JSON" "ok" || { dot_err "Fetch tag JSON" "empty/failed"; mask_set 4; }
            else
                dot_err "Tag JSON" "HTTP $TAG_JSON_CODE"
                mask_set 4
            fi
        else
            dot_err "Latest tag" "fallback could not parse redirect"
            mask_set 4
        fi
    fi

    if [ -n "$LATEST_JSON" ] && [ -n "$ARCH_TOKEN" ]; then
        # Primary (plain) asset
        FF_ASSET_URL="$(printf "%s\n" "$LATEST_JSON" | awk -v want="$ASSET_NAME" -F'"' '
            $2=="name" && $4==want {found=1; next}
            found && $2=="browser_download_url" {print $4; exit}
        ')"

        if [ -n "$FF_ASSET_URL" ]; then
            dot_ok "Asset URL" "parsed (plain)"
            case "$FF_ASSET_URL" in
                *.deb) dot_ok "Asset suffix" "expected (.deb)" ;;
                *)     dot_err "Asset suffix" "unexpected"; mask_set 4 ;;
            esac

            FF_ASSET_CODE="$(head_code "$DL_BIN" "$FF_ASSET_URL")"
            case "$FF_ASSET_CODE" in
                2??|3??) dot_ok "Asset" "reachable (HTTP $FF_ASSET_CODE)" ;;
                *)       dot_err "Asset" "HTTP $FF_ASSET_CODE"; mask_set 4 ;;
            esac
        else
            dot_err "Asset URL" "asset '${ASSET_NAME}' not found"
            mask_set 4
            say "  Available .deb assets seen:"
            printf "%s\n" "$LATEST_JSON" | awk -F'"' '/"name"[ ]*:/ && $4 ~ /\\.deb$/ {print "    - " $4}'
        fi

        # Optional polyfilled asset (older tester checked this; keep as WARN if missing)
        FF_ASSET_URL_POLY="$(printf "%s\n" "$LATEST_JSON" | awk -v want="$ASSET_NAME_POLY" -F'"' '
            $2=="name" && $4==want {found=1; next}
            found && $2=="browser_download_url" {print $4; exit}
        ')"

        if [ -n "$FF_ASSET_URL_POLY" ]; then
            dot_ok "Asset URL" "parsed (polyfilled)"
            FF_ASSET_CODE_POLY="$(head_code "$DL_BIN" "$FF_ASSET_URL_POLY")"
            case "$FF_ASSET_CODE_POLY" in
                2??|3??) dot_ok "Asset poly" "reachable (HTTP $FF_ASSET_CODE_POLY)" ;;
                *)       dot_warn "Asset poly" "HTTP $FF_ASSET_CODE_POLY (best-effort)";;
            esac
        else
            dot_warn "Asset poly" "not present (OK if upstream stopped publishing)"
        fi

        # Release page + SHA presence/format (best effort)
        if [ -n "$LATEST_VER" ]; then
            FF_REL_PAGE_URL="https://github.com/${FF_REPO_SLUG}/releases/tag/${LATEST_VER}"
            FF_REL_PAGE_CODE="$(head_code "$DL_BIN" "$FF_REL_PAGE_URL")"

            case "$FF_REL_PAGE_CODE" in
                2??|3??) dot_ok "Release page" "reachable (HTTP $FF_REL_PAGE_CODE)" ;;
                *)       dot_err "Release page" "HTTP $FF_REL_PAGE_CODE"; mask_set 4 ;;
            esac

            # SHA extraction:
            # - Try on raw HTML first (more reliable for checksum "lines"),
            # - then fallback to stripped text approach.
            REL_HTML=""
            if [ "$FF_REL_PAGE_CODE" = "200" ]; then
                REL_HTML="$(fetch_stdout "$DL_BIN" "$FF_REL_PAGE_URL" 2>/dev/null || true)"
                [ -n "$REL_HTML" ] && dot_ok "Fetch release HTML" "ok" || { dot_err "Fetch release HTML" "failed"; mask_set 4; }
            fi

            EXPECTED_SHA=""
            if [ -n "$REL_HTML" ]; then
                # Upstream sometimes prints checksums as:
                #   <sha256>  fastfetch-linux-ARCH/fastfetch-linux-ARCH.deb
                #   <sha256>  fastfetch-linux-ARCH.deb
                ASSET_PATH1="$ASSET_NAME"
                ASSET_PATH2="fastfetch-linux-${ARCH_TOKEN}/${ASSET_NAME}"

                EXPECTED_SHA="$(printf "%s\n" "$REL_HTML" | grep -Eo "[0-9a-fA-F]{64}[[:space:]]+${ASSET_PATH2}" 2>/dev/null | head -n 1 | awk '{print $1}' 2>/dev/null || true)"
                [ -z "$EXPECTED_SHA" ] && EXPECTED_SHA="$(printf "%s\n" "$REL_HTML" | grep -Eo "[0-9a-fA-F]{64}[[:space:]]+${ASSET_PATH1}" 2>/dev/null | head -n 1 | awk '{print $1}' 2>/dev/null || true)"

                if [ -n "$EXPECTED_SHA" ]; then
                    dot_ok "Release SHA" "found (64-hex)"
                else
                    # Fallback: strip tags (can help if HTML wraps)
                    REL_TEXT="$(printf "%s\n" "$REL_HTML" | sed 's/<[^>]*>//g' 2>/dev/null || true)"
                    EXPECTED_SHA="$(printf "%s\n" "$REL_TEXT" | grep -F "$ASSET_PATH2" | grep -Eo '[0-9a-fA-F]{64}' | head -n 1 || true)"
                    [ -z "$EXPECTED_SHA" ] && EXPECTED_SHA="$(printf "%s\n" "$REL_TEXT" | grep -F "$ASSET_PATH1" | grep -Eo '[0-9a-fA-F]{64}' | head -n 1 || true)"

                    if [ -n "$EXPECTED_SHA" ]; then
                        dot_ok "Release SHA" "found (64-hex)"
                    else
                        dot_err "Release SHA" "not found for asset"
                        mask_set 4
                    fi
                fi
            fi

            # Optional deep check: verify .deb magic bytes via Range (best-effort).
            # .deb is an ar archive; magic bytes are: "!<arch>\n" (hex: 21 3c 61 72 63 68 3e 0a)
            if [ -n "$FF_ASSET_URL" ]; then
                if need curl && need od; then
                    SNIP="${TMPDIR}/fastfetch.deb.snip"
                    if range_to_file "$FF_ASSET_URL" "$SNIP" 0 15; then
                        dot_ok "Magic check" "fetched first bytes (.deb)"
                        MAGIC="$(od -An -tx1 -N8 "$SNIP" 2>/dev/null | tr -d ' \n' 2>/dev/null || true)"
                        case "$MAGIC" in
                            213c617263683e0a*) dot_ok "Magic .deb" "ar header looks correct" ;;
                            *)                  dot_warn "Magic .deb" "header mismatch (proxy/redirect?)" ;;
                        esac
                    else
                        dot_ok "Magic .deb" "Range fetch unavailable (skipped)"
                    fi
                else
                    dot_ok "Magic .deb" "missing curl/od (skipped)"
                fi
            fi
        fi
    fi

    # Local version info (informational; mirrors older tester)
    if need fastfetch; then
        _vline="$(fastfetch --version 2>/dev/null | awk 'NR==1{print; exit}' || true)"
        [ -n "$_vline" ] && dot_ok "Local fastfetch" "$_vline" || dot_warn "Local fastfetch" "present but version query failed"
    else
        dot_ok "Local fastfetch" "not in PATH"
    fi

    if need dpkg-query; then
        if dpkg-query -W -f='${Status} ${Version}\n' fastfetch 2>/dev/null | grep -q '^install ok installed'; then
            _inst_ver="$(dpkg-query -W -f='${Version}\n' fastfetch 2>/dev/null | awk 'NR==1{print $1}' 2>/dev/null || true)"
            [ -n "$_inst_ver" ] && dot_ok "Installed fastfetch" "dpkg: $_inst_ver" || dot_ok "Installed fastfetch" "installed (version read failed)"
        else
            dot_ok "Installed fastfetch" "not installed via dpkg"
        fi
    fi
fi

# ==========================================================
# 4) Summary
# ==========================================================
say ""
COUNTER=$((COUNTER + 1))
say "${BOLD}==============================${RESET}"
say "${BOLD}$COUNTER) Summary${RESET}"
say "${BOLD}==============================${RESET}"

say "Checked URLs (HTTP codes):"
say "  - github.com:           ${INTERNET_URL_GH} -> ${CODE_GH:-000}"
say "  - api.github.com:       ${INTERNET_URL_API} -> ${CODE_API:-000}"
say "  - static.rust-lang.org: ${INTERNET_URL_RUST} -> ${CODE_RUST:-000}"

if [ "$DO_RUST" -eq 1 ]; then
    say "  - Rust manifest:        ${RUST_MANIFEST_URL} -> ${RUST_MANIFEST_CODE:-000}"
    [ -n "$RUST_ASSET_URL" ] && say "  - Rust asset:           ${RUST_ASSET_URL} -> ${RUST_ASSET_CODE:-000}"
fi

if [ "$DO_FASTFETCH" -eq 1 ]; then
    say "  - Fastfetch API:        ${FF_API_URL} -> ${FF_API_CODE:-000}"
    [ -n "$FF_ASSET_URL" ] && say "  - Fastfetch asset:      ${FF_ASSET_URL} -> ${FF_ASSET_CODE:-000}"
    [ -n "$FF_ASSET_URL_POLY" ] && say "  - Fastfetch asset poly: ${FF_ASSET_URL_POLY} -> ${FF_ASSET_CODE_POLY:-000}"
    [ -n "$FF_REL_PAGE_URL" ] && say "  - Fastfetch release:    ${FF_REL_PAGE_URL} -> ${FF_REL_PAGE_CODE:-000}"
fi

say ""
say "Temp dir used: $TMPDIR (cleaned on exit)"

say ""
say "Section status:"
if [ $((EXIT_MASK & 1)) -eq 0 ]; then dot_ok "Self/infra" "OK/WARN only"; else dot_err "Self/infra" "ERR"; fi
if [ "$DO_RUST" -eq 1 ]; then
    if [ $((EXIT_MASK & 2)) -eq 0 ]; then dot_ok "Rust" "OK/WARN only"; else dot_err "Rust" "ERR"; fi
fi
if [ "$DO_FASTFETCH" -eq 1 ]; then
    if [ $((EXIT_MASK & 4)) -eq 0 ]; then dot_ok "Fastfetch" "OK/WARN only"; else dot_err "Fastfetch" "ERR"; fi
fi

say ""
if [ "$EXIT_MASK" -eq 0 ]; then
    dot_ok "Overall" "OK"
    exit 0
else
    dot_err "Overall" "ERR (exit mask: $EXIT_MASK)"
    exit "$EXIT_MASK"
fi
