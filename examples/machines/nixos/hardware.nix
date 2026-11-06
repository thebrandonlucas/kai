# The disk and boot loader of a virtual machine; a real host has its own,
# such as nixos-generate-config writes.
{ ... }:
{
  boot.loader.grub.device = "/dev/vda";
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
