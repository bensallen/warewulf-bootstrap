#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

PKGS=(
    'musl'
    'busybox' 
    'openrc'
  )

NUM_CPU=$(nproc)
BASE=$(dirname $(readlink -f $0))

_PKGS="${BASE}/pkgs"

# Temp directory for creating the initramfs
INSTALLROOT="${BASE}/_install"
rm -rf "${INSTALLROOT}"
mkdir -p "${INSTALLROOT}"

# Temp directory for files needed only for the build process
BUILDROOT="${BASE}/_build"
rm -rf "${BUILDROOT}"
mkdir -p "${BUILDROOT}"

# Temp directory for source
SRCROOT="${BASE}/_src"
rm -rf "${SRCROOT}"
mkdir -p "${SRCROOT}"

PATH="${BUILDROOT}/bin":$PATH

error() {
  echo "ERROR: $1" >&2
  exit 1
}

fetch() {
  local source
  for source in ${SOURCE}; do
    local path
    IFS='/' read -r -a path <<< "${source}"
    local file="${path[-1]}"
    if [[ -e "${_PKGS}/${PKG}/src/${file}" ]]; then
        cp "${_PKGS}/${PKG}/src/${file}" "${SRCROOT}/${file}"
    elif [[ ! -e "${SRCROOT}/${file}" ]]; then
      if [[ "${path[0]}" == "http:" || "${path[0]}" == "https:" || "${path[0]}" == "ftp:" ]]; then
        (cd "${SRCROOT}" && curl -O "${source}" || error "${source} download failed")
      else
        error "${source} not found"
      fi
    fi
  done
}

checksha512() {
  local sum
  for sum in "${SHA512SUM}"; do
    (cd "${SRCROOT}" && echo "$sum" | sha512sum -c --quiet) || error "Checksum failed"
  done
}

for PKG in ${PKGS[@]}; do
  source "${_PKGS}/${PKG}/WWPKG"
  fetch
  checksha512
  prepare
  build
  install
  unset -f prepare build install
  unset -v SOURCE SHA512SUM
done

# systemd-nspawn needs os-release
echo 'NAME="Warewulf 4.0 Bootstrap"' > "${INSTALLROOT}/etc/os-release"

cat <<EOF > "${INSTALLROOT}/etc/inittab"
# /etc/inittab

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up a couple of getty's
console::respawn:/sbin/getty 38400 /dev/console

# Put a getty on the serial port
#ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
#ttyS1::respawn:/sbin/getty -L ttyS1 115200 vt100

# Stuff to do for the 3-finger salute
::ctrlaltdel:/sbin/reboot

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown
EOF

# Create empty directories
mkdir -p "${INSTALLROOT}"/{proc,run,dev,tmp}
touch "${INSTALLROOT}/etc/fstab" "${INSTALLROOT}/etc/sysctl.conf"

# Cleanup

## Remove static libaries
find "${INSTALLROOT}/usr/lib" -name "*.a" -delete

# For now disable keymap
rm -f "${INSTALLROOT}/etc/runlevels/boot/keymaps"

# Create root user
echo 'root:x:0:0:root:/:/bin/sh' > "${INSTALLROOT}/etc/passwd"
echo 'root::16793:0:99999:7:::' > "${INSTALLROOT}/etc/shadow"
echo 'root:x:0:' > "${INSTALLROOT}/etc/group"

# Create CPIO initramfs of installroot
(cd "$INSTALLROOT"; find . | cpio -R 0:0 -ov --format newc > "$BASE/initramfs")
