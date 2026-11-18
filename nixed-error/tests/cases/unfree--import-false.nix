# An unfree package from a second nixpkgs made with `import`, whose own config says allowUnfree = false.
# The system-wide nixpkgs.config.allowUnfree = true doesn't reach it: point at the import's setting.
# expect: unfree
# expect-output: Where: hosts/case.nix, line 13
# expect-output: and: hosts/case.nix, line 18
# expect-output: `pkgs-stable` is its own copy of nixpkgs, made with `import` on line 11 of hosts/case.nix
# expect-output: Change line 13 of hosts/case.nix to `true`
# expect-output: config.allowUnfreePredicate = pkg: builtins.elem (builtins.parseDrvName pkg.name).name [ "unrar" ];
{ pkgs, ... }:
let
  pkgs-stable = import pkgs.path {
    system = "x86_64-linux";
    config.allowUnfree = false;
  };
in
{
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = [ pkgs-stable.unrar ];
}
