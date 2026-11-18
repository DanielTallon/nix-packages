# allowUnfree is set to false on purpose: point at that line, and say to flip it, not to "add" it.
# expect: unfree
# expect-output: Where: hosts/case.nix, line 9
# expect-output: and: hosts/case.nix, line 10
# expect-output: sets `allowUnfree = false`, which blocks it
# expect-output: Change line 9 of hosts/case.nix to `true`
{ pkgs, ... }:
{
  nixpkgs.config.allowUnfree = false;
  environment.systemPackages = [ pkgs.discord ];
}
