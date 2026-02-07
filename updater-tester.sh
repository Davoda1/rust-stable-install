#!/bin/sh
# updater-tester — meticulous, non-destructive environment + upstream-shape tester
# SPDX-License-Identifier: MIT
#
# Purpose:
#   Validate that the *current* upstream assets + local toolchain still match the assumptions used by:
#     - rust-stable-install
#     - update-fastfetch
#
# Guarantees:
#   - Does NOT modify system files.
#   - Network downloads only into a temp dir under /tmp (cleaned on exit).
#   - Exits early ONLY for:
#       (a) script cannot run (Step 0 fatal)
#       (b) no internet to required endpoints (Step 1 fatal)
#     Everything else produces a full report.
#
# Usage:
#   updater-tester              # run Rust + Fastfetch tests
#   updater-tester --rust       # run Rust tests only
#   updater-tester --fastfetch  # run Fastfetch tests only
#   updater-tester --version
#   updater-tester -h|--help
#
# Exit codes (documented + stable):
#   0 = All selected test groups PASSED (warnings allowed)
#   1 = Usage / argument error
#   2 = Step (0) fatal: cannot run tests (no downloader, no mktemp, etc.)
#   3 = Step (1) fatal: no internet connectivity to required endpoints
#   4 = One or more selected test groups FAILED (script ran; checks found breakage)
#
# Notes:
#   - Colors are intentionally minimal: only the "[OK]/[WARN]/[FAIL]/[INFO]" tags.
#   - Honors NO_COLOR env var (any non-empty value disables color).

VERSION="1.0.0"

NUMBERING=2
NUMBERING_CURRENT=0

# ----------------------------- Dumb-user guard: args -----------------------------

want_rust=0
want_fastfetch=0
show_help=0
show_version=0

# If no group flags given, default to BOTH at end.
saw_group_flag=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rust|--cargo)
            want_rust=1
            saw_group_flag=1
            ;;
        --fastfetch|--fetch)
            want_fastfetch=1
            saw_group_flag=1
            ;;
        -h|--help)
            show_help=1
            ;;
        --version)
            show_version=1
            ;;
        --) shift; break ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Run: $0 --help" >&2
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "Run: $0 --help" >&2
            exit 1
            ;;
    esac
    shift
done

if [ "$show_help" -eq 1 ]; then
    cat <<EOF
updater-tester — meticulous, non-destructive updater sanity tester

USAGE
  $0 [--rust|--cargo] [--fastfetch|--fetch] [-h|--help] [--version]

BEHAVIOR
  - If neither --rust nor --fastfetch is provided: runs BOTH groups.
  - You may run only one group for speed/readability.
  - --help overrides all other flags (prints help and exits 0).
  - --version prints script version plus rust/fastfetch versions (if available) and exits 0.

EXIT CODES
  0 ok (warnings allowed)
  1 usage / argument error
  2 fatal: cannot run tests (missing essential local tools)
  3 fatal: no internet access to required endpoints
  4 failures detected (upstream shape or local requirements changed)

ENV
  NO_COLOR=1   disable colored status tags
EOF
    exit 0
fi

# Sets numbering
[ "$want_rust" -eq 1 ] && NUMBERING=$((NUMBERING + 1))
[ "$want_fastfetch" -eq 1 ] && NUMBERING=$((NUMBERING + 1))
# Default to both if user didn't specify a group flag
if [ "$saw_group_flag" -eq 0 ]; then
    want_rust=1
    want_fastfetch=1
    NUMBERING=4
fi

if [ "$show_version" -eq 1 ]; then
    echo "updater-tester version: $VERSION"

    if command -v rustc >/dev/null 2>&1; then
        rustc_v="$(rustc --version 2>/dev/null || echo 'rustc (present, version query failed)')"
        echo "rustc: $rustc_v"
    else
        echo "rustc: (not in PATH)"
    fi

    if command -v cargo >/dev/null 2>&1; then
        cargo_v="$(cargo --version 2>/dev/null || echo 'cargo (present, version query failed)')"
        echo "cargo: $cargo_v"
    else
        echo "cargo: (not in PATH)"
    fi

    if command -v fastfetch >/dev/null 2>&1; then
        ff_v="$(fastfetch --version 2>/dev/null | awk 'NR==1{print $0; exit}' 2>/dev/null)"
        [ -n "$ff_v" ] || ff_v="fastfetch (present, version query failed)"
        echo "fastfetch: $ff_v"
    else
        echo "fastfetch: (not in PATH)"
    fi

    exit 0
fi

# ----------------------------- Minimal color tags ------------------------------

use_color=1
if [ -n "${NO_COLOR:-}" ]; then
    use_color=0
fi
if [ ! -t 1 ]; then
    use_color=0
fi

if [ "$use_color" -eq 1 ]; then
    if command -v tput >/dev/null 2>&1; then
        C_OK="$(tput setaf 2 2>/dev/null || printf '')"
        C_WARN="$(tput setaf 3 2>/dev/null || printf '')"
        C_FAIL="$(tput setaf 1 2>/dev/null || printf '')"
        C_INFO="$(tput setaf 6 2>/dev/null || printf '')"
        C_RST="$(tput sgr0 2>/dev/null || printf '')"
    else
        C_OK="$(printf '\033[32m')"
        C_WARN="$(printf '\033[33m')"
        C_FAIL="$(printf '\033[31m')"
        C_INFO="$(printf '\033[36m')"
        C_RST="$(printf '\033[0m')"
    fi
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_RST=""
fi

say() { printf "%s\n" "$*"; }
tag_ok()   { printf "%s[OK]%s %s\n"   "$C_OK"   "$C_RST" "$*"; }
tag_warn() { printf "%s[WARN]%s %s\n" "$C_WARN" "$C_RST" "$*"; }
tag_fail() { printf "%s[FAIL]%s %s\n" "$C_FAIL" "$C_RST" "$*"; }
tag_info() { printf "%s[INFO]%s %s\n" "$C_INFO" "$C_RST" "$*"; }

hr() {
    # Visual separator, no fancy chars for maximal compatibility
    say "--------------------------------------------------------------------"
}

# ----------------------------- Bookkeeping -------------------------------------

WARNINGS=0
FAILURES=0
FATAL=0

warn() { WARNINGS=$((WARNINGS + 1)); tag_warn "$*"; }
fail() { FAILURES=$((FAILURES + 1)); tag_fail "$*"; }
fatal() { FATAL=1; tag_fail "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------- Block 1: Self checks ----------------------------

NUMBERING_CURRENT=1
hr
say "BLOCK $NUMBERING_CURRENT/$NUMBERING: SELF CHECKS (tester prerequisites + safe fallbacks)"
hr

tag_info "Step 0: Local tool availability checks"

# Essentials for the tester itself
if ! have_cmd mktemp; then fatal "mktemp is required to safely create /tmp workspace."; fi
if ! have_cmd uname; then fatal "uname is required for OS/arch detection."; fi

# Parsing helpers (strongly recommended)
if have_cmd awk; then tag_ok "Found: awk"; else fail "Missing: awk — parsing will be unreliable."; fi
if have_cmd grep; then tag_ok "Found: grep"; else fail "Missing: grep — parsing will be unreliable."; fi

# Optional utilities
if have_cmd sed; then tag_ok "Found: sed"; else warn "Missing: sed — some checks may be skipped."; fi
if have_cmd tr; then tag_ok "Found: tr"; else warn "Missing: tr — some checks may be skipped."; fi
if have_cmd head; then tag_ok "Found: head"; else warn "Missing: head — some checks may be skipped."; fi
if have_cmd wc; then tag_ok "Found: wc"; else warn "Missing: wc — some checks may be skipped."; fi
if have_cmd od; then tag_ok "Found: od (enables file-magic checks)"; else tag_info "od not found (file-magic checks skipped)"; fi

# Downloader selection (ranked). IMPORTANT: if a higher-ranked tool exists, do NOT warn about fallbacks.
DL_PRIMARY=""
if have_cmd curl; then
    DL_PRIMARY="curl"
    tag_ok "Downloader selected: curl"
elif have_cmd wget2; then
    DL_PRIMARY="wget2"
    warn "curl not found; using fallback downloader: wget2"
elif have_cmd wget; then
    DL_PRIMARY="wget"
    warn "curl and wget2 not found; using fallback downloader: wget"
else
    fatal "No downloader found. Install at least one of: curl, wget2, wget"
fi

# Hash tool (informational; some updaters use it, but this tester mostly checks format)
HASH256=""
if have_cmd sha256sum; then
    HASH256="sha256sum"
    tag_ok "Hash tool: sha256sum"
elif have_cmd shasum; then
    HASH256="shasum -a 256"
    warn "sha256sum not found; using fallback hash tool: shasum -a 256"
else
    tag_info "No SHA-256 tool found (sha256sum/shasum). Hash *verification* steps are limited."
fi

# Fastfetch-related local info (informational)
if have_cmd dpkg-query; then tag_ok "Found: dpkg-query"; else tag_info "dpkg-query not found (package version checks skipped)"; fi
if have_cmd dpkg; then tag_ok "Found: dpkg"; else tag_info "dpkg not found (installer would fail on this system)"; fi

# Rust tools in PATH (informational)
if have_cmd rustc; then tag_ok "Found: rustc"; else tag_info "rustc not found in PATH"; fi
if have_cmd cargo; then tag_ok "Found: cargo"; else tag_info "cargo not found in PATH"; fi

if [ "$FATAL" -eq 1 ]; then
    exit 2
fi

# Temp workspace
TMPDIR="$(mktemp -d "/tmp/updater-tester.XXXXXX" 2>/dev/null)"
if [ -z "$TMPDIR" ] || [ ! -d "$TMPDIR" ]; then
    tag_fail "Could not create temporary directory under /tmp."
    exit 2
fi

cleanup() { rm -rf "$TMPDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM

tag_ok "Workspace: $TMPDIR (will be removed on exit)"

# ----------------------------- HTTP helpers ------------------------------------

http_get() {
    url="$1"; out="$2"
    case "$DL_PRIMARY" in
        curl)  curl -f -sS -L "$url" -o "$out" >/dev/null 2>&1 ;;
        wget2) wget2 -q -O "$out" "$url" >/dev/null 2>&1 ;;
        wget)  wget -q -O "$out" "$url" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

http_head_status() {
    url="$1"; code="000"

    # Prefer curl for status if available (even if DL_PRIMARY is not curl)
    if have_cmd curl; then
        code="$(curl -sS -o /dev/null -L -I -w "%{http_code}" "$url" 2>/dev/null || echo "000")"
        printf "%s" "$code"
        return 0
    fi

    # wget/wget2 spider parsing fallback
    if have_cmd wget; then
        line="$(wget -S --spider "$url" 2>&1 | grep -E 'HTTP/[0-9]\.[0-9] ' | tail -n 1)"
        code="$(printf "%s" "$line" | awk '{print $2}' 2>/dev/null)"
        [ -n "$code" ] || code="000"
        printf "%s" "$code"
        return 0
    fi

    if have_cmd wget2; then
        line="$(wget2 --spider "$url" 2>&1 | grep -E 'HTTP/[0-9]\.[0-9] ' | tail -n 1)"
        code="$(printf "%s" "$line" | awk '{print $2}' 2>/dev/null)"
        [ -n "$code" ] || code="000"
        printf "%s" "$code"
        return 0
    fi

    printf "%s" "$code"
    return 0
}

http_range() {
    url="$1"; out="$2"; start="$3"; end="$4"
    if have_cmd curl; then
        curl -f -sS -L -H "Range: bytes=${start}-${end}" "$url" -o "$out" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# ----------------------------- Step (1): internet access ------------------------

tag_info "Step 1: Internet access test (fatal if missing)"

RUST_MANIFEST_URL="https://static.rust-lang.org/dist/channel-rust-stable.toml"
FF_GH_LATEST_API="https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest"
FF_GH_RELEASES="https://github.com/fastfetch-cli/fastfetch/releases/latest"

check_net_endpoint() {
    name="$1"; url="$2"
    code="$(http_head_status "$url")"
    case "$code" in
        2??|3??)
            tag_ok "Reachable: $name ($url) HTTP $code"
            return 0
            ;;
        *)
            fail "Unreachable: $name ($url) HTTP $code"
            return 1
            ;;
    esac
}

net_failed=0
if [ "$want_rust" -eq 1 ]; then
    check_net_endpoint "Rust stable manifest" "$RUST_MANIFEST_URL" || net_failed=1
fi
if [ "$want_fastfetch" -eq 1 ]; then
    check_net_endpoint "Fastfetch GitHub API latest release" "$FF_GH_LATEST_API" || net_failed=1
    check_net_endpoint "Fastfetch GitHub releases page" "$FF_GH_RELEASES" || net_failed=1
fi

if [ "$net_failed" -eq 1 ]; then
    tag_fail "Step 1 failed: required internet endpoints not reachable."
    exit 3
fi

tag_ok "Step 1 passed: internet access looks OK for selected test groups."

# ----------------------------- Shared OS/arch detection -------------------------

tag_info "Host detection"
OS_NAME="$(uname -s 2>/dev/null || echo "unknown")"
UNAME_M="$(uname -m 2>/dev/null || echo "unknown")"
tag_ok "OS: $OS_NAME"
tag_ok "Arch (uname -m): $UNAME_M"

# ----------------------------- Block 2: Rust checks -----------------------------

rust_target_triple=""
rust_manifest_path="$TMPDIR/channel-rust-stable.toml"
rust_tar_url=""
rust_tar_hash=""

get_rust_triple_from_uname() {
    m="$1"
    case "$m" in
        x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        i686|i386) echo "i686-unknown-linux-gnu" ;;
        armv7l|armv7|armhf) echo "armv7-unknown-linux-gnueabihf" ;;
        *) echo "" ;;
    esac
}

parse_rust_manifest_for_triple() {
    manifest="$1"; triple="$2"
    awk -v tgt="$triple" '
        BEGIN { in_tgt=0; url=""; hash="" }
        /^\[pkg\.rust\.target\./ {
            in_tgt = ($0 ~ ("\\[pkg\\.rust\\.target\\." tgt "\\]"))
        }
        /^\[/ && $0 !~ /^\[pkg\.rust\.target\./ { in_tgt=0 }
        in_tgt && $0 ~ /^url[[:space:]]*=/ {
            gsub(/\r/,"")
            match($0, /"[^"]+"/)
            if (RSTART > 0) url=substr($0, RSTART+1, RLENGTH-2)
        }
        in_tgt && $0 ~ /^hash[[:space:]]*=/ {
            gsub(/\r/,"")
            match($0, /"[^"]+"/)
            if (RSTART > 0) hash=substr($0, RSTART+1, RLENGTH-2)
        }
        END { if (url != "" && hash != "") printf "%s|%s", url, hash }
    ' "$manifest" 2>/dev/null
}

if [ "$want_rust" -eq 1 ]; then
    NUMBERING_CURRENT=$((NUMBERING_CURRENT + 1))
    hr
    say "BLOCK $NUMBERING_CURRENT/$NUMBERING: RUST CHECKS (matches rust-stable-install expectations)"
    hr

    tag_info "Step 2-3 (Rust): Endpoints + manifest shape + asset format"

    if http_get "$RUST_MANIFEST_URL" "$rust_manifest_path"; then
        tag_ok "Downloaded Rust manifest to: $rust_manifest_path"
    else
        fail "Could not download Rust manifest via $DL_PRIMARY: $RUST_MANIFEST_URL"
    fi

    if [ -s "$rust_manifest_path" ]; then
        bytes="$(wc -c < "$rust_manifest_path" 2>/dev/null | tr -d ' ' 2>/dev/null)"
        [ -n "$bytes" ] || bytes="(unknown)"
        tag_ok "Manifest size: $bytes bytes"

        if grep -Eq '^[[:space:]]*version[[:space:]]*=' "$rust_manifest_path" 2>/dev/null \
           && grep -Eq '^\[pkg\.rust\]' "$rust_manifest_path" 2>/dev/null; then
            tag_ok "Manifest contains [pkg.rust] and version key."
        else
            fail "Manifest shape changed: missing [pkg.rust] and/or version key."
        fi

        if [ "$OS_NAME" != "Linux" ]; then
            fail "Host OS is not Linux ($OS_NAME). rust-stable-install expects Linux targets."
        else
            tag_ok "Host OS is Linux (matches rust-stable-install assumptions)."
        fi

        rust_target_triple="$(get_rust_triple_from_uname "$UNAME_M")"
        if [ -z "$rust_target_triple" ]; then
            fail "Unsupported/unknown arch for rust-stable-install mapping: uname -m = $UNAME_M"
        else
            tag_ok "Mapped Rust target triple: $rust_target_triple"
        fi

        if [ -n "$rust_target_triple" ]; then
            if grep -Fq "[pkg.rust.target.$rust_target_triple]" "$rust_manifest_path" 2>/dev/null; then
                tag_ok "Manifest contains target table: [pkg.rust.target.$rust_target_triple]"
            else
                fail "Manifest missing target table for triple: $rust_target_triple"
            fi
        fi

        if [ -n "$rust_target_triple" ] && [ -f "$rust_manifest_path" ]; then
            pair="$(parse_rust_manifest_for_triple "$rust_manifest_path" "$rust_target_triple")"
            rust_tar_url="$(printf "%s" "$pair" | awk -F'|' '{print $1}' 2>/dev/null)"
            rust_tar_hash="$(printf "%s" "$pair" | awk -F'|' '{print $2}' 2>/dev/null)"

            if [ -n "$rust_tar_url" ]; then
                tag_ok "Parsed Rust tarball URL for triple: $rust_tar_url"
            else
                fail "Could not parse Rust tarball URL for triple: $rust_target_triple"
            fi

            if [ -n "$rust_tar_hash" ]; then
                tag_ok "Parsed Rust SHA256 for triple: $rust_tar_hash"
            else
                fail "Could not parse Rust SHA256 for triple: $rust_target_triple"
            fi

            if printf "%s" "$rust_tar_hash" | grep -Eq '^[0-9a-fA-F]{64}$' 2>/dev/null; then
                tag_ok "SHA256 format looks valid (64 hex)."
            else
                fail "SHA256 format invalid (expected 64 hex): $rust_tar_hash"
            fi

            if [ -n "$rust_tar_url" ] && printf "%s" "$rust_tar_url" | grep -Fq "$rust_target_triple" 2>/dev/null; then
                tag_ok "URL sanity check passed: contains target triple."
            else
                fail "URL sanity check failed: URL does not contain target triple."
            fi

            # IMPORTANT: match updater behavior. rust-stable-install may accept .tar.xz OR .tar.gz.
            rust_fmt="unknown"
            if printf "%s" "$rust_tar_url" | grep -Eq '\.tar\.xz([?#].*)?$' 2>/dev/null; then
                rust_fmt="xz"
                tag_ok "Archive format: .tar.xz (supported)"
            elif printf "%s" "$rust_tar_url" | grep -Eq '\.tar\.gz([?#].*)?$' 2>/dev/null; then
                rust_fmt="gz"
                tag_ok "Archive format: .tar.gz (supported)"
            else
                warn "Archive format: not .tar.xz or .tar.gz — updater may fail: $rust_tar_url"
            fi

            if [ -n "$rust_tar_url" ]; then
                code="$(http_head_status "$rust_tar_url")"
                case "$code" in
                    2??|3??) tag_ok "Tarball URL reachable (HTTP $code)" ;;
                    *) fail "Tarball URL not reachable (HTTP $code): $rust_tar_url" ;;
                esac
            fi

            # Deep check (best-effort): verify magic bytes for the detected format.
            # NOTE: Range support varies by CDN; inability to Range-fetch is INFO, not WARN.
            rust_snip="$TMPDIR/rust.tar.snip"
            if [ -n "$rust_tar_url" ] && [ "$rust_fmt" != "unknown" ]; then
                if http_range "$rust_tar_url" "$rust_snip" 0 15; then
                    tag_ok "Downloaded first 16 bytes of archive (Range request)."
                    if have_cmd od; then
                        if [ "$rust_fmt" = "xz" ]; then
                            # xz magic: FD 37 7A 58 5A 00
                            magic="$(od -An -tx1 -N6 "$rust_snip" 2>/dev/null | tr -d ' \n' 2>/dev/null)"
                            case "$magic" in
                                fd377a585a00*) tag_ok "xz magic header detected." ;;
                                *) warn "xz magic header NOT detected (Range/redirect/proxy may interfere)." ;;
                            esac
                        elif [ "$rust_fmt" = "gz" ]; then
                            # gzip magic: 1F 8B
                            magic="$(od -An -tx1 -N2 "$rust_snip" 2>/dev/null | tr -d ' \n' 2>/dev/null)"
                            case "$magic" in
                                1f8b*) tag_ok "gzip magic header detected." ;;
                                *) warn "gzip magic header NOT detected (Range/redirect/proxy may interfere)." ;;
                            esac
                        fi
                    else
                        tag_info "od not available — skipping file-magic check."
                    fi
                else
                    tag_info "Range-fetch not available (needs curl + server support) — skipping file-magic check."
                fi
            fi
        fi
    else
        fail "Rust manifest file is empty or missing after download."
    fi
fi

# ----------------------------- Block 3: Fastfetch checks ------------------------

ff_api_json="$TMPDIR/ff.latest.json"
ff_release_html="$TMPDIR/ff.release.html"
ff_tag=""
ff_arch_token=""
ff_asset_plain=""
ff_asset_poly=""
ff_asset_url_plain=""
ff_asset_url_poly=""

map_fastfetch_arch_token() {
    m="$1"
    case "$m" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7|armhf) echo "armv7l" ;;
        riscv64) echo "riscv64" ;;
        i686|i386) echo "i686" ;;
        *) echo "" ;;
    esac
}

parse_github_latest_tag() {
    awk -F'"' '/"tag_name"[[:space:]]*:/ {print $4; exit}' "$1" 2>/dev/null
}

parse_asset_url_for_name() {
    json="$1"; want="$2"
    awk -v want="$want" -F'"' '
        $0 ~ /"name"[[:space:]]*:/ && $4 == want { found=1 }
        found && $0 ~ /"browser_download_url"[[:space:]]*:/ { print $4; exit }
    ' "$json" 2>/dev/null
}

if [ "$want_fastfetch" -eq 1 ]; then
    NUMBERING_CURRENT=$((NUMBERING_CURRENT + 1))
    hr
    say "BLOCK $NUMBERING_CURRENT/$NUMBERING: FASTFETCH CHECKS (matches update-fastfetch expectations)"
    hr

    tag_info "Step 4-5 (Fastfetch): Endpoints + API shape + assets + checksum format"

    ff_arch_token="$(map_fastfetch_arch_token "$UNAME_M")"
    if [ -z "$ff_arch_token" ]; then
        fail "Unsupported/unknown arch for fastfetch updater mapping: uname -m = $UNAME_M"
    else
        tag_ok "Mapped Fastfetch arch token: $ff_arch_token"
    fi

    if http_get "$FF_GH_LATEST_API" "$ff_api_json"; then
        tag_ok "Downloaded GitHub latest-release JSON: $ff_api_json"
    else
        fail "Could not download GitHub API JSON: $FF_GH_LATEST_API"
    fi

    if [ -s "$ff_api_json" ]; then
        ff_tag="$(parse_github_latest_tag "$ff_api_json")"
        if [ -n "$ff_tag" ]; then
            tag_ok "Parsed latest tag_name: $ff_tag"
        else
            fail "Could not parse tag_name from GitHub API JSON (shape changed or rate-limited output)."
        fi

        if [ -n "$ff_arch_token" ]; then
            ff_asset_plain="fastfetch-linux-${ff_arch_token}.deb"
            ff_asset_poly="fastfetch-linux-${ff_arch_token}-polyfilled.deb"
            tag_ok "Expected asset (plain): $ff_asset_plain"
            tag_ok "Expected asset (polyfilled): $ff_asset_poly"
        fi

        if [ -n "$ff_asset_plain" ]; then
            ff_asset_url_plain="$(parse_asset_url_for_name "$ff_api_json" "$ff_asset_plain")"
            if [ -n "$ff_asset_url_plain" ]; then
                tag_ok "Found browser_download_url for plain asset."
                tag_ok "Asset URL (plain): $ff_asset_url_plain"
            else
                fail "Missing plain asset in latest release JSON: $ff_asset_plain"
            fi
        fi

        if [ -n "$ff_asset_poly" ]; then
            ff_asset_url_poly="$(parse_asset_url_for_name "$ff_api_json" "$ff_asset_poly")"
            if [ -n "$ff_asset_url_poly" ]; then
                tag_ok "Found browser_download_url for polyfilled asset."
                tag_ok "Asset URL (polyfilled): $ff_asset_url_poly"
            else
                warn "Polyfilled asset not present in latest release JSON (OK if upstream stopped publishing it)."
            fi
        fi

        if [ -n "$ff_asset_url_plain" ]; then
            code="$(http_head_status "$ff_asset_url_plain")"
            case "$code" in
                2??|3??) tag_ok "Plain .deb URL reachable (HTTP $code)" ;;
                *) fail "Plain .deb URL not reachable (HTTP $code): $ff_asset_url_plain" ;;
            esac
        fi
        if [ -n "$ff_asset_url_poly" ]; then
            code="$(http_head_status "$ff_asset_url_poly")"
            case "$code" in
                2??|3??) tag_ok "Polyfilled .deb URL reachable (HTTP $code)" ;;
                *) warn "Polyfilled .deb URL not reachable (HTTP $code): $ff_asset_url_poly" ;;
            esac
        fi

        if [ -n "$ff_tag" ]; then
            rel_url="https://github.com/fastfetch-cli/fastfetch/releases/tag/${ff_tag}"
            if http_get "$rel_url" "$ff_release_html"; then
                tag_ok "Downloaded release page HTML: $rel_url"
            else
                fail "Could not download release page HTML: $rel_url"
            fi
        else
            fail "No release tag parsed; cannot check release page checksum formatting."
        fi

        if [ -s "$ff_release_html" ] && [ -n "$ff_arch_token" ] && [ -n "$ff_asset_plain" ]; then
            p1="$ff_asset_plain"
            p2="fastfetch-linux-${ff_arch_token}/${ff_asset_plain}"

            sha_plain="$(grep -Eo "[0-9a-fA-F]{64}[[:space:]]+${p2}" "$ff_release_html" 2>/dev/null | head -n 1 | awk '{print $1}' 2>/dev/null)"
            if [ -z "$sha_plain" ]; then
                sha_plain="$(grep -Eo "[0-9a-fA-F]{64}[[:space:]]+${p1}" "$ff_release_html" 2>/dev/null | head -n 1 | awk '{print $1}' 2>/dev/null)"
            fi

            if [ -n "$sha_plain" ]; then
                tag_ok "Found checksum line for plain asset in release HTML."
                tag_ok "Checksum (plain): $sha_plain"
            else
                fail "Could not find checksum line for plain asset in release HTML."
                fail "Tried patterns:"
                fail "  - <sha256>  ${p2}"
                fail "  - <sha256>  ${p1}"
            fi

            # Best-effort .deb magic check (ar archive) via Range
            ff_snip="$TMPDIR/ff.deb.snip"
            if [ -n "$ff_asset_url_plain" ]; then
                if http_range "$ff_asset_url_plain" "$ff_snip" 0 15; then
                    tag_ok "Downloaded first 16 bytes of .deb (Range request)."
                    if have_cmd od; then
                        magic="$(od -An -tx1 -N8 "$ff_snip" 2>/dev/null | tr -d ' \n' 2>/dev/null)"
                        case "$magic" in
                            213c617263683e0a*) tag_ok ".deb/ar magic header detected (!<arch>\\n)." ;;
                            *) warn ".deb magic header not detected (Range/redirect/proxy may interfere)." ;;
                        esac
                    else
                        tag_info "od not available — skipping .deb magic check."
                    fi
                else
                    tag_info "Range-fetch not available — skipping .deb magic check."
                fi
            fi
        fi

        if command -v fastfetch >/dev/null 2>&1; then
            vline="$(fastfetch --version 2>/dev/null | awk 'NR==1{print $0; exit}' 2>/dev/null)"
            [ -n "$vline" ] && tag_ok "Local fastfetch reports: $vline" || warn "fastfetch present but version query failed."
        else
            tag_info "fastfetch not in PATH (version checks skipped)."
        fi

        if command -v dpkg-query >/dev/null 2>&1; then
            if dpkg-query -W -f='${Status} ${Version}\n' fastfetch 2>/dev/null | grep -q '^install ok installed'; then
                inst_ver="$(dpkg-query -W -f='${Version}\n' fastfetch 2>/dev/null | awk 'NR==1{print $1}' 2>/dev/null)"
                [ -n "$inst_ver" ] && tag_ok "Debian package fastfetch installed version: $inst_ver" || tag_info "fastfetch installed but version read failed."
            else
                tag_info "dpkg-query: fastfetch not installed as a Debian package (or not installed)."
            fi
        fi
    else
        fail "GitHub API JSON is empty or missing after download."
    fi
fi

# ----------------------------- Block 4: Summary --------------------------------

NUMBERING_CURRENT=$((NUMBERING_CURRENT + 1))
hr
say "BLOCK $NUMBERING_CURRENT/$NUMBERING: SUMMARY"
hr

tag_info "Step 6: Summary"

say "Selected groups:"
if [ "$want_rust" -eq 1 ]; then say "  - Rust:      YES"; else say "  - Rust:      NO"; fi
if [ "$want_fastfetch" -eq 1 ]; then say "  - Fastfetch: YES"; else say "  - Fastfetch: NO"; fi

say "Counters:"
say "  Warnings: $WARNINGS"
say "  Failures: $FAILURES"

if [ "$FAILURES" -eq 0 ]; then
    tag_ok "Overall result: PASS"
    exit 0
fi

tag_fail "Overall result: FAIL (one or more checks indicate updater breakage risk)."
exit 4
