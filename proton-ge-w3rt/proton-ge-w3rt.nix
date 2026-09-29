{ lib, stdenvNoCC, fetchzip, vkd3d-proton-w3rt }:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "proton-ge-w3rt";
  version = "GE-Proton11-7"; # must match the vkd3d-proton commit in vkd3d-proton-w3rt

  src = fetchzip {
	url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${finalAttrs.version}/${finalAttrs.version}-x86_64.tar.gz";
    hash = "sha256-ftW0vE45v2JsbaYqo/So0ZFfvdtakHX0XEXEE4TdxLk=";

  };

  outputs = [ "out" "steamcompattool" ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # Same convention as nixpkgs proton-ge-bin: `out` is a stub, the tool lives in `steamcompattool`
    echo "Use programs.steam.extraCompatPackages, not environment packages." > $out

    mkdir -p $steamcompattool
    cp -a $src/. $steamcompattool/
    chmod -R u+w $steamcompattool

    # Swap in the patched vkd3d-proton
    install -m644 ${vkd3d-proton-w3rt}/bin/d3d12.dll ${vkd3d-proton-w3rt}/bin/d3d12core.dll \
      $steamcompattool/files/lib/wine/vkd3d-proton/x86_64-windows/

    # Own Steam identity, so it never collides with a stock GE-Proton11-7
       sed -i -E 's/"${finalAttrs.version}[^"]*"/"${finalAttrs.version}-rt"/g' $steamcompattool/compatibilitytool.vdf
       grep -q '"${finalAttrs.version}-rt"' $steamcompattool/compatibilitytool.vdf \
      || { echo "compatibilitytool.vdf rename failed"; exit 1; }

    # Unique version string, so Proton refreshes the game prefix's DLLs when this changes
    ts=$(cut -d' ' -f1 $steamcompattool/version)
    echo "$ts ${finalAttrs.version}-rt-${vkd3d-proton-w3rt.version}" > $steamcompattool/version

    runHook postInstall
  '';

  meta = {
    description = "GE-Proton11-7 with patched vkd3d-proton for Witcher 3 ray tracing on NVIDIA 590+";
    homepage = "https://github.com/GloriousEggroll/proton-ge-custom";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
})
