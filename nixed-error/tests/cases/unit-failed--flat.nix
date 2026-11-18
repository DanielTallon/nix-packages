# mode: captured
# The same failure, with the service block written without indentation (as on the user's VM): its ExecStart
# must still be found, by brackets rather than indentation.
# expect: unit-failed
# expect-output: Where: configuration.nix, line 9
# expect-output: Look at line 9 of configuration.nix, the command the service runs.
{ config, pkgs, ... }:

{
  systemd.services.nixed-test = {
  description = "Diliberately failing unit for nixed-error";
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.bash}/bin/bash -c 'echo something broke >&2; exit 1'";
    };
  };

  networking.hostName = "nixos";
}
