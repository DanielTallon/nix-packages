# mode: captured
# Real output from the user's config (2026-10-24): nexusmods-app-unfree added to systemPackages after
# nixpkgs marked it insecure because upstream discontinued it. The trace only names man-db's options.
# expect-output: Where: configuration.nix, line 3
# expect-output: - NexusMods.App has been discontinued upstream: https://www.nexusmods.com/news/15424
# expect-output: It won't get fixes any more, so remove it from line 3 of configuration.nix
# expect-output: nixpkgs.config.permittedInsecurePackages = [ "nexusmods-app-unfree-0.21.1" ];
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.nexusmods-app-unfree ];
}
