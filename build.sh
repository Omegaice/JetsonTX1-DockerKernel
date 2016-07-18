#!/bin/bash
set -e
set -x

ROOT=$PWD
KERNEL_VERSION=3.10.67-g458d45c

# if the user is not root, there is not point in going forward
THISUSER=`whoami`
if [ "x$THISUSER" != "xroot" ]; then
    echo "This script requires root privilege"
    exit 1
fi

# Install Required Tools
apt-get install -y curl gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf git-core qemu-user-static

# Setup Cross Compile Variables
export CROSS_COMPILE=/usr/bin/aarch64-linux-gnu-
export CROSS_COMPILE=/usr/bin/aarch64-linux-gnu-
export CROSS32CC=/usr/bin/arm-linux-gnueabihf-gcc
export TEGRA_ROOT=$ROOT/Linux_for_Tegra
export TEGRA_KERNEL_OUT=$ROOT/build/kernel
export TEGRA_MODULE_OUT=$ROOT/build/modules
export ARCH=arm64

# Download Tegra driver scripts and root filesystem
if [ ! -f Scripts.tbz2 ]; then
    curl -o Scripts.tbz2 http://developer.download.nvidia.com/embedded/L4T/r23_Release_v2.0/Tegra210_Linux_R23.2.0_armhf.tbz2
fi

if [ ! -f Filesystem.tbz2 ]; then
    curl -o Filesystem.tbz2 http://developer.download.nvidia.com/embedded/L4T/r23_Release_v2.0/Tegra_Linux_Sample-Root-Filesystem_R23.2.0_armhf.tbz2
fi

# Destroy old versions
if [ -d $ROOT/build ]; then
    rm -rf $ROOT/build
fi 

if [ -d $TEGRA_ROOT ]; then
    rm -rf $TEGRA_ROOT
fi

# Extract
tar xjf Scripts.tbz2
cd $TEGRA_ROOT/rootfs
tar jxpf ../../Filesystem.tbz2 

# Checkout Kernel
mkdir -p $TEGRA_ROOT/sources
cd $TEGRA_ROOT/sources
git clone --depth 1 --branch tegra-l4t-r23.2 git://nv-tegra.nvidia.com/linux-3.10.git kernel
cd $TEGRA_ROOT/sources/kernel

# Patch Kernel
git apply < $ROOT/patch/vdso_arm_compile.patch
git apply < $ROOT/patch/remove_dirty_postfix.patch
git apply < $ROOT/patch/kernel_cgroup_uid.patch
git apply < $ROOT/patch/fs_proc_base_uid.patch
git apply < $ROOT/patch/drivers_misc_profiler_uid.patch
git apply < $ROOT/patch/include_net_route_uid.patch
git apply < $ROOT/patch/net_ipv4_route_uid.patch
git apply < $ROOT/patch/net_filter_xt_qtaguid_uid.patch
git apply < $ROOT/patch/net_filter_xt_quota2_uid.patch
git apply < $ROOT/patch/drivers_platform_tegra_clocks.patch

# Setup AUFS
git clone --depth 1 --branch aufs3.10.x git://git.code.sf.net/p/aufs/aufs3-standalone

cd $TEGRA_ROOT/sources/kernel/aufs3-standalone
rm include/uapi/linux/Kbuild
cp -rp *.patch fs include Documentation ../

cd $TEGRA_ROOT/sources/kernel
git apply < aufs3-kbuild.patch 
git apply < aufs3-base.patch 
git apply < aufs3-mmap.patch 
git apply < aufs3-standalone.patch

rm -rf aufs3-standalone *.patch

# Build Kernel
mkdir -p $TEGRA_KERNEL_OUT
cp $ROOT/config $TEGRA_KERNEL_OUT/.config
make O=$TEGRA_KERNEL_OUT zImage
make O=$TEGRA_KERNEL_OUT dtbs
make O=$TEGRA_KERNEL_OUT modules
make O=$TEGRA_KERNEL_OUT modules_install INSTALL_MOD_PATH=$TEGRA_MODULE_OUT

# Copy Kernel
cd $TEGRA_ROOT/kernel
cp $TEGRA_KERNEL_OUT/arch/arm64/boot/Image .
cp $TEGRA_KERNEL_OUT/arch/arm64/boot/zImage .

cd $TEGRA_ROOT/kernel/dtb
cp $TEGRA_KERNEL_OUT/arch/arm64/boot/dts/*.dtb .

# Copy Extra Modules
cd $TEGRA_ROOT/kernel
tar xvf kernel_supplements.tbz2
cp -r $TEGRA_ROOT/kernel/lib/modules/$KERNEL_VERSION/extra $TEGRA_MODULE_OUT/lib/modules/$KERNEL_VERSION/
rm -rf $TEGRA_ROOT/kernel/lib kernel_suppliments.tbz2

# Compress Resulting Modules
cd $TEGRA_MODULE_OUT
tar cjf kernel_supplements.tbz2 lib
mv kernel_supplements.tbz2 $TEGRA_ROOT/kernel

# Apply Binaries
cd $TEGRA_ROOT
./apply_binaries.sh

# Prepare for chroot
mv $TEGRA_ROOT/rootfs/etc/resolv.conf $TEGRA_ROOT/rootfs/etc/resolv.conf.orig
cp /etc/resolv.conf $TEGRA_ROOT/rootfs/etc/resolv.conf
cp $(which qemu-arm-static) $TEGRA_ROOT/rootfs/usr/bin/qemu-arm-static

chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'mv /sbin/initctl /sbin/initctl.bak && ln -s /bin/true /sbin/initctl && apt-get update'

# Install Docker
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'touch /etc/init.d/cgroup-lite && apt-get install -y cgroup-lite'

curl -o $TEGRA_ROOT/rootfs/aufs-tools_3.2+20130722-1.1_armhf.deb http://launchpadlibrarian.net/170861768/aufs-tools_3.2+20130722-1.1_armhf.deb
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'dpkg -i /aufs-tools_3.2+20130722-1.1_armhf.deb'
rm $TEGRA_ROOT/rootfs/aufs-tools_3.2+20130722-1.1_armhf.deb

cp $ROOT/package/docker-hypriot_1.10.3-1_armhf.deb $TEGRA_ROOT/rootfs
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'dpkg -i /docker-hypriot_1.10.3-1_armhf.deb'
rm $TEGRA_ROOT/rootfs/docker-hypriot_1.10.3-1_armhf.deb


cp $ROOT/package/docker-compose_1.7.1-41_armhf.deb $TEGRA_ROOT/rootfs
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'dpkg -i /docker-compose_1.7.1-41_armhf.deb'
rm $TEGRA_ROOT/rootfs/docker-compose_1.7.1-41_armhf.deb 

# Fix Docker Settings
curl -o $TEGRA_ROOT/rootfs/etc/init/docker.conf https://raw.githubusercontent.com/docker/docker/v1.10.3/contrib/init/upstart/docker.conf
sed -i "s/overlay/aufs/g" $TEGRA_ROOT/rootfs/etc/default/docker

# Add user to docker group
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'usermod -aG docker ubuntu'

# Cleanup
chroot $TEGRA_ROOT/rootfs qemu-arm-static /bin/bash -c 'mv /sbin/initctl.bak /sbin/initctl'
mv $TEGRA_ROOT/rootfs/etc/resolv.conf.orig $TEGRA_ROOT/rootfs/etc/resolv.conf
rm $TEGRA_ROOT/rootfs/usr/bin/qemu-arm-static

# Flash Kernel
./flash.sh jetson-tx1 mmcblk0p1



