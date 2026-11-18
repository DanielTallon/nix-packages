# mode: classic
# A plain configuration.nix: the definition is found in your folder, and nixpkgs (reached through
# a channel symlink) is not mistaken for your config.
# expect: option-not-exist
# expect-output: Whose: Your config
# expect-output: Where: case.nix, line 9
{ ... }:
{
  services.openssh.enabel = true;
}
