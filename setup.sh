SWAPSIZE=64  # Swap size in GiB
RESERVE=1    # Reserved space at end in GiB
EFISIZE=4    # EFI partition size in GiB
DISKS="/dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1"
RPOOL_PARTS=$(for disk in $DISKS; do echo -n "${disk}p2 "; done)


partition_disk() {
    local disk="$1"
    # Wipe the disk
    blkdiscard -f "$disk" || true

    # Calculate boundaries in MiB for alignment (1MiB = 2048 sectors)
    local efi_start=1  # Start at 1MiB for alignment
    local efi_end=$((efi_start + EFISIZE * 1024))  # EFI partition ends at 1MiB + 4GiB
    local rpool_start=$efi_end  # ZFS starts where EFI ends
    local total_size_mib=$(parted -s "$disk" unit MiB print | grep "Disk $disk" | awk '{print int($3)}')
    local rpool_end=$((total_size_mib - (SWAPSIZE * 1024) - RESERVE * 1024))  # ZFS ends before swap + reserve
    local swap_start=$rpool_end
    local swap_end=$((swap_start + SWAPSIZE * 1024))

    # Create partitions with explicit MiB boundaries
    parted --script --align=optimal "$disk" -- \
        mklabel gpt \
        mkpart EFI "${efi_start}MiB" "${efi_end}MiB" \
        mkpart rpool "${rpool_start}MiB" "${rpool_end}MiB" \
        mkpart swap "${swap_start}MiB" "${swap_end}MiB" \
        set 1 esp on

    partprobe "$disk"
}

# Partition disks
for disk in $DISKS; do
    partition_disk "$disk"
done

# Format boot partitions
for disk in $DISKS; do
    mkfs.vfat -F 32 -n EFI "${disk}p1"
done

# Verify disks
for disk in $DISKS; do
    parted "$disk" unit s print
done

# Setup zpool on each disk
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -R /mnt \
    -O acltype=posixacl \
    -O canmount=off \
    -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/ \
    -O encryption=aes-256-gcm \
    -O keyformat=passphrase \
    rpool raidz1 $RPOOL_PARTS

# Create zpool datasets
zfs create -o canmount=off -o mountpoint=none rpool/nixos
zfs create -o mountpoint=/ rpool/nixos/root
zfs create -o mountpoint=/home rpool/nixos/home
zfs create -o mountpoint=/nix rpool/nixos/nix
zfs create -o mountpoint=/var rpool/nixos/var
zfs create -o mountpoint=/var/log rpool/nixos/var/log

# Set a blank snapshot for rollback (used during boot):
zfs snapshot rpool/nixos/root@blank

# Mount boot partitions
mkdir -p /mnt/boot/efis
for i in $(seq 1 $(echo $DISKS | wc -w)); do
  mkdir -p "/mnt/boot/efis/efi${i}"
  mount -o uid=0,gid=0,umask=077 $(echo $DISKS | cut -d' ' -f${i})p1 /mnt/boot/efis/efi${i}
done

# Generate nixos base config 
nixos-generate-config --root /mnt

# TODO: Add step to automatically copy starting nix config
# /mnt/etc/nixos/configuration.nix
# /mnt/etc/nixos/hardware-configuration.nix

# Install
# nixos-install --no-root-passwd