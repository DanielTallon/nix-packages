{ lib, stdenvNoCC, fetchFromGitLab, makeWrapper, quickshell, qt6, matugen, ffmpeg, curl, python3, coreutils, ...}:

# Upstream is a Quickshell config folder meant to live (writable) in
# ~/.config/kwepaperpicker. Here it lives read-only in the store and is run
# with `qs -p`; the two files it writes at runtime (its settings and the
# matugen colour scheme) are moved to ~/.config/kwepaperpicker instead, the
# same place upstream's install.sh would put them, so existing settings and
# matugen templates keep working.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "qs-kwepaperpicker";
  version = "0-unstable-2026-10-15";

  src = fetchFromGitLab {
    owner = "theblackdon";
    repo = "qs-kwepaperpicker";
    rev = "b95c0aa44ae3d83f94bd282fb3a3bee328cc932d";
    hash = "sha256-uqlMJOZTsKTXxbJQZRZEGWbk8vawHnkMucDl9qiicNg=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  postPatch = ''
    substituteInPlace settings/SettingsConfig.qml \
      --replace-fail 'Quickshell.shellPath("settings.json")' \
                     'Quickshell.env("KWEPAPERPICKER_STATE") + "/settings.json"'
    substituteInPlace colors/Colors.qml \
      --replace-fail 'Quickshell.shellPath("colors/Colors.json")' \
                     'Quickshell.env("KWEPAPERPICKER_STATE") + "/colors/Colors.json"'

    # The launcher: run the store copy, and make sure the state dir exists.
    substituteInPlace bin/kwepaperpicker \
      --replace-fail 'cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/kwepaperpicker"' \
                     'cfg="@out@/share/kwepaperpicker"
export KWEPAPERPICKER_STATE="''${XDG_CONFIG_HOME:-$HOME/.config}/kwepaperpicker"
mkdir -p "$KWEPAPERPICKER_STATE/colors"' \
      --replace-fail '(run its install.sh)' '(broken package)'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kwepaperpicker $out/bin
    cp -r colors components extras modules scripts services settings shaders shell.qml \
      $out/share/kwepaperpicker/
    install -Dm755 bin/kwepaperpicker $out/bin/kwepaperpicker
    substituteInPlace $out/bin/kwepaperpicker --subst-var out

    runHook postInstall
  '';

  # qs inherits this environment, and so do the scripts it runs. nixpkgs'
  # quickshell has no Qt Multimedia (video wallpapers) or image formats
  # (WebP), so those are added here.
  postFixup = ''
    wrapProgram $out/bin/kwepaperpicker \
      --prefix PATH : ${lib.makeBinPath [ quickshell matugen ffmpeg curl python3 coreutils ]} \
      --prefix QML_IMPORT_PATH : ${qt6.qtmultimedia}/${qt6.qtbase.qtQmlPrefix} \
      --prefix QT_PLUGIN_PATH : ${qt6.qtmultimedia}/${qt6.qtbase.qtPluginPrefix} \
      --prefix QT_PLUGIN_PATH : ${qt6.qtimageformats}/${qt6.qtbase.qtPluginPrefix}
  '';

  meta = {
    description = "Swatch-deck wallpaper picker for Quickshell";
    homepage = "https://gitlab.com/theblackdon/qs-kwepaperpicker";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "kwepaperpicker";
  };
})
