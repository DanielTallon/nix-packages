# Home Manager module for wallpaperpicker: the package, a login autostart,
# a Plasma shortcut, and matugen colors from the wallpaper (the picker's own
# UI, and optionally a whole Plasma color scheme). The same setup as my
# dotfiles (modules/desktop/plasma.nix and wallpaper-colors.nix), for any
# distro with Home Manager. Exposed as homeModules.wallpaperpicker; see the
# README and ./home-template for a ready-made flake.
#
# The shortcut and the Plasma color scheme need plasma-manager's module
# imported too. Everything else works on any desktop the picker runs on.
{ self }:
{ config, lib, pkgs, options, ... }:
let
  cfg = config.programs.wallpaperpicker;
  system = pkgs.stdenv.hostPlatform.system;

  # This flake's build. matugen's template and scheme come from it even when
  # `package` is some other build.
  picker = self.packages.${system}.wallpaperpicker;
  matugenScheme = picker.matugenScheme;

  hasPlasmaManager = options ? programs.plasma.hotkeys;
  usesPlasma = cfg.hotkey != null || cfg.matugen.plasmaColorScheme;

  # What's installed and run: the package, through nixGL if asked.
  installed = if cfg.nixGL then config.lib.nixGL.wrap cfg.package else cfg.package;
  exe = "${installed}/bin/wallpaperpicker";

  schemeDir = "${config.xdg.dataHome}/color-schemes";
  kwriteconfig = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
  kreadconfig = "${pkgs.kdePackages.kconfig}/bin/kreadconfig6";
  applyColorScheme = "${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-colorscheme";

  # A matugen color role as KDE writes colors ("r,g,b").
  c = role: "{{colors.${role}.default.red}},{{colors.${role}.default.green}},{{colors.${role}.default.blue}}";

  # One [Colors:*] group. The negative/neutral/positive colors are Breeze
  # Dark's, so errors and warnings still look like errors and warnings.
  colorGroup = name: bg: alt: ''
    [Colors:${name}]
    BackgroundNormal=${c bg}
    BackgroundAlternate=${c alt}
    DecorationFocus=${c "primary"}
    DecorationHover=${c "primary"}
    ForegroundNormal=${c "on_surface"}
    ForegroundInactive=${c "on_surface_variant"}
    ForegroundActive=${c "primary"}
    ForegroundLink=${c "primary"}
    ForegroundVisited=${c "tertiary"}
    ForegroundNegative=218,68,83
    ForegroundNeutral=246,116,0
    ForegroundPositive=39,174,96
  '';

  # A Plasma color scheme in matugen's template syntax, laid out like
  # Breeze Dark (ColorEffects copied from it). Always dark.
  kdeTemplate = pkgs.writeText "matugen-kde.colors" ''
    [ColorEffects:Disabled]
    Color=56,56,56
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.65
    ContrastEffect=1
    IntensityAmount=0.1
    IntensityEffect=2

    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=112,111,110
    ColorAmount=0.025
    ColorEffect=2
    ContrastAmount=0.1
    ContrastEffect=2
    Enable=false
    IntensityAmount=0
    IntensityEffect=0

    ${colorGroup "Window" "surface_container" "surface_container_high"}
    ${colorGroup "View" "surface" "surface_container_low"}
    ${colorGroup "Button" "surface_container_high" "surface_container_highest"}
    ${colorGroup "Header" "surface_container" "surface_container_low"}
    ${colorGroup "Header][Inactive" "surface_container_low" "surface_container"}
    ${colorGroup "Tooltip" "surface_container_highest" "surface_container_high"}
    ${colorGroup "Complementary" "surface_container_lowest" "surface_container"}
    [Colors:Selection]
    BackgroundNormal=${c "primary"}
    BackgroundAlternate=${c "primary_container"}
    DecorationFocus=${c "primary"}
    DecorationHover=${c "primary"}
    ForegroundNormal=${c "on_primary"}
    ForegroundInactive=${c "on_primary"}
    ForegroundActive=${c "on_primary"}
    ForegroundLink=${c "on_primary"}
    ForegroundVisited=${c "on_primary"}
    ForegroundNegative=176,55,69
    ForegroundNeutral=198,92,0
    ForegroundPositive=23,104,57

    [General]
    ColorScheme=Matugen
    Name=Matugen

    [KDE]
    contrast=4

    [WM]
    activeBackground=${c "surface_container"}
    activeBlend=${c "on_surface"}
    activeForeground=${c "on_surface"}
    inactiveBackground=${c "surface_container_low"}
    inactiveBlend=${c "on_surface_variant"}
    inactiveForeground=${c "on_surface_variant"}
  '';

  # plasma-apply-colorscheme does nothing when asked for the scheme that's
  # already in use, even if its file has changed, so take turns between
  # Matugen and a copy of it named MatugenAlt.
  applyMatugenScheme = pkgs.writeShellScript "apply-matugen-colorscheme" ''
    if [[ $(${kreadconfig} --file kdeglobals --group General --key ColorScheme) == Matugen ]]; then
      ${pkgs.gnused}/bin/sed -e 's/^ColorScheme=Matugen$/ColorScheme=MatugenAlt/' \
        -e 's/^Name=Matugen$/Name=Matugen (alt)/' \
        "${schemeDir}/Matugen.colors" > "${schemeDir}/MatugenAlt.colors"
      exec ${applyColorScheme} MatugenAlt
    fi
    exec ${applyColorScheme} Matugen
  '';
in
{
  options.programs.wallpaperpicker = {
    enable = lib.mkEnableOption "wallpaperpicker, a swatch-deck wallpaper picker for Quickshell";

    package = lib.mkOption {
      type = lib.types.package;
      default = picker;
      defaultText = lib.literalExpression "nix-packages.packages.\${system}.wallpaperpicker";
      description = "The picker to install.";
    };

    nixGL = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the picker through nixGL, with Home Manager's
        `targets.genericLinux.nixGL` (set that up too). Needed on distros
        other than NixOS, where programs from Nix can't find the graphics
        drivers otherwise and the picker never appears. Leave it off on NixOS.
      '';
    };

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the picker in the background on login (an XDG autostart entry).";
    };

    hotkey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Meta+Space";
      description = ''
        A Plasma shortcut that opens and closes the picker
        (`wallpaperpicker toggle`). Needs plasma-manager. On other desktops,
        bind `wallpaperpicker toggle` to a key in the desktop's own config.
      '';
    };

    matugen = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Color the picker's own UI from the wallpaper. The picker runs
          matugen on every wallpaper it sets; this writes the matugen config
          (~/.config/matugen/config.toml) that tells it where the picker's
          colors go. Replaces any matugen config you already have.
        '';
      };

      plasmaColorScheme = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Also make a whole dark Plasma color scheme ("Matugen") from each
          wallpaper and apply it: windows, buttons, headers, selection and
          title bars. Turns off Plasma's own accent color from wallpaper.
          Needs plasma-manager, and matugen.enable.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = usesPlasma -> hasPlasmaManager;
          message = "programs.wallpaperpicker.hotkey and .matugen.plasmaColorScheme need plasma-manager's Home Manager module imported.";
        }
        {
          assertion = cfg.matugen.plasmaColorScheme -> cfg.matugen.enable;
          message = "programs.wallpaperpicker.matugen.plasmaColorScheme needs programs.wallpaperpicker.matugen.enable.";
        }
      ];

      home.packages = [ installed ];

      xdg.configFile."autostart/wallpaperpicker.desktop" = lib.mkIf cfg.autostart {
        text = ''
          [Desktop Entry]
          Type=Application
          Name=wallpaperpicker
          Exec=${exe}
          Icon=preferences-desktop-wallpaper
        '';
      };

      xdg.configFile."matugen/config.toml" = lib.mkIf cfg.matugen.enable {
        text = ''
          [config]

          [templates.wallpaperpicker]
          input_path = "${picker}/share/wallpaperpicker/extras/matugen/quickshell.json.hbs"
          output_path = "${config.xdg.configHome}/wallpaperpicker/colors/Colors.json"
        '' + lib.optionalString cfg.matugen.plasmaColorScheme ''

          [templates.plasma]
          input_path = "${kdeTemplate}"
          output_path = "${schemeDir}/Matugen.colors"
          post_hook = "${applyMatugenScheme}"
        '';
      };
    }

    # Only defined with plasma-manager imported, so the module also loads
    # without it (the assertion above explains if it's needed).
    (lib.optionalAttrs hasPlasmaManager (lib.mkMerge [
      (lib.mkIf usesPlasma { programs.plasma.enable = lib.mkDefault true; })

      (lib.mkIf (cfg.hotkey != null) {
        programs.plasma.hotkeys.commands."wallpaperpicker" = {
          name = "Wallpaper picker";
          key = cfg.hotkey;
          command = "${exe} toggle";
        };
      })

      (lib.mkIf cfg.matugen.plasmaColorScheme {
        programs.plasma.configFile."kdeglobals".General.accentColorFromWallpaper = false;

        # Runs once at the first login after a switch that changes it, after
        # plasma-manager's own theme script.
        programs.plasma.startup.startupScript."wallpaperpicker-colors" = {
          priority = 2;
          text = ''
            # A leftover wallpaper accent would tint the scheme's own highlight.
            ${kwriteconfig} --file kdeglobals --group General --key AccentColor --delete
            # The current wallpaper's scheme now, rather than at the next one picked.
            if [ -e "$HOME/.cache/current_wallpaper" ]; then
              ${pkgs.matugen}/bin/matugen image "$HOME/.cache/current_wallpaper" --type ${matugenScheme} --source-color-index 0
            fi
          '';
        };
      })
    ]))
  ]);
}
