# A home-manager flake-parts module whose file was deleted (seen in ~/.dotfiles: discord-nixcord.nix).
# The report shouldn't hedge with "or moved" (a moved file would still be found), nor show the
# option Nix happened to be evaluating.
# deleted: home-manager/discord.nix { flake.modules.homeManager.discord = { }; }
# expect: missing-module
# expect-output: uses the home-manager module `discord`, but no file sets `flake.modules.homeManager.discord`
# expect-output: home-manager/discord.nix used to set it, but that file was deleted since your last commit
# expect-output: checkout HEAD -- home-manager/discord.nix
{ ... }:
let
  config.flake.modules.homeManager.aliases = { };
in
{
  imports = [
    config.flake.modules.homeManager.aliases
    config.flake.modules.homeManager.discord
  ];
}
