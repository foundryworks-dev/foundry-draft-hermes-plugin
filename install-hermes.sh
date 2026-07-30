#!/bin/sh
# Foundry/Draft Hermes plugin installer (#524).
#
#   export FOUNDRY_API_KEY=fdrk_...
#   curl -fsSL https://dl.foundryworks.dev/install-hermes.sh | sh
#
# Hermes has no plugin marketplace, so this is the Hermes equivalent of
# "/plugin install": it fetches a versioned, SHA-256-verified tarball from
# dl.foundryworks.dev, drops it somewhere stable, and wires ~/.hermes.
#
# What it does:
#   1. check prereqs (node 18+)
#   2. resolve the version (latest, or FOUNDRY_HERMES_VERSION to pin)
#   3. download + verify the tarball against SHA256SUMS
#   4. extract to ~/.foundry/hermes-draft-plugin/<version> + a `current` symlink
#   5. run the bundled scripts/install.sh from `current`, which copies the
#      skills and wires mcp_servers.foundry / mcp_servers.draft
#
# Step 5 is a delegation, not a reimplementation, and that is deliberate.
# The config wiring is the subtle part — YAML has no repeated-key merge, so
# it appends a block only when there is none and otherwise prints entries to
# paste, and it must not clobber a hand-tuned server. That logic already
# exists, ships inside the tarball, and is what a clone install runs. A second
# copy here would be a second thing to keep correct, and the two would drift
# the first time either changed — which is the failure this plugin family has
# hit repeatedly (#517, #519, #522, #523).
#
# Running it from `current` rather than the versioned directory is what makes
# upgrades free: the config points at the symlink, so the next release moves
# the symlink and nothing in ~/.hermes/config.yaml has to change.
#
# Re-running upgrades in place. Uninstall with:
#   curl -fsSL https://dl.foundryworks.dev/install-hermes.sh | sh -s -- --uninstall
#
# Environment overrides:
#   FOUNDRY_HERMES_VERSION       version to install (default: latest). "v0.1.0" or "0.1.0".
#   FOUNDRY_HERMES_INSTALL_DIR   install root (default: $HOME/.foundry/hermes-draft-plugin).
#   FOUNDRY_DOWNLOAD_BASE        base URL for downloads (default: https://dl.foundryworks.dev).
#   HERMES_HOME                  Hermes config dir (default: $HOME/.hermes).
#
# Export FOUNDRY_API_KEY *before* running: Hermes does not forward your shell
# environment to stdio MCP servers, so the key has to be written into the
# config's env: block at install time. Without it you get a placeholder to
# fill in by hand.

set -eu

PLUGIN="foundry-draft-hermes-plugin"
VERSION="${FOUNDRY_HERMES_VERSION:-latest}"
INSTALL_ROOT="${FOUNDRY_HERMES_INSTALL_DIR:-$HOME/.foundry/hermes-draft-plugin}"
DOWNLOAD_BASE="${FOUNDRY_DOWNLOAD_BASE:-https://dl.foundryworks.dev}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# The skills the plugin ships. Named explicitly rather than globbed because
# uninstall must remove exactly what was installed and nothing a user added
# themselves — ~/.hermes/skills is a shared directory.
SKILLS="foundry-agents foundry-queue foundry-refresh foundry-watch foundry-work"
# Pre-#476 names. Installs only ever copied, so nothing has removed these for
# anyone who installed before the rename — uninstall clears both generations
# for the same reason install-codex.sh now does (#523).
LEGACY_SKILLS="draft-agents draft-queue draft-refresh draft-watch draft-work"

info() { printf '  %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- tooling ----------------------------------------------------------------

download() { # download <url> <dest>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        err "need curl or wget to download release assets"
    fi
}

fetch_text() { # fetch_text <url> -> body on stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO - "$1"
    else
        err "need curl or wget to fetch $1"
    fi
}

sha256_of() { # sha256_of <file> -> hex digest on stdout
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        err "need sha256sum or shasum to verify the download"
    fi
}

# ---- prereqs ----------------------------------------------------------------

check_prereqs() {
    command -v node >/dev/null 2>&1 \
        || err "node is required (the MCP server runs 'node mcp/draft-mcp.js'). Install Node 18+ and re-run."
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    [ "$major" -ge 18 ] \
        || err "Node $(node -v 2>/dev/null) is too old — the MCP server needs Node 18+ (global fetch)."
    # The bundled wiring script is bash; the tarball's own scripts/install.sh
    # declares #!/usr/bin/env bash and uses `set -o pipefail`.
    command -v bash >/dev/null 2>&1 \
        || err "bash is required to run the bundled wiring step (scripts/install.sh)."
}

# ---- uninstall --------------------------------------------------------------

uninstall() {
    info "uninstalling $PLUGIN"

    for s in $SKILLS $LEGACY_SKILLS; do
        rm -rf "$HERMES_HOME/skills/$s"
    done
    rm -f "$HERMES_HOME/scripts/foundry-registry.js"
    rm -rf "$INSTALL_ROOT"
    info "removed skills, broker client, and $INSTALL_ROOT"

    # The config is left alone, deliberately, and this is the same reason the
    # install side won't edit an existing mcp_servers: block: stripping YAML
    # entries safely means parsing YAML, and a wrong guess corrupts a file
    # that may hold other servers. Telling the user exactly what to delete is
    # honest; silently mangling their config is not.
    if [ -f "$HERMES_HOME/config.yaml" ]; then
        printf '\n'
        info "One manual step: remove the plugin's MCP servers from"
        info "$HERMES_HOME/config.yaml — the 'foundry:' and 'draft:' entries"
        info "under mcp_servers:. They are left in place because editing YAML"
        info "safely means parsing it, and your config may hold other servers."
    fi
    printf '\n'
    info "Done. Restart Hermes."
    exit 0
}

# ---- version resolution -----------------------------------------------------

resolve_version() {
    if [ "$VERSION" != "latest" ]; then
        case "$VERSION" in
            v*) printf '%s' "$VERSION" ;;
            *) printf 'v%s' "$VERSION" ;;
        esac
        return
    fi
    # The release workflow writes the newest tag to hermes-plugin/latest.txt.
    v="$(fetch_text "$DOWNLOAD_BASE/hermes-plugin/latest.txt" 2>/dev/null | tr -d ' \t\r\n')"
    [ -n "$v" ] || err "could not determine the latest version from $DOWNLOAD_BASE/hermes-plugin/latest.txt (no release published yet?)"
    printf '%s' "$v"
}

# ---- main -------------------------------------------------------------------

main() {
    if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
        uninstall
    fi

    info "Foundry/Draft Hermes plugin installer"
    check_prereqs

    version="$(resolve_version)"
    tarball="${PLUGIN}.tar.gz"
    base="${DOWNLOAD_BASE}/hermes-plugin/${version}"
    dest="${INSTALL_ROOT}/${version}"

    info "version: $version"

    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT INT TERM

    info "downloading $tarball ..."
    download "$base/$tarball" "$workdir/$tarball" \
        || err "download failed: $base/$tarball (no release for $version?)"
    download "$base/SHA256SUMS" "$workdir/SHA256SUMS" \
        || err "download failed: $base/SHA256SUMS"

    info "verifying checksum ..."
    expected="$(grep " ${tarball}\$" "$workdir/SHA256SUMS" | awk '{print $1}' | head -n1)"
    [ -n "$expected" ] || err "no checksum for $tarball in SHA256SUMS"
    actual="$(sha256_of "$workdir/$tarball")"
    [ "$expected" = "$actual" ] || err "checksum mismatch for $tarball (expected $expected, got $actual)"

    info "installing to $dest ..."
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xzf "$workdir/$tarball" -C "$dest"
    [ -f "$dest/mcp/draft-mcp.js" ] || err "release tarball did not contain mcp/draft-mcp.js"
    [ -f "$dest/scripts/install.sh" ] || err "release tarball did not contain scripts/install.sh"

    # Stable `current` symlink so config.yaml never has to change on upgrade.
    ln -sfn "$dest" "${INSTALL_ROOT}/current"

    # Delegate the skills + config wiring to the bundled script, run from
    # `current` so the MCP path it writes is the stable one. It derives its
    # own root from its location, so this is all it needs.
    info "wiring $HERMES_HOME ..."
    printf '\n'
    HERMES_HOME="$HERMES_HOME" bash "${INSTALL_ROOT}/current/scripts/install.sh"

    printf '\n'
    info "Installed $version. Re-run this script to upgrade."
    info "Uninstall:  curl -fsSL ${DOWNLOAD_BASE}/install-hermes.sh | sh -s -- --uninstall"
}

main "$@"
