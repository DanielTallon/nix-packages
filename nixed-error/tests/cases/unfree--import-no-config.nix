# A second nixpkgs made with `import` and no config at all: unfree is off there even though the system allows it.
# expect: unfree
# expect-output: Where: hosts/case.nix, line 8
# expect-output: It doesn't allow unfree packages, even if your system does.
# expect-output: Add `config.allowUnfree = true;` inside the `import { … }` on line 8 of hosts/case.nix
{ pkgs, ... }:
let
  pkgs-other = import pkgs.path { system = "x86_64-linux"; };
in
{
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = [ pkgs-other.unrar ];
}
