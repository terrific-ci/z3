#!/bin/sh
# Install z3 on Linux or macOS: downloads the z3 binary of a GitHub release
# of terrific-ci/z3, checks it against SHA256SUMS and puts it in /usr/local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/terrific-ci/z3/main/install.sh | sh
#
# With --service (Linux) it also runs z3 as a systemd service: a z3 user, the
# data directory /var/lib/z3, the settings file /etc/z3/z3.env, enabled and started.
#
#   curl -fsSL https://raw.githubusercontent.com/terrific-ci/z3/main/install.sh | sh -s -- --service
#
# Options (after `sh -s --` when piped):
#   --service       also set up and start the z3 systemd service (Linux)
#   --version X     install version X (default: the latest release)
#   --dir DIR       install into DIR (default: /usr/local/bin)
#   -h, --help
#
# Z3_VERSION and Z3_INSTALL_DIR work too. Running it again upgrades.
set -eu

REPO=terrific-ci/z3
VERSION=${Z3_VERSION:-latest}
DIR=${Z3_INSTALL_DIR:-/usr/local/bin}
SERVICE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE=1 ;;
    --version) VERSION=${2:?--version needs a value}; shift ;;
    --dir) DIR=${2:?--dir needs a value}; shift ;;
    -h|--help) sed -n '2,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need curl
need tar

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die "unsupported system $(uname -s); use the Docker image terrificci/z3" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac

if [ "$VERSION" = latest ]; then
  VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$VERSION" ] || die "cannot find the latest release of $REPO"
fi
VERSION=${VERSION#v}

asset="z3-$VERSION-$os-$arch.tar.gz"
base="https://github.com/$REPO/releases/download/v$VERSION"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading z3 $VERSION for $os/$arch"
curl -fsSL -o "$tmp/$asset" "$base/$asset" || die "no $asset in release v$VERSION"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "no SHA256SUMS in release v$VERSION"
want=$(grep " $asset\$" "$tmp/SHA256SUMS" | cut -d' ' -f1)
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1); else got=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1); fi
[ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $asset"
tar -C "$tmp" -xzf "$tmp/$asset"

SUDO=""
if [ ! -w "$DIR" ] && [ "$(id -u)" != 0 ]; then need sudo; SUDO=sudo; fi
$SUDO mkdir -p "$DIR"
$SUDO install -m 0755 "$tmp/z3" "$DIR/z3"
say "Installed $DIR/z3 ($("$DIR/z3" --version 2>/dev/null || echo "z3 $VERSION"))"

[ -n "$SERVICE" ] || exit 0
[ "$os" = linux ] || die "--service sets up systemd, which is Linux only"
need systemctl
SUDO=""
[ "$(id -u)" = 0 ] || { need sudo; SUDO=sudo; }

id z3 >/dev/null 2>&1 || $SUDO useradd --system --home /var/lib/z3 --shell /usr/sbin/nologin z3
$SUDO mkdir -p /var/lib/z3 /etc/z3
$SUDO chown z3:z3 /var/lib/z3
if [ ! -f /etc/z3/z3.env ]; then
  secret=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  $SUDO tee /etc/z3/z3.env >/dev/null <<ENV
# z3 settings; see https://github.com/$REPO for every option.
Z3_DATA_DIR=/var/lib/z3
Z3_S3_ADDR=0.0.0.0:9000
Z3_ADMIN_ADDR=127.0.0.1:9001
Z3_PEER_ADDR=0.0.0.0:9002
Z3_ACCESS_KEY=admin
Z3_SECRET_KEY=$secret
ENV
  $SUDO chmod 0640 /etc/z3/z3.env
  $SUDO chown root:z3 /etc/z3/z3.env
  say "Wrote /etc/z3/z3.env with a random root secret key"
fi
$SUDO tee /etc/systemd/system/z3.service >/dev/null <<UNIT
[Unit]
Description=z3 S3-compatible object storage
After=network-online.target
Wants=network-online.target

[Service]
User=z3
Group=z3
EnvironmentFile=/etc/z3/z3.env
ExecStart=$DIR/z3
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now z3
say "z3 is running: S3 API on :9000, console on http://127.0.0.1:9001 (credentials in /etc/z3/z3.env)"
