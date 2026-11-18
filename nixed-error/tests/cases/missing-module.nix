# A flake-parts style module whose file was deleted: name the file that defined it,
# instead of treating `chaotic` as a package. The let stands in for flake-parts' `config`.
# deleted: hosts/chaotic.nix { flake.modules.nixos.chaotic = { }; }
# expect-output: Where: hosts/case.nix, line 16
# expect-output: hosts/chaotic.nix used to set it, but that file was deleted since your last commit
# expect-output: git -C
# expect-output: checkout HEAD -- hosts/chaotic.nix
# expect-output: If you meant to drop the module, remove line 16 of hosts/case.nix.
{ ... }:
let
  config.flake.modules.nixos.cavalier = { };
in
{
  imports = [
    config.flake.modules.nixos.cavalier
    config.flake.modules.nixos.chaotic
  ];
}
