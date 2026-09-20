{ lib, stdenvNoCC, makeWrapper, jq, fzf, coreutils, gnused, gawk, util-linux
}:

stdenvNoCC.mkDerivation {
  pname = "limine-gardener";
  version = "1.2.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin $out/libexec/limine-gardener
    install -m755 limine-pin-picker.sh $out/libexec/limine-gardener/limine-pin-picker.sh
    install -m755 limine-boot-rescue.sh $out/libexec/limine-gardener/limine-boot-rescue.sh
    install -m755 limine-gardener $out/bin/limine-gardener

    wrapProgram $out/bin/limine-gardener \
      --prefix PATH : ${lib.makeBinPath [ jq fzf coreutils gnused gawk util-linux ]}
  '';

  meta = with lib; {
    description = "Pick, pin, harvest, or garbage-collect NixOS generations in your Limine boot menu, or rescue a full /boot partition";
    platforms = platforms.linux;
    mainProgram = "limine-gardener";
  };
}
