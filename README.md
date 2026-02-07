# rust-stable-install

A **safe, deterministic, rustup-free installer** for **Rust Stable** on Linux.

This script installs Rust using the **official standalone installer tarballs** published by the Rust project. It is designed for **servers, SBCs, CI systems, and power users** who want a transparent, auditable, and reproducible installation without `rustup`.

## Key properties

- **No rustup** — downloads official standalone installers only
- **Deterministic** — always installs the latest *stable* release for your platform
- **Verified** — SHA-256 checked against Rust’s published channel manifest
- **Prefix-based** — install anywhere, no system pollution
- **Safe by default** — uses `trash`, never `rm`, unless explicitly requested
- **Automation-friendly** — non-interactive mode and self-test support

---

## Non-goals (by design)

This script intentionally does **not**:

- manage multiple Rust toolchains
- install nightly or beta releases
- replace `rustup` for desktop workflows
- support non-Linux platforms

If you need those, `rustup` is the correct tool.

## Who this is for

- Linux **servers** and **SBCs** (including ARM)
- CI runners and reproducible build systems
- Minimal systems without Python or package managers
- Users who want full control over where Rust is installed
- Anyone who dislikes `curl | sh` installers

## What the script does (high level)

1. Validates required tools are installed
2. Detects OS and CPU architecture
3. Ensures working and install directories are usable
4. Reads existing `version.txt` (if present)
5. Fetches Rust’s **stable channel manifest**
6. Extracts:
   - latest stable version
   - target installer URL
   - expected SHA-256 hash
7. Removes working directory contents (safe backend)
8. Downloads the installer archive
9. Verifies SHA-256 integrity
10. Extracts the installer
11. Removes existing install prefix (safe backend)
12. Runs `install.sh --prefix=…`
13. Writes `version.txt` on success
14. Performs backend-specific cleanup

---

## Requirements

### Operating system

- **Linux only** (hard-enforced)

### Supported architectures

| uname -m | Rust target triple            |
| -------- | ----------------------------- |
| x86_64   | x86_64-unknown-linux-gnu      |
| aarch64  | aarch64-unknown-linux-gnu     |
| i686     | i686-unknown-linux-gnu        |
| armv7l   | armv7-unknown-linux-gnueabihf |

If Rust does not publish a standalone installer for your platform, the script exits with a clear error.

### Required tools

Always required:

- `bash`, `uname`, `mkdir`, `cat`, `printf`
- `grep`, `sed`, `awk`, `head`, `cut`
- `tar` (with `-J` support) or `xz`
- `sha256sum`
- One downloader: **`wget2`** (preferred), `curl`, or `wget`
- `sudo` (used **only** for the final installer step)

Deletion backend:

- Default: `trash`, `trash-empty` (from **trash-cli**)
- Optional: `rm` (only when `--rm` is specified)

---

## Installation

Save the script and make it executable:

```bash
chmod +x rust-stable-install
```

## Configuration

### WORKDIR

Temporary working directory for downloads, extraction, and `version.txt`.

Default:

```bash
${XDG_CACHE_HOME:-$HOME/.cache}/rust-stable-installer
```

Override example:

```bash
WORKDIR=/opt/rust-installer-cache ./rust-stable-install
```

### INSTALL_PREFIX

Installation target directory for Rust.

Default:

```bash
$HOME/rust-stable
```

Override example:

```bash
INSTALL_PREFIX=$HOME/.local/rust-stable ./rust-stable-install
```

Both may be overridden together:

```bash
WORKDIR=/tmp/rust-installer INSTALL_PREFIX=$HOME/.local/rust-stable ./rust-stable-install
```

## Usage

### Interactive

```bash
./rust-stable-install
```

### Non-interactive (assume yes)

```bash
./rust-stable-install --yes
```

### Self-test (no downloads or installs)

```bash
./rust-stable-install --self-test
```

### Disable colors

```bash
./rust-stable-install --no-color
# or
NO_COLOR=1 ./rust-stable-install
```

### Deletion backend selection

Safe default (recoverable):

```bash
./rust-stable-install
```

Force permanent deletion:

```bash
./rust-stable-install --rm
```

Force trash explicitly:

```bash
./rust-stable-install --trash
```

The script always prints whether it is **trashing** or **deleting** files.

## Safety and scope

The script **only modifies**:

- `$WORKDIR/*`
- `$INSTALL_PREFIX`

By default, all removals go through **`trash`**.
Permanent deletion occurs **only** if `--rm` is specified.

`sudo` is used **only** for:

```bash
sudo ./install.sh --prefix="$INSTALL_PREFIX"
```

## Failure behavior

- Missing tools → immediate, descriptive error
- Unsupported architecture → immediate exit
- Manifest parse failure → immediate exit
- SHA-256 mismatch → aborts without extracting

No partial installs are left behind on failure

## License

MIT