# mode: captured
# `nh os test` after a nixpkgs update bumped the NVIDIA driver (fixture modelled on the user's real run,
# 2026-10-15): the new nvidia-smi refuses the old, still-loaded kernel module. That's the machine, not the
# service, so the report says to reboot into the new generation instead of pointing at ExecStart.
# expect: unit-failed
# expect-output: Whose: Your machine
# expect-output: Where: configuration.nix, line 4
# expect-output: Your GPU driver changed during the last update, and you need to reboot to use it.
# expect-output: (here also `nvidia-persistenced.service`).
# expect-output: nh os boot reboot
# expect-output: Or without nh: sudo nixos-rebuild boot reboot
# expect-output: > Failed to initialize NVML: Driver/library version mismatch
{ config, pkgs, ... }:

{
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia.open = true;

  systemd.services.nixed-gpu-perf = {
    description = "NVIDIA persistence mode";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/run/current-system/sw/bin/nvidia-smi -pm 1";
    };
  };
}
