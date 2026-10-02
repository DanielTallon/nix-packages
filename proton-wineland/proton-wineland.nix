{
  lib,
  stdenvNoCC,
  fetchzip,
  # "x86_64_v3" needs a CPU with AVX2; "x86_64" runs everywhere.
  variant ? "x86_64_v3",
  # Fixed name Steam sees, so per-game compatibility tool choices survive updates.
  steamDisplayName ? "Proton-Wineland",
}:

let
  sources = lib.importJSON ./sources.json;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "proton-wineland";
  inherit (sources) version;

  src = fetchzip {
    url = "https://github.com/nanomatters/proton-cachyos/releases/download/wineland-${finalAttrs.version}/proton-wineland-${finalAttrs.version}-${variant}.tar.xz";
    hash = sources.hashes.${variant};
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  outputs = [
    "out"
    "steamcompattool"
  ];

  installPhase = ''
    runHook preInstall

    # Not meant for environment.systemPackages; consumed via programs.steam.extraCompatPackages.
    echo "${finalAttrs.pname} should not be installed into environments. Use programs.steam.extraCompatPackages instead." > $out

    mkdir $steamcompattool
    ln -s $src/* $steamcompattool
    # Real copy of the manifest so its tool name can be rewritten below.
    rm $steamcompattool/compatibilitytool.vdf
    cp $src/compatibilitytool.vdf $steamcompattool

    runHook postInstall
  '';

  preFixup = ''
    # Both the internal name and display_name use the versioned string; replace it with a
    # fixed one so Steam doesn't drop the game's tool selection on every update.
    substituteInPlace "$steamcompattool/compatibilitytool.vdf" \
      --replace-fail "proton-wineland-${finalAttrs.version}-${variant}" "${steamDisplayName}"
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Proton Wineland (Wayland-focused Proton fork from nanomatters/proton-cachyos), packaged for programs.steam.extraCompatPackages";
    homepage = "https://github.com/nanomatters/proton-cachyos";
    license = lib.licenses.bsd3;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
