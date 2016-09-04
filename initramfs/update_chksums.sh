#!/bin/bash

#set -o errexit
set -o nounset
set -o pipefail

BASE=$(dirname $(readlink -f $0))

_3RDPARTY="${BASE}/3rd_party"

PKGS=(
    'MIT/musl'
    'GPL/busybox'
    'MIT/openrc'
  )

for PKG in ${PKGS[@]}; do
  echo "Updating chksums for $PKG"
  cd "${_3RDPARTY}/${PKG}"
  find src patches -type f 2>/dev/null | xargs sha512sum > chksums
done
