# The NVIDIA driver is unfree, but the config never names nvidia-x11: point at videoDrivers.
# expect: unfree
# expect-output: Where: hosts/case.nix, line 8
# expect-output: It's pulled in by hosts/case.nix, line 8
# expect-output: nixpkgs.config.allowUnfree = true;
{ ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia.open = false;
}
