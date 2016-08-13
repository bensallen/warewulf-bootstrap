#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

MUSL_VERS=1.1.15
BUSYBOX_VERS=1.25.0
OPENRC_VERS=0.21.2

BASE=$(dirname $(readlink -f $0))
mkdir -p $BASE/initramfs
mkdir -p $BASE/initramfs/3rd_party/MIT
mkdir -p $BASE/initramfs/3rd_party/GPL

INSTALLROOT="${BASE}/initramfs/_install"
rm -rf "${INSTALLROOT}"
mkdir -p "${INSTALLROOT}"
BUILDROOT="${BASE}/initramfs/_build"
rm -rf "${BUILDROOT}"
mkdir -p "${BUILDROOT}"
SRCROOT="${BASE}/initramfs/_src"
rm -rf "${SRCROOT}"
mkdir -p "${SRCROOT}"

KHDR_BASE=/usr

### MUSL-C ###
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
make -j2

make DESTDIR="${INSTALLROOT}" install
echo -e 'print-ldso:\n\t@echo $$(basename $(LDSO_PATHNAME))' >> Makefile
LDSO=$(make -f Makefile print-ldso)
mv -f "${INSTALLROOT}/usr/lib/libc.so" "${INSTALLROOT}/lib/${LDSO}"
ln -sf "../../lib/${LDSO}" "${INSTALLROOT}/usr/lib/libc.so"
mkdir -p "${INSTALLROOT}/usr/bin"
ln -sf "../../lib/${LDSO}" "${INSTALLROOT}/usr/bin/ldd"

mkdir -p "${BUILDROOT}/bin" "${BUILDROOT}/etc"

sh "${SRCROOT}/musl-${MUSL_VERS}/tools/musl-gcc.specs.sh" "${BUILDROOT}/include" "${INSTALLROOT}/usr/lib" "/lib/${LDSO}" > "${BUILDROOT}/etc/musl-gcc.specs"

cat <<EOF > "${BUILDROOT}/bin/musl-gcc"
#!/bin/sh
exec "\${REALGCC:-gcc}" "\$@" -specs "${BUILDROOT}/etc/musl-gcc.specs"
EOF

chmod +x "${BUILDROOT}/bin/musl-gcc"

PATH="${BUILDROOT}/bin":$PATH

cd "${BUILDROOT}/bin"

# TODO: Using binutils from the build host for now
ln -s `which ar` musl-ar
ln -s `which strip` musl-strip

# TODO: Using linux-headers from the buildhost for now
mkdir -p "${BUILDROOT}/include"
cd "${BUILDROOT}/include"
ln -s "${KHDR_BASE}/include/linux" linux
ln -s "${KHDR_BASE}/include/mtd" mtd
if [ -d "${KHDR_BASE}/include/asm" ]
then
  ln -s "${KHDR_BASE}/include/asm" asm
else
    ln -s "${KHDR_BASE}/include/asm-generic" asm
fi
ln -s "${KHDR_BASE}/include/asm-generic" asm-generic

### Busybox (static) ###
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

make V=1 -j2
make install

(cd ${INSTALLROOT} && ln -s bin/busybox init)

### OpenRC ###
mkdir -p "${BASE}/initramfs/3rd_party/MIT/openrc"
cd "${BASE}/initramfs/3rd_party/MIT/openrc"
if [ ! -e "${BASE}/initramfs/3rd_party/MIT/openrc/openrc-${OPENRC_VERS}.tar.gz" ]; then
    curl -L -o openrc-${OPENRC_VERS}.tar.gz https://github.com/OpenRC/openrc/archive/${OPENRC_VERS}.tar.gz
fi

tar -C "${SRCROOT}" -xf openrc-${OPENRC_VERS}.tar.gz
cd "${SRCROOT}/openrc-${OPENRC_VERS}"

for i in ${BASE}/initramfs/3rd_party/MIT/openrc/patches/*.patch; do
    patch -p1 -i $i || return 1
done
sed -i -e '/^sed/d' pkgconfig/Makefile

make install \
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
mkdir -p ${INSTALLROOT}/proc ${INSTALLROOT}/run ${INSTALLROOT}/dev ${INSTALLROOT}/tmp ${INSTALLROOT}/lib/modules
touch ${INSTALLROOT}/etc/fstab ${INSTALLROOT}/etc/sysctl.conf

# Cleanup
find ${INSTALLROOT}/usr/lib -name "*.a" -delete

# Create root user
echo 'root:x:0:0:root:/:/bin/sh' > ${INSTALLROOT}/etc/passwd
echo 'root::16793:0:99999:7:::' > ${INSTALLROOT}/etc/shadow
echo 'root:x:0:' > ${INSTALLROOT}/etc/group

# Create CPIO initramfs of installroot
(cd $INSTALLROOT; find . | bsdcpio -R 0:0 -o -z --format newc > $BASE/initramfs.gz)
