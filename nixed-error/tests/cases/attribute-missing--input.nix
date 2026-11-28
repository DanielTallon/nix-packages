# A name read from a flake input through a variable (seen in ~/.dotfiles: `nixPackages =
# inputs.nix-packages.packages.${system};` then `nixPackages.plymouth-nixos-chase-glitch`, pushed to the
# input's repo but flake.lock not updated). Not a nixpkgs search: name the input, its locked commit, the
# one-input update, and close names that do exist in it (here a typo).
# expect: attribute-missing
# expect-output: `firefx` isn't in your locked nixpkgs
# expect-output: `firefx` is read from the flake input `nixpkgs` (inputs.nixpkgs.legacyPackages.${system})
# expect-output: nix flake update nixpkgs
# expect-output: Or, if you meant `firefox`: change line 15 to use it.
{ inputs, pkgs, ... }:
let
  np = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  environment.systemPackages = [ np.firefx ];
}
