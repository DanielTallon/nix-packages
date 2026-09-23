{ lib, stdenvNoCC, makeWrapper, jq, fzf, coreutils, gnused, gawk, util-linux
}:

stdenvNoCC.mkDerivation {
  pname = "boot-gardener";
  version = "2.5.1";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin $out/libexec/boot-gardener
    install -m755 boot-backend.sh $out/libexec/boot-gardener/boot-backend.sh
    install -m755 gardener.sh $out/libexec/boot-gardener/gardener.sh
    install -m755 rescue.sh $out/libexec/boot-gardener/rescue.sh
    install -m755 boot-gardener $out/bin/boot-gardener

    wrapProgram $out/bin/boot-gardener \
      --prefix PATH : ${lib.makeBinPath [ jq fzf coreutils gnused gawk util-linux ]}
  '';

  meta = with lib; {
    description = "Pick, pin, prune, harvest, or garbage-collect NixOS generations in your Limine, systemd-boot, or GRUB boot menu, or rescue a full /boot partition";
    platforms = platforms.linux;
    mainProgram = "boot-gardener";
  };
}
