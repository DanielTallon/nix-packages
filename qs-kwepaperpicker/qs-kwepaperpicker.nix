{ lib, stdenvNoCC, fetchFromGitLab, makeWrapper, writeText, quickshell, qt6, matugen, ffmpeg, curl, python3, coreutils, material-symbols, ...}:

# Upstream is a Quickshell config folder meant to live (writable) in
# ~/.config/kwepaperpicker. Here it lives read-only in the store and is run
# with `qs -p`; the two files it writes at runtime (its settings and the
# matugen colour scheme) are moved to ~/.config/kwepaperpicker instead, the
# same place upstream's install.sh would put them, so existing settings and
# matugen templates keep working.
let
  # The system's fonts plus Material Symbols (the picker's icons), so the
  # icon font needn't be installed system-wide.
  fontsConf = writeText "kwepaperpicker-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
      <dir>${material-symbols}/share/fonts</dir>
    </fontconfig>
  '';
in
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

    # On Plasma, default to letting Plasma set the wallpaper (as upstream does
    # for KineticWE) instead of drawing a second background over the desktop.
    # Only the default: a command saved in settings.json still wins.
    substituteInPlace settings/SettingsConfig.qml \
      --replace-fail 'readonly property string kineticweCommand: "noctalia-kwe msg wallpaper-set {}"' \
                     'readonly property string kineticweCommand: "noctalia-kwe msg wallpaper-set {}"
    readonly property bool plasma: (Quickshell.env("XDG_CURRENT_DESKTOP") ?? "").split(":").includes("KDE")
    readonly property string plasmaCommand: "plasma-apply-wallpaperimage {}"' \
      --replace-fail 'property string wallpaperCommand: root.kineticwe ? root.kineticweCommand : ""' \
                     'property string wallpaperCommand: root.kineticwe ? root.kineticweCommand : root.plasma ? root.plasmaCommand : ""'

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
      --set FONTCONFIG_FILE ${fontsConf} \
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
