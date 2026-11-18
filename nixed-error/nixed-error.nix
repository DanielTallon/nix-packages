{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  git,
}:

stdenvNoCC.mkDerivation {
  pname = "nixed-error";
  version = "0.1.0";

  # Only the tool and its rules; tests, docs and fixtures stay out of the build.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./nixed_error.py
      ./rules.toml
    ];
  };

  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    # The script looks for rules.toml next to itself.
    install -Dm644 nixed_error.py $out/share/nixed-error/nixed_error.py
    install -Dm644 rules.toml $out/share/nixed-error/rules.toml

    # nix, systemctl and journalctl come from the running system. git is only a
    # fallback (--suffix), since a fresh NixOS install doesn't ship it.
    # NIXED_ERROR_RUN is how to call it when it isn't installed, for the "pipe it in" hint.
    makeWrapper ${python3.interpreter} $out/bin/nixed-error \
      --add-flags $out/share/nixed-error/nixed_error.py \
      --set-default NIXED_ERROR_RUN 'nix run --extra-experimental-features "nix-command flakes" github:DanielTallon/nix-packages#nixed-error' \
      --suffix PATH : ${lib.makeBinPath [ git ]}

    runHook postInstall
  '';

  meta = {
    description = "Explain failed NixOS rebuilds in plain words";
    platforms = lib.platforms.linux;
    mainProgram = "nixed-error";
  };
}
