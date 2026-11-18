# A new module file named after the module, not added to git and not defining it yet (seen in
# ~/.dotfiles: modules/fake.nix containing just "FAKE.NIX"). Name that file, and say both problems.
# untracked: modules/fake.nix FAKE.NIX
# expect: missing-module
# expect-output: modules/fake.nix looks like it's meant to, but it isn't added to git
# expect-output: It also doesn't set `flake.modules.nixos.fake` yet
# expect-output: add modules/fake.nix
{ ... }:
let
  config.flake.modules.nixos.core = { };
in
{
  imports = [
    config.flake.modules.nixos.core
    config.flake.modules.nixos.fake
  ];
}
