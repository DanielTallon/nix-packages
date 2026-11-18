# mode: captured
# What nixed-error's own re-check produces when the config builds but a unit is failed. The unit isn't
# written in the config, so the report points at the module that brings it in.
# expect: unit-failed
# expect-output: Where: configuration.nix, line 4
# expect-output: It isn't written in your files: it comes from the NixOS module you turn on on line 4 of configuration.nix.
# expect-output: Full log: journalctl -b -u nixedtestdaemon.service
{ config, pkgs, ... }:

{
  services.nixedtestdaemon.enable = true;
}
