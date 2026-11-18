# mode: classic
# A plain configuration.nix (no flake, no git): the line is still found, and blamed on you.
# expect: undefined-variable
# expect-output: Whose: Your config
# expect-output: Where: case.nix, line 9
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    neovimm
  ];
}
