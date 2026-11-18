# A misspelled flake-parts module name: suggest the modules that do exist, not `nix search`.
# expect: missing-module
# expect-output: no file sets `flake.modules.nixos.cavaleir`
# expect-output: Did you mean: `cavalier`
# expect-output: Change `cavaleir` to `cavalier`
# expect-output: remove `config.flake.modules.nixos.cavaleir` from line 12 of hosts/case.nix.
{ ... }:
let
  config.flake.modules.nixos.cavalier = { };
in
{
  imports = [ config.flake.modules.nixos.cavaleir ];
}
