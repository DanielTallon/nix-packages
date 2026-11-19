{ lib, stdenvNoCC, makeWrapper, bash, jq, fzf, coreutils, gnused, gawk, gnugrep, util-linux }:

# nti.sh sits next to this file. Nix itself is not wrapped in: nti uses the
# nix already installed (NixOS or the Nix installer), so it talks to the same
# daemon and the same user profile you do.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nti";
  version = "0.2.1";

  src = ./nti.sh;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/libexec/nti/nti
    substituteInPlace $out/libexec/nti/nti --subst-var-by version ${finalAttrs.version}
    patchShebangs $out/libexec/nti/nti
    makeWrapper $out/libexec/nti/nti $out/bin/nti \
      --prefix PATH : ${lib.makeBinPath [ bash jq fzf coreutils gnused gawk gnugrep util-linux ]}
    runHook postInstall
  '';

  meta = {
    description = "Nix Temporary Install: try programs from nixpkgs without a rebuild, kept in a list you can edit";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "nti";
  };
})
