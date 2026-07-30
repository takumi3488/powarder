#!/bin/sh
# Install powarder from GitHub Releases.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/takumi3488/powarder/main/install.sh | sh
#
# Environment variables:
#   POWARDER_VERSION      Version to install, e.g. "v0.2.0" or "0.2.0".
#                         Defaults to the latest release.
#   POWARDER_INSTALL_DIR  Directory to install the binary into.
#                         Defaults to "${XDG_BIN_HOME:-$HOME/.local/bin}".
#
# This script is POSIX sh (dash-compatible, no bashisms).
#
# Testing note: setting POWARDER_INSTALL_SH_TEST=1 before sourcing this file
# (". install.sh") defines all functions below without invoking main, so a
# test harness can exercise detect_target/hash_file/verify_checksum offline.

set -eu

REPO="takumi3488/powarder"
BIN_NAME="powarder"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# OS / architecture detection.
#
# detect_target OS ARCH
#   Prints the release asset target name (e.g. "linux-x86_64") on stdout
#   and returns 0 on success.
#   On failure, prints a short reason code ("intel-mac" or "unknown") on
#   stdout instead and returns 1, so callers can produce a tailored error
#   message.
# ---------------------------------------------------------------------------

detect_target() {
  _dt_os=$1
  _dt_arch=$2

  case "$_dt_os" in
    Darwin)
      case "$_dt_arch" in
        arm64)
          printf '%s\n' "darwin-arm64"
          return 0
          ;;
        x86_64)
          printf '%s\n' "intel-mac"
          return 1
          ;;
        *)
          printf '%s\n' "unknown"
          return 1
          ;;
      esac
      ;;
    Linux)
      case "$_dt_arch" in
        arm64 | aarch64)
          printf '%s\n' "linux-arm64"
          return 0
          ;;
        x86_64 | amd64)
          printf '%s\n' "linux-x86_64"
          return 0
          ;;
        *)
          printf '%s\n' "unknown"
          return 1
          ;;
      esac
      ;;
    *)
      printf '%s\n' "unknown"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Download helper: curl (preferred) with a wget fallback.
# ---------------------------------------------------------------------------

download() {
  _dl_url=$1
  _dl_dest=$2

  if have curl; then
    curl -fsSL -o "$_dl_dest" "$_dl_url" || die "Failed to download ${_dl_url}"
  elif have wget; then
    wget -qO "$_dl_dest" "$_dl_url" || die "Failed to download ${_dl_url}"
  else
    die "Neither curl nor wget was found. Please install one of them and try again."
  fi
}

# ---------------------------------------------------------------------------
# Checksum verification.
# ---------------------------------------------------------------------------

# hash_file FILE
#   Prints the sha256 hex digest of FILE on stdout.
#   Returns 2 if neither sha256sum nor shasum is available.
hash_file() {
  _hf_file=$1

  if have sha256sum; then
    sha256sum "$_hf_file" | awk '{ print $1 }'
  elif have shasum; then
    shasum -a 256 "$_hf_file" | awk '{ print $1 }'
  else
    return 2
  fi
}

# verify_checksum FILE SUMS_FILE NAME
#   Looks up NAME in SUMS_FILE (a "sha256sum"-style checksum listing) and
#   compares it against the actual digest of FILE. Dies on mismatch or on a
#   missing entry. If no sha256 tool is available, prints a warning and
#   returns without verifying (never silently skips without saying so).
verify_checksum() {
  _vc_file=$1
  _vc_sums_file=$2
  _vc_name=$3

  if ! have sha256sum && ! have shasum; then
    warn "Neither sha256sum nor shasum is available; skipping checksum verification for ${_vc_name}."
    return 0
  fi

  _vc_expected=$(awk -v name="$_vc_name" '
    {
      fname = $2
      sub(/^\*/, "", fname)
      if (fname == name) print $1
    }
  ' "$_vc_sums_file" | head -n 1)

  if [ -z "$_vc_expected" ]; then
    die "Could not find a checksum entry for ${_vc_name} in SHA256SUMS."
  fi

  _vc_actual=$(hash_file "$_vc_file")

  if [ "$_vc_expected" != "$_vc_actual" ]; then
    die "Checksum verification failed for ${_vc_name}: expected ${_vc_expected}, got ${_vc_actual}."
  fi

  info "Checksum OK for ${_vc_name}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  os_name=$(uname -s)
  arch_name=$(uname -m)

  if target=$(detect_target "$os_name" "$arch_name"); then
    :
  else
    case "$target" in
      intel-mac)
        die "Intel Mac (darwin-x86_64) is not supported: powarder does not publish prebuilt binaries for it. You can build it yourself (see \"Building from source\" in the README), or open an issue at https://github.com/${REPO}/issues if you would like a prebuilt binary."
        ;;
      *)
        die "Unsupported platform: ${os_name}/${arch_name}. Please open an issue at https://github.com/${REPO}/issues."
        ;;
    esac
  fi

  info "Detected platform: ${target}"

  if ! have curl && ! have wget; then
    die "Neither curl nor wget was found. Please install one of them and try again."
  fi

  version=${POWARDER_VERSION:-}
  if [ -n "$version" ]; then
    case "$version" in
      v*) tag=$version ;;
      *) tag="v${version}" ;;
    esac
    base_url="https://github.com/${REPO}/releases/download/${tag}"
    info "Installing powarder ${tag}"
  else
    base_url="https://github.com/${REPO}/releases/latest/download"
    info "Installing the latest powarder release"
  fi

  install_dir=${POWARDER_INSTALL_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}

  archive_name="${BIN_NAME}-${target}.tar.gz"
  archive_url="${base_url}/${archive_name}"
  sums_url="${base_url}/SHA256SUMS"

  tmpdir=$(mktemp -d)
  tmp_bin=""
  cleanup() {
    # Preserve the real exit status: the last command run before this trap
    # fired might have succeeded, and we must not let an incidental false
    # test below (e.g. tmp_bin already empty) clobber that with its own
    # status when the shell exits.
    _cl_status=$?
    if [ -n "${tmpdir:-}" ]; then
      rm -rf "$tmpdir"
    fi
    if [ -n "${tmp_bin:-}" ] && [ -f "$tmp_bin" ]; then
      rm -f "$tmp_bin"
    fi
    exit "$_cl_status"
  }
  trap cleanup EXIT INT TERM HUP

  info "Downloading ${archive_url}"
  download "$archive_url" "${tmpdir}/${archive_name}"

  info "Downloading ${sums_url}"
  download "$sums_url" "${tmpdir}/SHA256SUMS"

  verify_checksum "${tmpdir}/${archive_name}" "${tmpdir}/SHA256SUMS" "$archive_name"

  info "Extracting archive"
  tar xzf "${tmpdir}/${archive_name}" -C "$tmpdir" "$BIN_NAME"

  extracted="${tmpdir}/${BIN_NAME}"
  [ -f "$extracted" ] || die "Archive did not contain the expected ${BIN_NAME} binary."
  chmod +x "$extracted"

  if [ ! -d "$install_dir" ]; then
    info "Creating install directory: ${install_dir}"
    if ! mkdir -p "$install_dir" 2>/dev/null; then
      die "Could not create install directory: ${install_dir}. Choose a writable directory via POWARDER_INSTALL_DIR=<dir>, or re-run with elevated privileges, e.g.: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo sh"
    fi
  fi

  if [ ! -w "$install_dir" ]; then
    die "No write permission for ${install_dir}. Choose a writable directory via POWARDER_INSTALL_DIR=<dir>, or re-run with elevated privileges, e.g.: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo sh"
  fi

  # Write to a temp file in the same directory, then rename atomically, so
  # that a running instance of powarder (e.g. self-updating) is never
  # overwritten in place.
  tmp_bin="${install_dir}/.${BIN_NAME}.tmp.$$"
  cp "$extracted" "$tmp_bin"
  chmod +x "$tmp_bin"
  mv -f "$tmp_bin" "${install_dir}/${BIN_NAME}"
  tmp_bin=""

  info "Installed ${install_dir}/${BIN_NAME}"
  "${install_dir}/${BIN_NAME}" --version

  case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
      warn "${install_dir} is not in your \$PATH. Add it to your shell profile, e.g.: export PATH=\"${install_dir}:\$PATH\""
      ;;
  esac
}

if [ "${POWARDER_INSTALL_SH_TEST:-0}" != "1" ]; then
  main "$@"
fi
