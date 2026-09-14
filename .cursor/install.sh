#!/usr/bin/env bash
# Cloud Agent install script for dayglass.
#
# dayglass is a macOS Swift 6 package, but Cloud Agents run Linux. The base
# image ships no Swift toolchain, so this script provisions Swift 6.0 on Linux,
# then resolves dependencies and warms the build cache for the portable
# DayglassCore module (the macOS-only `dayglass` executable target is gated out
# on non-macOS hosts in Package.swift).
#
# Runs after checkout and may run again to refresh state, so it is idempotent.
set -euo pipefail

SWIFT_RELEASE="swift-6.0.3-RELEASE"
SWIFT_PREFIX="/opt/swift"

if [ ! -x "${SWIFT_PREFIX}/usr/bin/swift" ]; then
  echo "Installing Swift ${SWIFT_RELEASE} toolchain..."

  ubuntu_version="$(. /etc/os-release && echo "${VERSION_ID}")"    # e.g. 24.04
  ubuntu_path="ubuntu$(echo "${ubuntu_version}" | tr -d '.')"       # URL path: ubuntu2404
  ubuntu_file="ubuntu${ubuntu_version}"                             # file name: ubuntu24.04
  release_dir="$(echo "${SWIFT_RELEASE}" | tr '[:upper:]' '[:lower:]')"
  tarball="${SWIFT_RELEASE}-${ubuntu_file}.tar.gz"
  url="https://download.swift.org/${release_dir}/${ubuntu_path}/${SWIFT_RELEASE}/${tarball}"

  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-12-dev \
    libpython3-dev libstdc++-12-dev libxml2-dev libz3-dev pkg-config tzdata \
    zlib1g-dev curl ca-certificates libncurses-dev

  tmp="$(mktemp -d)"
  echo "Downloading ${url}"
  curl -fSL --retry 4 -o "${tmp}/swift.tar.gz" "${url}"
  sudo mkdir -p "${SWIFT_PREFIX}"
  sudo tar xzf "${tmp}/swift.tar.gz" -C "${SWIFT_PREFIX}" --strip-components=1
  rm -rf "${tmp}"
else
  echo "Swift toolchain already present at ${SWIFT_PREFIX}, skipping download."
fi

# Expose swift on PATH for login shells and via /usr/local/bin (default PATH).
echo 'export PATH="/opt/swift/usr/bin:$PATH"' | sudo tee /etc/profile.d/swift.sh >/dev/null
sudo ln -sf "${SWIFT_PREFIX}/usr/bin/swift" /usr/local/bin/swift
sudo ln -sf "${SWIFT_PREFIX}/usr/bin/swiftc" /usr/local/bin/swiftc

export PATH="${SWIFT_PREFIX}/usr/bin:${PATH}"
swift --version

# No external package dependencies; resolve is a fast no-op that validates the
# manifest, then warm the build cache for the portable core + its test target.
swift package resolve
swift build --build-tests

echo "dayglass install complete."
