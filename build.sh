#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

MUSL_VERS=1.1.15
BUSYBOX_VERS=1.25.0
OPENRC_VERS=0.21.3

NUM_CPU=$(nproc)

BASE=$(dirname $(readlink -f $0))
mkdir -p "$BASE/initramfs"
mkdir -p "$BASE/initramfs/3rd_party/MIT"
mkdir -p "$BASE/initramfs/3rd_party/GPL"

# Temp directory for creating the initramfs
INSTALLROOT="${BASE}/initramfs/_install"
rm -rf "${INSTALLROOT}"
mkdir -p "${INSTALLROOT}"

# Temp directory for files needed only for the build process
BUILDROOT="${BASE}/initramfs/_build"
rm -rf "${BUILDROOT}"
mkdir -p "${BUILDROOT}"

# Temp directory for source
SRCROOT="${BASE}/initramfs/_src"
rm -rf "${SRCROOT}"
mkdir -p "${SRCROOT}"

# Where to find linux-headers
KERN_HDR=/usr/include

### Build MUSL-C ###

mkdir -p "${BASE}/initramfs/3rd_party/MIT/musl"
cd "${BASE}/initramfs/3rd_party/MIT/musl"

if [ ! -e "${BASE}/initramfs/3rd_party/MIT/musl/musl-${MUSL_VERS}.tar.gz" ]; then
    curl -O https://www.musl-libc.org/releases/musl-${MUSL_VERS}.tar.gz
fi

tar -C "${SRCROOT}" -xf musl-${MUSL_VERS}.tar.gz
cd "${SRCROOT}/musl-${MUSL_VERS}"
./configure \
    --disable-wrapper \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --syslibdir=/lib \
    --includedir="/../_build/include"

make -j${NUM_CPU}
make DESTDIR="${INSTALLROOT}" install

# Determine MUSL-LIBC's loader filename
echo -e 'print-ldso:\n\t@echo $$(basename $(LDSO_PATHNAME))' >> Makefile
LDSO=$(make -f Makefile print-ldso)

# Rename libc.so to $LDSO and symlink back
mv -f "${INSTALLROOT}/usr/lib/libc.so" "${INSTALLROOT}/lib/${LDSO}"
ln -sf "../../lib/${LDSO}" "${INSTALLROOT}/usr/lib/libc.so"
mkdir -p "${INSTALLROOT}/usr/bin"
ln -sf "../../lib/${LDSO}" "${INSTALLROOT}/usr/bin/ldd"

mkdir -p "${BUILDROOT}"/{bin,etc}

# Create musl-libc specs file for GCC
sh "${SRCROOT}/musl-${MUSL_VERS}/tools/musl-gcc.specs.sh" "${BUILDROOT}/include" "${INSTALLROOT}/usr/lib" "/lib/${LDSO}" > "${BUILDROOT}/etc/musl-gcc.specs"

# Create musl-libc wrapper for GCC
cat <<EOF > "${BUILDROOT}/bin/musl-gcc"
#!/bin/sh
exec "\${REALGCC:-gcc}" "\$@" -specs "${BUILDROOT}/etc/musl-gcc.specs"
EOF

chmod +x "${BUILDROOT}/bin/musl-gcc"

PATH="${BUILDROOT}/bin":$PATH

cd "${BUILDROOT}/bin"

# TODO: Using binutils from the build host for now
ln -s $(which ar) musl-ar
ln -s $(which strip) musl-strip

# TODO: Using linux-headers from the buildhost for now
mkdir -p "${BUILDROOT}/include"
cd "${BUILDROOT}/include"
ln -s "${KERN_HDR}/linux" linux
ln -s "${KERN_HDR}/mtd" mtd
if [ -d "${KERN_HDR}/asm" ]
then
  ln -s "${KERN_HDR}/asm" asm
else
    ln -s "${KERN_HDR}/asm-generic" asm
fi
ln -s "${KERN_HDR}/asm-generic" asm-generic

### Build Busybox (static) ###

mkdir -p "${BASE}/initramfs/3rd_party/GPL/busybox"
cd "${BASE}/initramfs/3rd_party/GPL/busybox"

if [ ! -e "${BASE}/initramfs/3rd_party/GPL/busybox/busybox-${BUSYBOX_VERS}.tar.bz2" ]; then
    curl -O https://www.busybox.net/downloads/busybox-${BUSYBOX_VERS}.tar.bz2
fi

tar -C "${SRCROOT}" -xf busybox-${BUSYBOX_VERS}.tar.bz2
cd "${SRCROOT}/busybox-${BUSYBOX_VERS}"
cp "${BASE}/busybox.config" .config
sed -i -e "s/CONFIG_EXTRA_COMPAT=y/CONFIG_EXTRA_COMPAT=n/" \
       -e "s/.*CONFIG_CROSS_COMPILER_PREFIX.*/CONFIG_CROSS_COMPILER_PREFIX=\"musl-\"/" \
       -e "s|.*CONFIG_PREFIX.*|CONFIG_PREFIX=\"${INSTALLROOT}\"|" \
       -e "s/.*CONFIG_PIE.*/\# CONFIG_PIE is not set/" \
       -e "s/.*CONFIG_INSTALL_APPLET_DONT.*/\# CONFIG_INSTALL_APPLET_DONT is not set/" \
       -e "s/.*CONFIG_STATIC.*/CONFIG_STATIC=y/" \
       -e "s/.*CONFIG_INSTALL_APPLET_SYMLINKS.*/CONFIG_INSTALL_APPLET_SYMLINKS=y/" \
       .config

make V=1 -j${NUM_CPU}
make install

(cd "${INSTALLROOT}" && ln -s bin/busybox init)

### Build OpenRC ###

mkdir -p "${BASE}/initramfs/3rd_party/MIT/openrc"
cd "${BASE}/initramfs/3rd_party/MIT/openrc"
if [ ! -e "${BASE}/initramfs/3rd_party/MIT/openrc/openrc-${OPENRC_VERS}.tar.gz" ]; then
    curl -L -o openrc-${OPENRC_VERS}.tar.gz https://github.com/OpenRC/openrc/archive/${OPENRC_VERS}.tar.gz
fi

tar -C "${SRCROOT}" -xf openrc-${OPENRC_VERS}.tar.gz
cd "${SRCROOT}/openrc-${OPENRC_VERS}"

for i in "${BASE}"/initramfs/3rd_party/MIT/openrc/patches/*.patch; do
    patch -p1 --input="${i}"
done

sed -i -e '/^sed/d' pkgconfig/Makefile

make -j${NUM_CPU} install \
    LIBNAME=lib \
    DESTDIR="${INSTALLROOT}" \
    MKNET=yes \
    MKPKGCONFIG=no \
    MKSTATICLIBS=no \
    MKTOOLS=yes \
    LOCAL_PREFIX=/usr/local \
    BRANDING=\"Warewulf/$(uname -s)\" \
    CC=musl-gcc 

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
(cd "$INSTALLROOT"; find . | cpio -R 0:0 -ov --format newc > "$BASE/initramfs/initramfs")
