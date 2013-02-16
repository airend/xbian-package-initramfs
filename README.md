```
cd /opt/
mkdir initramfs
cd initramfs

fakeroot
mkdir bin dev etc lib proc rootfs sbin sys
touch etc/mdev.conf
cp /bin/busybox bin/
ln -s busybox bin/sh

mkdir -p lib/arm-linux-gnueabihf
cp /lib/ld-linux-armhf.so.3 lib/
cp -a /lib/arm-linux-gnueabihf/{ld-*,libc-*,libgcc_s.so*,libc.so*,libdl*} lib/arm-linux-gnueabihf
cp -a /lib/arm-linux-gnueabihf/{libm-*,libm.so*,libpam.so*,libpam_misc*} lib/arm-linux-gnueabihf
ln -s lib/arm-linux-gnueabihf/libc.so.6 lib/libc.so.6
ln -sl lib/arm-linux-gnueabihf/libgcc_s.so.1 lib/libgcc_s.so.1

wget -O - https://raw.github.com/xbianonpi/xbian-initramfs/master/init > init
chmod a+x init

rm -r .git

find . | cpio -H newc -o > ../initramfs.cpio
cat ../initramfs.cpio | gzip > /boot/initramfs.gz
```
