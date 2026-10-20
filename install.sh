#!/bin/sh
# toft — the Toft command-line client.
#
#   curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh
#
# Downloads one binary for this machine, checks it against the published
# SHA256SUMS, and puts it somewhere on PATH. Nothing else — no daemon, no
# configuration, no root.
#
# Linux and macOS. Windows does not run this and is refused by name, with
# somewhere to go.
#
# THE WHOLE BODY IS INSIDE main(), CALLED ON THE LAST LINE, for the same reason
# the one-box installer is written that way: piping into a shell executes what
# has arrived so far, and a truncated download of this script must do nothing at
# all rather than half of something.
#
# POSIX sh on purpose. This runs on machines nobody has prepared, where /bin/sh
# is as likely to be dash as bash.
#
# It never uses sudo. A one-line install that escalates is a worse trade than an
# install that lands in ~/.local/bin and says so.

set -eu

# --- What this installs ------------------------------------------------------
#
# VERSION_DEFAULT is stamped by scripts/publish-cli.sh in the same act that
# uploads the release, so the default is always the version whose SHA256SUMS
# sits beside it. Typing a version here by hand is how those two come apart.

VERSION_DEFAULT=0.9.1
REPO_DEFAULT=larchway-labs/toft-cli
BINARY=toft

VERSION=$VERSION_DEFAULT
REPO=$REPO_DEFAULT
DIR=
QUIET=0

usage() {
    cat <<'EOF'
toft — the Toft command-line client.

  curl -fsSL https://raw.githubusercontent.com/larchway-labs/toft-cli/main/install.sh | sh

Options:
  --dir DIR         install into DIR instead of the default. The default is
                    /usr/local/bin when this user can write to it, and
                    ~/.local/bin otherwise. sudo is never used.
  --version X.Y.Z   install that release instead of the one this script was
                    published with. `latest` follows the newest release.
  -q, --quiet       print the installed path and nothing else
  -h, --help        this

Uninstalling is deleting the file; it is the whole install.
EOF
    exit "${1:-0}"
}

# --- Output ------------------------------------------------------------------

ui_init() {
    C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_RESET=''
    if [ -t 2 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != dumb ]; then
        C_BOLD=$(printf '\033[1m') C_DIM=$(printf '\033[2m')
        C_RED=$(printf '\033[31m') C_GREEN=$(printf '\033[32m')
        C_RESET=$(printf '\033[0m')
    fi
}

say() { [ "$QUIET" = 1 ] || printf '  %s\n' "$*" >&2; }
ok() { [ "$QUIET" = 1 ] || printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
note() { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

die() {
    printf '\n  %serror%s %s\n\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- Options -----------------------------------------------------------------

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
        --dir)
            shift
            DIR=${1:-}
            [ -n "$DIR" ] || die "--dir needs a directory"
            ;;
        --version)
            shift
            VERSION=${1:-}
            [ -n "$VERSION" ] || die "--version needs a version"
            ;;
        --repo)
            shift
            REPO=${1:-}
            ;;
        -q | --quiet) QUIET=1 ;;
        -h | --help) usage 0 ;;
        *)
            printf '  unknown option %s\n\n' "$1" >&2
            usage 1
            ;;
        esac
        shift
    done
}

# --- This machine ------------------------------------------------------------
#
# The asset names are the Go pair, toft_<goos>_<goarch>, because that is what the
# build matrix produces and a translation table between two spellings of the
# same platforms is a thing to get wrong twice.
#
# Windows is refused by name rather than left to 404, and names the asset to
# fetch instead. macOS installs here like Linux: the darwin binaries are
# unsigned, and Gatekeeper quarantines what a *browser* downloads rather than
# what curl does, so this path works while a hand-download from the releases
# page will need clearing.

detect_platform() {
    case $(uname -s) in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
        die "this script is for Linux and macOS. On Windows, download toft_windows_amd64.exe from https://github.com/$REPO/releases and rename it toft.exe"
        ;;
    *) die "unsupported operating system: $(uname -s)" ;;
    esac

    case $(uname -m) in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m). Built for x86_64 and arm64" ;;
    esac

    ASSET="${BINARY}_${OS}_${ARCH}"
}

# --- Where it goes -----------------------------------------------------------
#
# Two candidates, and the rule is "can this user write there", never sudo.
# /usr/local/bin first because it is on PATH on every machine that has it;
# ~/.local/bin second because it always works and needs nobody's permission.

resolve_dir() {
    if [ -n "$DIR" ]; then
        mkdir -p "$DIR" 2>/dev/null || die "cannot create $DIR"
        [ -w "$DIR" ] || die "$DIR is not writable by $(id -un)"
        return
    fi
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        DIR=/usr/local/bin
        return
    fi
    DIR=$HOME/.local/bin
    mkdir -p "$DIR" || die "cannot create $DIR"
}

on_path() {
    case ":${PATH:-}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
    esac
}

# --- Download ----------------------------------------------------------------

fetch() {
    # $1 url, $2 destination
    if have curl; then
        curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2"
    elif have wget; then
        wget -qO "$2" "$1"
    else
        die "neither curl nor wget is installed, so nothing can be downloaded"
    fi
}

# GitHub serves /releases/latest/download/<asset> as a redirect to the newest
# release, and /releases/download/v<version>/<asset> for a named one. Both are
# anonymous on a public repository, which is the whole reason the binaries live
# in a repository of their own.
release_base() {
    if [ "$VERSION" = latest ]; then
        printf 'https://github.com/%s/releases/latest/download' "$REPO"
    else
        printf 'https://github.com/%s/releases/download/v%s' "$REPO" "$VERSION"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | cut -d' ' -f1
    elif have shasum; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif have openssl; then
        openssl dgst -sha256 "$1" | sed 's/.*= //'
    else
        return 1
    fi
}

# The checksum is not there to defend against GitHub. It is there because a
# proxy, a captive portal or a truncated transfer produces a file that is the
# right length often enough, and "toft: cannot execute binary file" is a terrible
# way to learn that.
verify() {
    # $1 the downloaded binary, $2 the SHA256SUMS file
    want=$(grep "  $ASSET\$" "$2" 2>/dev/null | cut -d' ' -f1) || true
    [ -n "${want:-}" ] || die "SHA256SUMS for $VERSION does not name $ASSET"

    got=$(sha256_of "$1") || {
        note "no sha256sum, shasum or openssl on this machine — skipping verification"
        return 0
    }
    [ "$got" = "$want" ] || die "checksum mismatch for $ASSET: got $got, expected $want"
    ok "checksum verified"
}

install_binary() {
    base=$(release_base)

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t toft) || die "cannot create a temporary directory"
    trap 'rm -rf "$tmp"' EXIT INT TERM

    say "downloading $ASSET"
    fetch "$base/$ASSET" "$tmp/$BINARY" ||
        die "could not download $base/$ASSET — check the version exists at https://github.com/$REPO/releases"

    if fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null; then
        verify "$tmp/$BINARY" "$tmp/SHA256SUMS"
    else
        note "no SHA256SUMS published for this release — skipping verification"
    fi

    chmod 0755 "$tmp/$BINARY"

    # Replacing a running binary in place fails on some systems and succeeds
    # confusingly on others; a rename over the old inode is atomic and leaves
    # any process still holding the old one alone.
    mv -f "$tmp/$BINARY" "$DIR/$BINARY" 2>/dev/null ||
        die "could not write $DIR/$BINARY"
}

# --- What to do next ---------------------------------------------------------

summary() {
    if [ "$QUIET" = 1 ]; then
        printf '%s\n' "$DIR/$BINARY"
        return
    fi

    installed=$("$DIR/$BINARY" --version 2>/dev/null || echo "$BINARY $VERSION")
    printf '\n'
    ok "$installed → $DIR/$BINARY"

    if ! on_path "$DIR"; then
        printf '\n  %s%s is not on your PATH.%s Add it:\n\n' "$C_BOLD" "$DIR" "$C_RESET"
        printf '      export PATH="%s:$PATH"\n' "$DIR"
        printf '\n  %s(put that in ~/.zshrc or ~/.bashrc to keep it)%s\n' "$C_DIM" "$C_RESET"
    fi

    cat >&2 <<EOF

  Point it at your install and sign in:

      ${C_BOLD}toft login https://toft.your-company.com${C_RESET}

  then, from a project directory:

      ${C_BOLD}toft link <app>${C_RESET}      ${C_DIM}name the app this directory deploys to${C_RESET}
      ${C_BOLD}toft deploy${C_RESET}          ${C_DIM}push what is on your disk${C_RESET}

EOF
}

main() {
    parse_args "$@"
    ui_init
    detect_platform
    resolve_dir
    install_binary
    summary
}

main "$@"
