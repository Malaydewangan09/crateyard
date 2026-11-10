#!/bin/sh
# Runs once inside a RAM-only Alpine to install Crateyard's root disk, then powers off.
exec >/dev/hvc0 2>&1
set -eux
trap 'echo CRATEYARD_PROVISION_FAILED; sync; poweroff' EXIT

# The repo may be plain HTTP because the guest clock can be wrong before first sync. apk checks every package against
# the keys in the initramfs, and the Mac verified that initramfs by SHA-256.
REPO='@ALPINE_REPO@'

mkfs.ext4 -q -F -L crateyard-root /dev/vda
# The data disk holds every image and volume, so only a new one is formatted.
if [ '@FORMAT_DATA@' = true ]; then mkfs.ext4 -q -F -L crateyard-data /dev/vdb; fi
modprobe ext4
mount -t ext4 /dev/vda /mnt

mkdir -p /mnt/etc/apk /mnt/dev /mnt/proc /mnt/sys
cp -a /etc/apk/keys /mnt/etc/apk/
printf '%s/main\n%s/community\n' "$REPO" "$REPO" > /mnt/etc/apk/repositories
mount --bind /dev /mnt/dev
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys

apk add --root /mnt --initdb --no-cache alpine-base linux-virt docker e2fsprogs socat

cat > /mnt/etc/fstab <<'EOF'
/dev/vda / ext4 rw,relatime 0 1
/dev/vdb /var/lib/docker ext4 rw,relatime 0 2
crateyard /Users virtiofs rw,nofail 0 0
EOF
printf 'virtiofs\nvirtio_balloon\n' >> /mnt/etc/modules
mkdir -p /mnt/var/lib/docker /mnt/etc/docker /mnt/etc/network /mnt/Users
echo crateyard > /mnt/etc/hostname
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > /mnt/etc/network/interfaces

for s in devfs dmesg mdev hwdrivers; do chroot /mnt rc-update add $s sysinit; done
for s in modules sysctl hostname bootmisc root localmount networking cgroups seedrng; do chroot /mnt rc-update add $s boot; done
chroot /mnt rc-update add docker default
# The host has no shell into the guest yet, so dockerd's log goes to the console log on the Mac.
mkdir -p /mnt/etc/local.d
printf '#!/bin/sh\ntail -F /var/log/docker.log > /dev/hvc0 2>&1 &\n' > /mnt/etc/local.d/docker-log.start
# The Mac reaches dockerd over vsock, because macOS local-network privacy blocks unsigned tools from the VM's IP.
# socat's -t is how long it keeps a connection after one side half-closes. The default 0.5 s cut off `docker run` output.
printf '#!/bin/sh\nmodprobe vmw_vsock_virtio_transport\nsocat -t 315360000 VSOCK-LISTEN:2375,reuseaddr,fork,backlog=128 UNIX-CONNECT:/var/run/docker.sock > /dev/hvc0 2>&1 &\n' > /mnt/etc/local.d/docker-vsock.start
# The host sizes the memory balloon from the guest's own view of used memory.
printf '#!/bin/sh\nsocat VSOCK-LISTEN:2376,reuseaddr,fork SYSTEM:"cat /proc/meminfo /proc/vmstat" > /dev/hvc0 2>&1 &\n' > /mnt/etc/local.d/meminfo-vsock.start
# Published container ports: the Mac sends the port number on the first line, then the guest pipes to it.
mkdir -p /mnt/usr/local/bin
printf '#!/bin/sh\nread -r port\ncase "$port" in ""|*[!0-9]*) exit 1;; esac\nexec socat -t 315360000 STDIO TCP:127.0.0.1:"$port"\n' > /mnt/usr/local/bin/crateyard-portfwd
chmod +x /mnt/usr/local/bin/crateyard-portfwd
printf '#!/bin/sh\nsocat -t 315360000 VSOCK-LISTEN:2377,reuseaddr,fork,backlog=128 EXEC:/usr/local/bin/crateyard-portfwd > /dev/hvc0 2>&1 &\n' > /mnt/etc/local.d/portfwd-vsock.start
chmod +x /mnt/etc/local.d/docker-log.start /mnt/etc/local.d/docker-vsock.start /mnt/etc/local.d/meminfo-vsock.start /mnt/etc/local.d/portfwd-vsock.start
# Hourly TRIM lets APFS reclaim blocks freed by deleted images, so data.img shrinks.
printf '#!/bin/sh\nfstrim /var/lib/docker\n' > /mnt/etc/periodic/hourly/fstrim
chmod +x /mnt/etc/periodic/hourly/fstrim
chroot /mnt rc-update add crond default
chroot /mnt rc-update add local default
for s in killprocs mount-ro savecache; do chroot /mnt rc-update add $s shutdown; done

tar cf /dev/vdc -C /mnt/boot vmlinuz-virt initramfs-virt

umount /mnt/sys /mnt/proc /mnt/dev /mnt
trap - EXIT
echo CRATEYARD_PROVISION_OK
sync
poweroff
