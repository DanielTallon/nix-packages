{ lib
, stdenv
, fetchurl
, appimageTools
, ...
}:

# NOTE: this is a placeholder. Your real derivation currently lives in your
# dotfiles at modules/kenku-fm/_default.nix, built via `pkgs-stable.callPackage`
# — port that logic in here.
#
# Worth checking as you port it over:
#   1. If Kenku FM ships as an AppImage upstream, `appimageTools.wrapType2`
#      (or `wrapType1`) is almost certainly what your original derivation
#      uses — carry that over rather than a plain mkDerivation.
#   2. `src` — swap any local path for a `fetchurl` pinned to a specific
#      upstream release + hash, so it's not tied to anything on your machine.
#   3. You pinned this against `nixpkgs-stable` (nixos-26.05) in your dotfiles
#      specifically for Kenku FM's build — this repo's flake.nix already pins
#      nixpkgs to nixos-26.05 for the same reason, so that constraint should
#      carry over for free. If the real reason was narrower (e.g. one specific
#      dependency's version), double check it still applies here.

appimageTools.wrapType2 rec {
  pname = "kenku-fm";
  version = "0.0.0"; # replace with the real version

  src = fetchurl {
    url = "REPLACE_ME"; # upstream AppImage release URL
    hash = "REPLACE_ME"; # nix will tell you the right value on first build attempt
  };

  extraPkgs = pkgs: with pkgs; [ ]; # add any runtime deps the AppImage needs

  meta = {
    description = "Kenku FM";
    homepage = "REPLACE_ME";
    license = lib.licenses.unfree; # replace with the actual upstream license
    platforms = [ "x86_64-linux" ];
    mainProgram = "kenku-fm";
  };
}
