{ config, lib, ... }:
{
  imports = lib.optional config.services.openssh.enable ./ssh-extra.nix;
}
