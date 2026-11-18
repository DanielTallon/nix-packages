# mode: captured
# `sudo nixos-rebuild switch 2>&1 | nixed-error` on a classic NixOS VM, with a oneshot service that fails
# (fixture transcribed from the real run). The program's own output and systemd's exit status must show,
# and the service is found in the config, at its ExecStart.
# expect-output: Whose: Your config
# expect-output: Where: configuration.nix, line 11
# expect-output: ran, but exited with status 1: the program itself reported an error.
# expect-output: You define it yourself, on line 6 of configuration.nix.
# expect-output: It failed while switching to your new config.
# expect-output: End of nixed-test.service's log:
# expect-output: > something broke
# expect-output: What systemd said: nixed-test.service: Main process exited, code=exited, status=1/FAILURE
# expect-output: Look at line 11 of configuration.nix, the command the service runs.
{ config, pkgs, ... }:

{
  networking.hostName = "nixos";

  systemd.services.nixed-test = {
    description = "Diliberately failing unit for nixed-error";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo something broke >&2; exit 1'";
    };
  };
}
