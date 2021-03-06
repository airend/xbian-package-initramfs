# part of code, which is relevant to block devices ... to keep init readable

telnetrun() {
    [ -e /bin/bash ] && shl=/bin/bash || shl=/bin/sh
    echo "ENV=/.profile exec $shl" > /cmd.sh; chmod +x /cmd.sh
    busybox cttyhack busybox telnetd -f /howto.txt -F -l /cmd.sh & echo $! > /telnetd.pid
}

vncrun() {
    find /lib/modules -iname vchiq.ko | xargs -n 1 insmod
    modprobe -q uinput
    /usr/local/sbin/dispman_vncserver &
}

up() {
echo "$(date) at initramfs/init $1: $(cat /proc/uptime)" >> /run/uptime-init.log
}

mount_root_btrfs() {
    test -z "$1" && device="LABEL=xbian-root-btrfs" || device="$1"
    /bin/mount -t btrfs -o compress=lzo,rw,noatime,space_cache $device $CONFIG_newroot
}

update_resolv_helper() {
for f in `ls /run/net-*.conf | grep -v net-lo.conf`; do 
    . $f
    [ -z "$IPV4DNS0" ] || echo "nameserver $IPV4DNS0"
    [ -z "$IPV4DNS1" -o "$IPV4DNS1" = '0.0.0.0' ] || echo "nameserver $IPV4DNS1"
    [ -z "$DNSDOMAIN" ] || echo "domain $DNSDOMAIN"
    [ -z "$DOMAINSEARCH" ] && echo "search $DNSDOMAIN" || echo "search $DOMAINSEARCH" 
done
#echo ""
}

update_resolv() {
    printf "%s\n" "$(update_resolv_helper)" | uniq
}

update_interfaces() {
if [ "$1" = "rollback" ]; then
	test -e "${CONFIG_newroot}/etc/network/interfaces.initramfs.autoconfig" && mv "${CONFIG_newroot}/etc/network/interfaces.initramfs.autoconfig" "${CONFIG_newroot}/etc/network/interfaces"
	return
fi
#test "$CONFIG_cnet" = "dhcp" || return

test -e "${CONFIG_newroot}/etc/network/interfaces.initramfs.autoconfig" && return
for f in `ls /run/net-eth?.conf`; do
	f=${f%%.conf}; f=${f##/run/net-};
	if [ "$(cat ${CONFIG_newroot}/etc/network/interfaces | grep $f | grep inet | grep -c iface)" -eq '1' ]; then
		grep -v  "$(cat ${CONFIG_newroot}/etc/network/interfaces | grep $f | grep inet | grep  iface)" "${CONFIG_newroot}/etc/network/interfaces" > "${CONFIG_newroot}/etc/network/interfaces.new"
		if [ "$(cat ${CONFIG_newroot}/etc/network/interfaces | grep $f | grep -c auto)" -eq '0' ]; then
			printf "%s\n" "auto $f" >> "${CONFIG_newroot}/etc/network/interfaces.new"
		fi
		printf "%s\n" "iface $f inet manual" >> "${CONFIG_newroot}/etc/network/interfaces.new"
		test -e "${CONFIG_newroot}/etc/network/interfaces.initramfs.autoconfig" || mv "${CONFIG_newroot}/etc/network/interfaces" "${CONFIG_newroot}/etc/network/interfaces.initramfs.autoconfig"
		mv "${CONFIG_newroot}/etc/network/interfaces.new" "${CONFIG_newroot}/etc/network/interfaces"
	fi
done
}

cp_splash() {
copyto="$1"

cp -d -a --parents /usr/bin/splash "$copyto"/
mkdir -p /run/initramfs/usr/share/fonts/splash
mkdir -p /run/initramfs/usr/share/images/splash
cp -d -aR --parents /usr/share/fonts/splash "$copyto"/
cp -d -aR --parents /usr/share/images/splash "$copyto"/
cp -d --parents /usr/bin/splash.images "$copyto"/
cp -d --parents /usr/bin/splash.fonts "$copyto"/
}

create_fsck() {
if [ ! -e "$1"/sbin/fsck.btrfs ]; then
echo "#!/bin/sh

true
" >> "$1"/sbin/fsck.btrfs
chmod +x "$1"/sbin/fsck.btrfs
fi
}

get_root() {
    [ -n "$CONFIG_roottxt" ] && export CONFIG_root="$CONFIG_roottxt"
    if echo $CONFIG_root | grep -q ^'UUID=\|LABEL='; then
        export CONFIG_roottxt=$CONFIG_root
        export CONFIG_root=$(findfs $CONFIG_roottxt 2>/dev/null)
        [ -z $CONFIG_root ] && return 1
    elif echo $CONFIG_root | grep -q ^'ZFS='; then
        export CONFIG_roottxt="$CONFIG_root"
        export CONFIG_root=${CONFIG_root##ZFS=}
        if [ -f /etc/zfs/zpool.cache ]; then
                zpool list ${CONFIG_root} >/dev/null 2>&1|| zpool import -f -N ${CONFIG_root} 2>&1
        else
                zpool import -f -N ${CONFIG_root} 2>&1
        fi
        [ $? -ne 0 ] && return 1
        export CONFIG_rootfs=$(zpool list -H -o bootfs ${CONFIG_root} 2>/dev/null)
        [ -z "$CONFIG_rootfs" -o "$CONFIG_rootfs" = - ] && return 1
        zfs list "$CONFIG_rootfs" >/dev/null 2>&1 || return 1
        zfs set mountpoint=/ "$CONFIG_rootfs" >/dev/null 2>&1 || return 1
        export CONFIG_root="$CONFIG_rootfs"
        export CONFIG_rootfstype=zfs
        export CONFIG_rootfsopts=zfsutil
        [ "$(zfs get atime -H "$CONFIG_root"|awk '{print $3}')" = off ] && export CONFIG_rootfsopts="$CONFIG_rootfsopts,noatime"
        return 0
    else
        [ -b $CONFIG_root ] || return 1
    fi

    if [ $CONFIG_rootfstype = btrfs ]; then
        btrfs dev scan || :
        READY=$(btrfs dev ready $CONFIG_root 2>&1)
        if [ $? -eq 1 ]; then
                echo $READY | grep -q Inappropriate || return 1
        fi
        [ "$(btrfs fi show $CONFIG_root | grep -c devid)" -gt 1 ] && export RESIZEERROR=1
    fi

    export DEV="${CONFIG_root%[0-9]}"
    if [ ! -e ${DEV} ]; then
	export DEV=${DEV%p}
	export PARTdelim='p'
    else
	export PARTdelim=''
    fi
    export PART=${CONFIG_root#${CONFIG_root%?}}

    return 0
}

convert_btrfs() {
# Check for the existance of tune2fs through the RESIZEERROR variable
if [ "$CONFIG_noconvertsd" -eq '0' -a "${CONFIG_rootfstype}" = "btrfs" -a "$FSCHECK" != "btrfs" ]; then
    [ "$RESIZEERROR" -gt '0' -a "$RESIZEERROR_NONFATAL" -ne '1' ] && return 0
	if [ "${FSCHECK}" = 'ext4' ]; then
		# Make sure we have enough memory available for live conversion
		FREEMEM=`free -m | grep "Mem:" | awk '{printf "%d", $4}'`
		if [ ${FREEMEM} -lt '128' ]; then
				test ! -d /boot && mkdir /boot
				/bin/mount "${DEV}${PARTdelim}1" /boot
				# Save the old memory value to the cmdline.txt to restore it later on
				cp /boot/config.txt /boot/config.txt.convert
				sed -i "s/gpu_mem_256=[0-9]*/gpu_mem_256=32/g" /boot/config.txt
				umount /boot
				reboot -f
		fi	
	
		test -n "$CONFIG_splash" && /usr/bin/splash --infinitebar --msgtxt="sd card convert..."
		test -n "$CONFIG_splash" \
|| echo '
 .d8888b.   .d88888b.  888b    888 888     888 8888888888 8888888b. 88888888888
d88P  Y88b d88P" "Y88b 8888b   888 888     888 888        888   Y88b    888
888    888 888     888 88888b  888 888     888 888        888    888    888
888        888     888 888Y88b 888 Y88b   d88P 8888888    888   d88P    888
888        888     888 888 Y88b888  Y88b d88P  888        8888888P"     888
888    888 888     888 888  Y88888   Y88o88P   888        888 T88b      888
Y88b  d88P Y88b. .d88P 888   Y8888    Y888P    888        888  T88b     888
 "Y8888P"   "Y88888P"  888    Y888     Y8P     8888888888 888   T88b    888';
		e2fsck -p -f ${CONFIG_root}
		/splash_updater.sh &
		stdbuf -o 0 -e 0 btrfs-convert -d ${CONFIG_root} 2>&1 > /tmp/output.grab
		touch /run/splash_updater.kill
		export FSCHECK=`blkid -s TYPE -o value -p ${CONFIG_root} `
	fi
	
	test ! -d /boot && mkdir /boot
	/bin/mount "${DEV}${PARTdelim}1" /boot
	test -e /boot/config.txt.convert && mv /boot/config.txt.convert /boot/config.txt
	test "$FSCHECK" = "ext4" && sed -i "s/rootfstype=btrfs/rootfstype=ext4/g" /boot/cmdline.txt
	if [ "$FSCHECK" = "btrfs" ]; then
		test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt="post conversion tasks..."
		/sbin/btrfs fi label ${CONFIG_root} xbian-root-btrfs
		mount_root_btrfs
		create_fsck $CONFIG_newroot
		/sbin/btrfs sub delete $CONFIG_newroot/ext2_saved

		/sbin/btrfs sub create $CONFIG_newroot/ROOT
		echo "Moving root..."
		test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt="moving root..."
		/sbin/btrfs sub snap $CONFIG_newroot $CONFIG_newroot/ROOT/@

                mount && echo '============================' && sleep 15
		for f in $(ls $CONFIG_newroot | grep -vw ROOT); do rm -fr $CONFIG_newroot/$f >/dev/null 2>&1; done

		mv $CONFIG_newroot/ROOT $CONFIG_newroot/root
		/sbin/btrfs sub create $CONFIG_newroot/home
		/sbin/btrfs sub create $CONFIG_newroot/home/@
		/sbin/btrfs sub create $CONFIG_newroot/modules
		/sbin/btrfs sub create $CONFIG_newroot/modules/@
		mv $CONFIG_newroot/root/@/home/* $CONFIG_newroot/home/@
		mv $CONFIG_newroot/root/@/lib/modules/* $CONFIG_newroot/modules/@
		cp $CONFIG_newroot/root/@/etc/fstab $CONFIG_newroot/root/@/etc/fstab.ext4
# edit fstab
                sed -i "/\(\/var\/swapfile\)/d" $CONFIG_newroot/root/@/etc/fstab

            if grep -wq "/tmp" $CONFIG_newroot/root/@/etc/fstab; then
                grep -wv "/tmp" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
                mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            fi

            if grep -wq 'root/@' $CONFIG_newroot/root/@/etc/fstab; then
                grep -wv 'root/@' $CONFIG_newroot/root/@/etc/fstab >> $CONFIG_newroot/root/@/etc/fstab.new
                mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            fi

#            if [ $(grep -w '/dev/root' $CONFIG_newroot/root/@/etc/fstab | grep -wc '/home') -ne 1 -o $(grep -w '/dev/root' $CONFIG_newroot/root/@/etc/fstab | grep -w '/home' | grep -c 'subvol=') -ne 1 ]; then
                if grep -wq "/home" $CONFIG_newroot/root/@/etc/fstab; then
                    grep -wv "/home" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
                    mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
                fi
                echo "/dev/root             /home                   xbian   subvol=home/@,noatime,nobootwait           0       0" >> $CONFIG_newroot/root/@/etc/fstab
#            fi

            if grep -wq "/lib/modules" $CONFIG_newroot/root/@/etc/fstab; then
                grep -wv "/lib/modules" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
                mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            fi
            echo "/dev/root             /lib/modules            xbian   subvol=modules/@,noatime,nobootwait        0       0" >> $CONFIG_newroot/root/@/etc/fstab

            if grep -wq "/" $CONFIG_newroot/root/@/etc/fstab; then
                grep -wv "/" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
                grep ^'//' $CONFIG_newroot/root/@/etc/fstab >> $CONFIG_newroot/root/@/etc/fstab.new
                mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            fi
            echo "/dev/root             /                       xbian   noatime,nobootwait                         0       0" >> $CONFIG_newroot/root/@/etc/fstab

            if grep -wq "/proc" $CONFIG_newroot/root/@/etc/fstab; then
                grep -wv "/proc" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
                mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            fi

            grep -wv "/boot" $CONFIG_newroot/root/@/etc/fstab > $CONFIG_newroot/root/@/etc/fstab.new
            mv $CONFIG_newroot/root/@/etc/fstab.new $CONFIG_newroot/root/@/etc/fstab
            echo "/dev/mmcblk0p1        /boot                   xbian   rw,nobootwait                              0       1" >> $CONFIG_newroot/root/@/etc/fstab

            if ! grep -wq "/run/user" $CONFIG_newroot/root/@/etc/fstab; then
                echo "none            /run/user                       tmpfs                   noauto                  0       0" >> $CONFIG_newroot/root/@/etc/fstab
            fi
            if ! grep -wq "/sys/kernel/security" $CONFIG_newroot/root/@/etc/fstab; then
                echo "none            /sys/kernel/security            securityfs              noauto                  0       0" >> $CONFIG_newroot/root/@/etc/fstab
            fi
            if ! grep -wq "/sys/kernel/debug" $CONFIG_newroot/root/@/etc/fstab; then
                echo "none            /sys/kernel/debug               debugfs                 noauto                  0       0" >> $CONFIG_newroot/root/@/etc/fstab
            fi
            if ! grep -wq "/run/shm" $CONFIG_newroot/root/@/etc/fstab; then
                echo "none            /run/shm                        tmpfs                   noauto                  0       0" >> $CONFIG_newroot/root/@/etc/fstab
            fi
            if ! grep -wq "/run/lock" $CONFIG_newroot/root/@/etc/fstab; then
                echo "none            /run/lock                       tmpfs                   noauto                  0       0" >> $CONFIG_newroot/root/@/etc/fstab
            fi
# end edit fstab
		echo "rebalancing filesystem..."
		test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt="rebalancing filesystem..."
		btrfs fi bal "$CONFIG_newroot"
		umount $CONFIG_newroot
	fi
	if [ "$FSCHECK" = btrfs ]; then
	    echo "FILESYSTEM WAS SUCESSFULLY CONVERTED TO BTRFS"
	    echo "ADAPTING rootflags IN CMDLINE.TXT"
            if grep -q rootflags /boot/cmdline.txt; then
                sed -i 's/rootflags=.*? /rootflags=subvol=root\/@,autodefrag,compress=lzo/g' /boot/cmdline.txt
            else
                l="$(cat /boot/cmdline.txt) rootflags=subvol=root/@,autodefrag,compress=lzo" 
                echo $l > /boot/cmdline.txt
            fi
	fi
	test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt="rebooting..."
	umount /boot
	sync
	reboot -nf
fi
}

resize_part() {
if [ "$RESIZEERROR" -eq '0' -a "$CONFIG_noresizesd" -eq '0' -a "${CONFIG_rootfstype}" != "nfs" ]; then
	nrpart=$(sfdisk -s $DEV$PARTdelim? | grep -c .)
	if [ "$nrpart" -gt "$PART" ]; then
		test -z "$CONFIG_partswap" && echo "FATAL: only the last partition can be resized"
		export RESIZEERROR='1'
		export RESIZEERROR_NONFATAL=1
		return 1
	fi

	#Save partition table to file
	/sbin/sfdisk -u S -d ${DEV} > /tmp/part.txt
	#Read partition sizes
	sectorTOTAL=$(blockdev --getsz ${DEV})
	sectorSTART=$(grep ${CONFIG_root} /tmp/part.txt | awk '{printf "%d", $4}')
	sectorSIZE=$(grep ${CONFIG_root} /tmp/part.txt | awk '{printf "%d", $6}')
	export sectorNEW=$(( $sectorTOTAL - $sectorSTART ))
	rm /tmp/part.txt &>/dev/null

	if [ $sectorSIZE -lt $sectorNEW ]; then
		test -n "$CONFIG_splash" && /usr/bin/splash --infinitebar --msgtxt="sd card resize..."
		test -n "$CONFIG_splash" \
|| echo '
8888888b.  8888888888  .d8888b.  8888888 8888888888P 8888888 888b    888  .d8888b.
888   Y88b 888        d88P  Y88b   888         d88P    888   8888b   888 d88P  Y88b
888    888 888        Y88b.        888        d88P     888   88888b  888 888    888
888   d88P 8888888     "Y888b.     888       d88P      888   888Y88b 888 888
8888888P"  888            "Y88b.   888      d88P       888   888 Y88b888 888  88888
888 T88b   888              "888   888     d88P        888   888  Y88888 888    888
888  T88b  888        Y88b  d88P   888    d88P         888   888   Y8888 Y88b  d88P
888   T88b 8888888888  "Y8888P"  8888888 d8888888888 8888888 888    Y888  "Y8888P88'

		pSIZE=$(sfdisk -s ${CONFIG_root} | awk -F'\n' '{ sum += $1 } END {print sum}')
		echo ",${sectorNEW},,," | sfdisk -uS -N${PART} --force -q ${DEV}
		/sbin/partprobe
		nSIZE=$(sfdisk -s ${CONFIG_root} | awk -F'\n' '{ sum += $1 } END {print sum}')

		if [ ! $nSIZE -gt $pSIZE ]; then
			echo "Resizing failed..."
			export RESIZEERROR="1"
		else
			echo "Partition resized..."
		fi
	else
		export RESIZEERROR="0"
	fi
fi

[ "$RESIZEERROR" -lt '0' ] && return 0 || return $RESIZEERROR
}

resize_ext4() {
if [ "$RESIZEERROR" -eq "0" -a "$CONFIG_noresizesd" -eq '0' -a "$FSCHECK" = "ext4" ]; then

	if [ "${FSCHECK}" = 'ext4' ]; then
		# check if the partition needs resizing
		TUNE2FS=$(/sbin/tune2fs -l ${CONFIG_root})
		TUNEBLOCKSIZE=$(echo -e "${TUNE2FS}" | grep "Block size" | awk '{printf "%d", $3}')
		TUNEBLOCKCOUNT=$(echo -e "${TUNE2FS}" | grep "Block count" | awk '{printf "%d", $3}')
		export BLOCKNEW=$(($sectorNEW / ($TUNEBLOCKSIZE / 512) ))

		# resize root partition
		if [ "$TUNEBLOCKCOUNT" -lt "$BLOCKNEW" ]; then
			test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt="fs resize..."
			test -n "$CONFIG_splash" \
|| echo '
8888888b.  8888888888  .d8888b.  8888888 8888888888P 8888888 888b    888  .d8888b.
888   Y88b 888        d88P  Y88b   888         d88P    888   8888b   888 d88P  Y88b
888    888 888        Y88b.        888        d88P     888   88888b  888 888    888
888   d88P 8888888     "Y888b.     888       d88P      888   888Y88b 888 888
8888888P"  888            "Y88b.   888      d88P       888   888 Y88b888 888  88888
888 T88b   888              "888   888     d88P        888   888  Y88888 888    888
888  T88b  888        Y88b  d88P   888    d88P         888   888   Y8888 Y88b  d88P
888   T88b 8888888888  "Y8888P"  8888888 d8888888888 8888888 888    Y888  "Y8888P88';
			e2fsck -p -f ${CONFIG_root}
			/bin/mount -t ext4 ${CONFIG_root} "$CONFIG_newroot"
			TUNEBLOCKCOUNT=$(/sbin/resize2fs ${CONFIG_root} | grep now | rev | awk '{print $3}' | rev)
			if [ "$?" -eq '0' ]; then
				TUNEBLOCKCOUNT=${BLOCKNEW}
			fi
			umount ${CONFIG_root}

			# check if parition was actually resized
			if [ "${TUNEBLOCKCOUNT}" -lt "${BLOCKNEW}" ]; then
				echo "Resizing failed..."
				export RESIZEERROR="1"
			else
				echo "Filesystem resized..."
			fi
			#e2fsck -p -f ${CONFIG_root}
		fi
	fi
fi
}

resize_btrfs() {
if [ "$RESIZEERROR" -eq "0" -a "$CONFIG_noresizesd" -eq '0' -a "$CONFIG_rootfstype" = "btrfs" -a "$FSCHECK" = 'btrfs' ]; then

        smsg="fs resize..."
        [ -n "$1" ] && smsg="$1" 

	# check if the partition needs resizing
	sectorDF=$(df -B512 -P | grep "$CONFIG_newroot" | awk '{printf "%d", $2}')
	
	# resize root partition
	if [ "$sectorDF" -lt "$sectorNEW" ]; then
		test -n "$CONFIG_splash" && /usr/bin/splash --msgtxt=$smsg
		test -n "$CONFIG_splash" \
|| echo '
8888888b.  8888888888  .d8888b.  8888888 8888888888P 8888888 888b    888  .d8888b.
888   Y88b 888        d88P  Y88b   888         d88P    888   8888b   888 d88P  Y88b
888    888 888        Y88b.        888        d88P     888   88888b  888 888    888
888   d88P 8888888     "Y888b.     888       d88P      888   888Y88b 888 888
8888888P"  888            "Y88b.   888      d88P       888   888 Y88b888 888  88888
888 T88b   888              "888   888     d88P        888   888  Y88888 888    888
888  T88b  888        Y88b  d88P   888    d88P         888   888   Y8888 Y88b  d88P
888   T88b 8888888888  "Y8888P"  8888888 d8888888888 8888888 888    Y888  "Y8888P88'
		/sbin/btrfs fi resize max $CONFIG_newroot
		/sbin/btrfs fi sync $CONFIG_newroot
		
		sectorDF=`df -B512 -P | grep "$CONFIG_newroot" | awk '{printf "%d", $2}'`

		# check if parition was actually resized
		if [ "$sectorDF" -lt "$sectorNEW" ]; then
			export RESIZEERROR="1"
		fi
	fi
fi
}

move_root() {
[ ! -e /etc/blkid.tab ] || cp /etc/blkid.tab $CONFIG_newroot/etc

/bin/mount --move /run $CONFIG_newroot/run
rm -fr /run
ln -s $CONFIG_newroot/run /run

udevadm control --exit
if [ -e /etc/udev/udev.conf ]; then
  . /etc/udev/udev.conf
fi

/bin/mount --move /dev $CONFIG_newroot/dev
rm -fr /dev
ln -s $CONFIG_newroot/dev /dev

/bin/mount --move /sys $CONFIG_newroot/sys
rm -fr /sys
ln -s $CONFIG_newroot/sys /sys

/bin/mount --move /proc $CONFIG_newroot/proc
rm -fr /proc
ln -s $CONFIG_newroot/proc /proc
}

create_swap() {
if [ "$RESIZEERROR" -eq "0" -a "$CONFIG_partswap" -eq '1' -a "$CONFIG_rootfstype" = "btrfs" -a "$FSCHECK" = 'btrfs' ]; then
    nrpart=$(sfdisk -s $DEV$PARTdelim? | grep -c .)
    [ $nrpart -gt $PART -o $PART -gt 3 ] && return 1
    [ "$(blkid -s TYPE -o value -p $DEV$PARTdelim$nrpart)" = swap ] && return 0
    mount_root_btrfs $CONFIG_root && resize_btrfs "creating swap..."
    mountpoint -q $CONFIG_newroot || return 1

    swapsize=$(( $(blockdev --getsize64 $CONFIG_root) /10/1024/1024)); [ $swapsize -gt 250 ] && swapsize=250

    /sbin/btrfs fi resize -${swapsize}M $CONFIG_newroot || { umount $CONFIG_newroot; return 1; }
    /sbin/btrfs fi sync $CONFIG_newroot
    umount $CONFIG_newroot
    swapsize=$(( $swapsize - 5 ))
    echo ",-$swapsize,,," | sfdisk -uM -N${PART} --force ${DEV}
    /sbin/partprobe
    pend=$(sfdisk -l -uS ${DEV} 2>/dev/null| grep $CONFIG_root | awk '{print $3}')
    pstart=$(( ($pend/2048 + 1) * 2048));pPART=$(($PART+1))
    echo "$pstart,+,S,," | sfdisk -uS -N${pPART} --force ${DEV}
    /sbin/partprobe
    mkswap ${DEV}${PARTdelim}${pPART}
fi
}

kill_splash() {
	test -n "$CONFIG_splash" && /bin/kill -SIGTERM $(pidof splash) 2>/dev/null
	test -n "$CONFIG_splash" && /bin/kill -SIGTERM $(pidof splash-daemon) 2>/dev/null
	rm -fr /run/splash
	busybox setconsole -r
}

drop_shell() {
	kill_splash
	set +x

	[ ! -d /boot ] && mkdir /boot
	/bin/mount /dev/mmcblk0p1 /boot

	if [ "$1" != noumount ]; then
	    mountpoint -q $CONFIG_newroot || eval $mount_bin -t ${CONFIG_rootfstype} -o rw,"$CONFIG_rootfsopts" "${CONFIG_root}" $CONFIG_newroot
	    mountpoint -q $CONFIG_newroot/proc || /bin/mount -o bind /proc $CONFIG_newroot/proc
	    mountpoint -q $CONFIG_newroot/boot || /bin/mount -o bind /boot $CONFIG_newroot/boot
	    mountpoint -q $CONFIG_newroot/dev || /bin/mount -o bind /dev $CONFIG_newroot/dev
	    mountpoint -q $CONFIG_newroot/dev/pts || /bin/mount -o bind /dev $CONFIG_newroot/dev/pts
	    mountpoint -q $CONFIG_newroot/sys || /bin/mount -o bind /sys $CONFIG_newroot/sys
	    mountpoint -q $CONFIG_newroot/run || /bin/mount -o bind /run $CONFIG_newroot/run
	    [ "$CONFIG_rootfstype" = btrfs ] && ! mountpoint -q $CONFIG_newroot/lib/modules  && /bin/mount -t ${CONFIG_rootfstype} -o rw,subvol=modules/@ "${CONFIG_root}" $CONFIG_newroot/lib/modules
	fi
	mountpoint -q $CONFIG_newroot && ln -s /rootfs /run/initramfs/rootfs
	[ -n "${CONFIG_console}" ] && exec > /dev/$CONFIG_console
	cat /motd
	echo "========================================================================="
	cat /howto.txt
	if [ -f /bin/bash ]; then
		busybox cttyhack /bin/bash
	else 
		ENV=/.profile busybox cttyhack /bin/sh
	fi
	rm -fr /run/do_drop
	ps | grep busybox | grep telnetd | xargs kill 2>/dev/null; pkill sshrun

	mountpoint -q /boot && umount /boot; [ -d /boot ] && rmdir /boot
	if [ "$1" != noumount ]; then
	    mountpoint -q $CONFIG_newroot/boot && umount $CONFIG_newroot/boot
	    mountpoint -q $CONFIG_newroot/proc && umount $CONFIG_newroot/proc
	    mountpoint -q $CONFIG_newroot/dev/pts && umount $CONFIG_newroot/dev/pts
	    mountpoint -q $CONFIG_newroot/dev && umount $CONFIG_newroot/dev
	    mountpoint -q $CONFIG_newroot/sys && umount $CONFIG_newroot/sys
	    mountpoint -q $CONFIG_newroot/run && umount $CONFIG_newroot/run
	    mountpoint -q $CONFIG_newroot/lib/modules && umount $CONFIG_newroot/lib/modules
	    mountpoint -q $CONFIG_newroot && umount $CONFIG_newroot
	fi
	return 0
}

load_modules() {
export MODPROBE_OPTIONS='-qb'
echo "Loading initram modules ... "
grep '^[^#]' /etc/modules |
    while read module args; do
        [ -n "$module" ] || continue
        [ "$module" != usb_storage ] || continue
        /sbin/modprobe $MODPROBE_OPTIONS $module $args || :
    done
}
