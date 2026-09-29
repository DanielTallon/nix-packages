{ lib, stdenv, fetchgit, fetchurl, meson, ninja, glslang, wine, windows }:
  # RTAS prebuild-size x8 workaround for vkd3d-proton#3226 (Witcher 3 RT GPU hang on NVIDIA 590+)
  # by gabrielmaialva33: https://gist.github.com/gabrielmaialva33/33ebb2542f0513d55100b22aa2149ff5
stdenv.mkDerivation {
  pname = "vkd3d-proton-w3rt";
  version = "af89350c-rtas-x8";

  src = fetchgit {
    url = "https://github.com/HansKristian-Work/vkd3d-proton";
    rev = "af89350cc2eacd9da2293fbae96bd9ab4987c9bb";
    fetchSubmodules = true;
    hash = "sha256-K6nrw1rbEbqYNwpj1vMkibfHK9gVGi81W0kUYJb6G9Q=";

  };

  patches = [
    (fetchurl {
      url = "https://gist.github.com/gabrielmaialva33/33ebb2542f0513d55100b22aa2149ff5/raw/7a97d95f5aeffeda5fad59dbfb80270d27600682/vkd3d-rtas-prebuild-x8.patch";
      hash = "sha256-t8xcATC1RaDuuBRZJnZWRIJYWCDUrIYmXguxIxmV8QA="; # patch hash
    })
  ];

    nativeBuildInputs = [ meson ninja glslang wine ]; # wine provides widl
    buildInputs = [ windows.pthreads ];               # mingw winpthreads for -lpthread
    mesonBuildType = "release";

  meta = {
    description = "vkd3d-proton (GE-Proton11-7 commit) with an RTAS size workaround for Witcher 3 ray tracing under Proton";
    homepage = "https://github.com/HansKristian-Work/vkd3d-proton";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.windows;
  };
}
