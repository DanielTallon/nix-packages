{ lib, stdenv, fetchFromGitHub, cmake, qt6, imagemagick, ...}:

stdenv.mkDerivation (finalAttrs: {
  pname = "lgl-papercutter";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "linuxgamerlife";
    repo = "lgl-papercutter";
    rev = "v0.3.0";
    hash = "sha256-KaIGuuXEKQzJQhX2s6qY7PJukcKLgUsshX/e+tVxPXc=";
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
