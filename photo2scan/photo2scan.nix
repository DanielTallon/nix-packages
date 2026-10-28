{ lib, stdenvNoCC, makeWrapper, python3 }:

# photo2scan.py sits next to this file; the wrapper runs it with a Python that
# has OpenCV, NumPy and img2pdf.
let
  python = python3.withPackages (ps: [ ps.opencv4 ps.numpy ps.img2pdf ]);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "photo2scan";
  version = "0.1.0";

  src = ./photo2scan.py;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/share/photo2scan/photo2scan.py
    makeWrapper ${lib.getExe python} $out/bin/photo2scan \
      --add-flags $out/share/photo2scan/photo2scan.py
    runHook postInstall
  '';

  meta = {
    description = "Turn phone photos of paper pages into a straightened, scanned-looking PDF";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "photo2scan";
  };
})
