{ lib, stdenv, fetchFromGitHub, cmake, qt6, imagemagick, ...}:

# NOTE: this is a placeholder. You already have a working flake.nix/package.nix
# for this at ~/Develop/lgl-papercutter — port the real `mkDerivation` call
# (source fetch, build inputs, qt6 wrapping, install phase) in here.
#
# Two things worth double-checking as you port it over:
#   1. `src` — swap whatever local/path reference you were using for a
#      `fetchFromGitHub` (or similar) pointing at the upstream LGL Papercutter
#      repo, pinned to a rev/hash, so this package doesn't depend on anything
#      local to your machine.
#   2. Wrapping — if the app needs `QT_QPA_PLATFORM`, plugin paths, or an
#      ImageMagick binary on PATH at runtime, make sure `wrapQtAppsHook`
#      (from qt6) and any `postFixup` wrapProgram calls carry over.

stdenv.mkDerivation (finalAttrs: {
  pname = "lgl-papercutter";
  version = "0.0.0"; # replace with the real version

  src = fetchFromGitHub {
    owner = "linuxgamerlife";
    repo = "lgl-papercutter";
    rev = "REPLACE_ME";
    hash = "REPLACE_ME"; # nix will tell you the right value on first build attempt
  };

  nativeBuildInputs = [
    cmake
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    imagemagick
  ];

  meta = {
    description = "Qt6/ImageMagick wallpaper editor";
    homepage = "https://github.com/linuxgamerlife/lgl-papercutter";
    license = lib.licenses.mit;
    mainProgram = "lgl-papercutter";
  };
})
