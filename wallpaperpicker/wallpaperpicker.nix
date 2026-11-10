{ lib, stdenvNoCC, fetchFromGitLab, makeWrapper, writeText, quickshell, qt6, matugen, ffmpeg, curl, python3, coreutils, material-symbols, ...}:

# Upstream is qs-kwepaperpicker, a Quickshell config folder meant to live
# (writable) in ~/.config/kwepaperpicker. Here it is renamed wallpaperpicker,
# lives read-only in the store and is run with `qs -p`; the two files it
# writes at runtime (its settings and the matugen colour scheme) are moved to
# ~/.config/wallpaperpicker instead. An existing ~/.config/kwepaperpicker
# (from upstream's install.sh or an older build of this package) is moved
# there on first run, so existing settings carry over.
let
  # The system's fonts plus Material Symbols (the picker's icons), so the
  # icon font needn't be installed system-wide.
  fontsConf = writeText "wallpaperpicker-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
      <dir>${material-symbols}/share/fonts</dir>
    </fontconfig>
  '';

  # matugen's scheme type: how bold the colors are. Every option is described
  # at the top of the dotfiles' modules/desktop/wallpaper-colors.nix, which
  # has its own matugenScheme for the login re-apply: keep the two the same.
  matugenScheme = "scheme-vibrant";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wallpaperpicker";
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
                     'Quickshell.env("WALLPAPERPICKER_STATE") + "/settings.json"'

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

    # settings.json is shared by every session, so a Plasma command saved
    # there would also run outside Plasma (e.g. under Niri), where it fails
    # and the wallpaper never changes. Outside Plasma, ignore it and draw
    # the wallpaper with Quickshell instead.
    substituteInPlace services/WallpaperEngine.qml \
      --replace-fail 'readonly property string command: SettingsConfig.wallpaperCommand.trim()' \
                     'readonly property string savedCommand: SettingsConfig.wallpaperCommand.trim()
    readonly property string command: !SettingsConfig.plasma && savedCommand.startsWith("plasma-apply-wallpaperimage") ? "" : savedCommand'

    # matugenScheme instead of matugen's default (tonal spot), which mutes the
    # wallpaper's colors. Both the scheme the desktop gets and the dry runs
    # the swatch cards are dressed in use it, so the cards still show what
    # each wallpaper will set. The palette cache's version names the scheme,
    # so changing it makes the picker read every wallpaper again.
    substituteInPlace scripts/wallpaper-apply \
      --replace-fail 'matugen image "$still" --source-color-index 0' \
                     'matugen image "$still" --type ${matugenScheme} --source-color-index 0'
    substituteInPlace scripts/wallpaper-palettes.py \
      --replace-fail '"--source-color-index", "0", "--dry-run"' \
                     '"--type", "${matugenScheme}", "--source-color-index", "0", "--dry-run"'
    substituteInPlace services/WallpaperSwatches.qml \
      --replace-fail 'JSON.stringify({ version: 1,' 'JSON.stringify({ version: "1-${matugenScheme}",' \
      --replace-fail 'd.version === 1' 'd.version === "1-${matugenScheme}"'

    substituteInPlace colors/Colors.qml \
      --replace-fail 'Quickshell.shellPath("colors/Colors.json")' \
                     'Quickshell.env("WALLPAPERPICKER_STATE") + "/colors/Colors.json"'

    # The launcher: its usage text and messages under the new name.
    substituteInPlace bin/kwepaperpicker \
      --replace-fail 'kwepaperpicker' 'wallpaperpicker'

    # Run the store copy, and make sure the state dir exists (moving the old
    # kwepaperpicker one over if that's all there is).
    # Quickshell finds a running instance by its config path, and the store
    # path changes with every update, so the picker is run through a symlink
    # that `start` points at this build: `toggle` from a newer build still
    # reaches the instance started by an older one.
    # `toggle` and `wallhaven` start the picker in the background first if it
    # isn't running (no autostart, `stop`ped, or killed), so a key binding
    # always works and never needs a terminal left open.
    substituteInPlace bin/kwepaperpicker \
      --replace-fail 'cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/wallpaperpicker"' \
                     'cfg="@out@/share/wallpaperpicker"
export WALLPAPERPICKER_STATE="''${XDG_CONFIG_HOME:-$HOME/.config}/wallpaperpicker"
old="''${XDG_CONFIG_HOME:-$HOME/.config}/kwepaperpicker"
[[ -d $old && ! -e $WALLPAPERPICKER_STATE ]] && mv "$old" "$WALLPAPERPICKER_STATE"
mkdir -p "$WALLPAPERPICKER_STATE/colors"
link="''${XDG_STATE_HOME:-$HOME/.local/state}/wallpaperpicker/shell"
ready() { qs -p "$link" ipc show 2>/dev/null | grep -q "^target wallpaper"; }
ensure() {
    [[ -e $link ]] && ready && return
    mkdir -p "''${link%/*}"; ln -sfn "$cfg" "$link"
    qs -p "$link" --no-duplicate --daemonize >/dev/null 2>&1 || true
    for _ in {1..100}; do ready && return; sleep 0.1; done
}' \
      --replace-fail 'start)     exec qs -p "$cfg" --no-duplicate ;;' \
                     'start)     mkdir -p "''${link%/*}"; ln -sfn "$cfg" "$link"
               exec qs -p "$link" --no-duplicate ;;' \
      --replace-fail 'toggle)    exec' 'toggle)    ensure; exec' \
      --replace-fail 'wallhaven) exec' 'wallhaven) ensure; exec' \
      --replace-fail 'qs -p "$cfg"' 'qs -p "$link"' \
      --replace-fail '(run its install.sh)' '(broken package)'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/wallpaperpicker $out/bin
    cp -r colors components extras modules scripts services settings shaders shell.qml \
      $out/share/wallpaperpicker/
    install -Dm755 bin/kwepaperpicker $out/bin/wallpaperpicker
    substituteInPlace $out/bin/wallpaperpicker --subst-var out

    runHook postInstall
  '';

  # qs inherits this environment, and so do the scripts it runs. nixpkgs'
  # quickshell has no Qt Multimedia (video wallpapers) or image formats
  # (WebP), so those are added here.
  postFixup = ''
    wrapProgram $out/bin/wallpaperpicker \
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
    mainProgram = "wallpaperpicker";
  };
})
