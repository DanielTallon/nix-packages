# A module whose `package` defaults to a removed package: point at where the module is enabled,
# and don't advise renaming it. The option is declared here to stand in for an upstream module;
# getAttr keeps "pkgs.zscroll" out of this file so the search can't land on the default.
# expect: package-renamed-or-removed
# expect-output: Where: hosts/case.nix, line 17
# expect-output: turns on NixOS's fakeviz module
# expect-output: Quickest: change `enable = true;` on line 18 to `enable = false;`.
# expect-output: remove the `programs.fakeviz = { … };` block
{ config, lib, pkgs, ... }:
{
  options.programs.fakeviz = {
    enable = lib.mkEnableOption "fakeviz";
    package = lib.mkOption { type = lib.types.package; default = builtins.getAttr "zscroll" pkgs; };
  };
  config = lib.mkMerge [
    (lib.mkIf config.programs.fakeviz.enable { environment.systemPackages = [ config.programs.fakeviz.package ]; })
    {
      programs.fakeviz = {
        enable = true;
      };
    }
  ];
}
