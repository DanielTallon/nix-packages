# nixos-chase: a Plymouth boot splash of the official NixOS logo, with a light
# chasing around the snowflake's six lambdas. Optional glitch bursts (glitch > 0).
#
# Install (NixOS):
#   boot.plymouth = {
#     enable = true;
#     theme = "nixos-chase";        # or "nixos-chase-glitch"
#     themePackages = [ nix-packages.packages.${pkgs.stdenv.hostPlatform.system}.plymouth-nixos-chase ];
#   };
#
# Tweak with .override { settings = { … }; } (any of these; the rest keep their defaults):
#   steps:  frames per lambda (6 lambdas, so 6 * steps frames per turn)
#   ticks:  Plymouth refreshes (50 Hz) per frame; one turn = 6 * steps * ticks / 50 s
#   trail:  how many lambdas behind the lit one still glow
#   dim:    brightness of an unlit lambda, 0 to 1
#   height: logo height in pixels, drawn 1:1 (400 is ~37% of 1080p, ~28% of 1440p)
#   glitch: 0 = off; N = loop N turns of the chase with a glitch burst near the end
#
# `.videos` renders the same animation as video files (1080p MP4, lossless 1080p
# WebM, Steam Deck 1280x800 WebM), smoother than the boot splash (30 fps).
{
  lib,
  stdenvNoCC,
  fetchurl,
  python3,
  resvg,
  optipng,
  ffmpeg-headless,
  # One attrset rather than separate arguments: callPackage would fill `dim`
  # (and other names) with nixpkgs packages of that name.
  settings ? { },
}:
let
  inherit (lib.recursiveUpdate {
    steps = 4;
    ticks = 4;
    trail = 2;
    dim = 0.3;
    height = 400;
    glitch = 0;
  } settings) steps ticks trail dim height glitch;
  name = "nixos-chase" + lib.optionalString (glitch > 0) "-glitch";

  # "NixOS Logo" by Simon Frankau, Tim Cuthbertson and Daniel Baker, from
  # github.com/NixOS/branding, CC BY 4.0. Logomark + wordmark, white text.
  logo = fetchurl {
    url = "https://github.com/NixOS/branding/releases/download/nixos-branding-guide-v0.2.0/nixos-logo-default-gradient-white-regular-vertical-minimal.svg";
    hash = "sha256-jHlVDGJtVs+VcyXvoT6XKiuFO6TdKu5y4VFXAkHfCWs=";
  };

  python = python3.withPackages (ps: [ ps.pillow ]);

  # Shell commands that leave frames/frame-1.png … frame-N.png.
  #   hold: frames each glitch burst step lasts (keeps bursts as long at higher fps)
  makeFrames = { steps, height, hold ? 1 }: ''
    python3 -I ${./logo-chase.py} ${logo} frames ${toString steps} ${toString trail} ${toString dim}
    for f in frames/*.svg; do
      resvg --height ${toString height} "$f" "''${f%.svg}.png"
    done
    rm frames/*.svg
  '' + lib.optionalString (glitch > 0) ''
    python3 -I ${./logo-glitch.py} frames glitched ${toString glitch} ${toString hold}
    rm -r frames
    mv glitched frames
  '';

  # Video: 30 fps, 2 s per turn (10 frames per lambda), same look as the splash.
  videos = stdenvNoCC.mkDerivation {
    pname = "${name}-videos";
    version = "1.0";
    src = logo;
    dontUnpack = true;
    nativeBuildInputs = [ python resvg ffmpeg-headless ];
    buildPhase = ''
      # render <logo height> <width> <height> <crf, or "lossless"> <output>
      render() {
        rm -rf frames
        ${makeFrames { steps = 10; height = "$1"; hold = 3; }}
        n=$(ls frames | wc -l)
        # Loop to ~6 s, whole turns only.
        loops=$(( (180 + n - 1) / n ))
        if [ "$4" = lossless ]; then
          # Full color resolution (4:4:4), so nothing at all is lost
          codec=(-c:v libvpx-vp9 -lossless 1 -row-mt 1); pixfmt=yuv444p
        elif [[ "$5" == *.webm ]]; then
          codec=(-c:v libvpx-vp9 -crf "$4" -b:v 0 -row-mt 1); pixfmt=yuv420p
        else
          codec=(-c:v libx264 -crf "$4" -preset slow -movflags +faststart); pixfmt=yuv420p
        fi
        ffmpeg -loglevel error -stream_loop $((loops - 1)) -framerate 30 -i frames/frame-%d.png \
          -f lavfi -i "color=black:s=$2x$3:r=30" \
          -filter_complex "[1][0]overlay=(W-w)/2:(H-h)/2:shortest=1,format=$pixfmt" \
          -an "''${codec[@]}" "$5"
      }
      mkdir -p $out
      render 400 1920 1080 14 $out/${name}-1080p.mp4
      render 400 1920 1080 lossless $out/${name}-1080p-lossless.webm
      render 300 1280 800 18 $out/${name}-steamdeck.webm
    '';
    dontInstall = true;
  };
in
stdenvNoCC.mkDerivation {
  pname = "plymouth-theme-${name}";
  version = "1.0";
  src = logo;
  dontUnpack = true;

  nativeBuildInputs = [ python resvg optipng ];

  buildPhase = ''
    ${makeFrames { inherit steps height; }}
    optipng -quiet -o1 frames/*.png
  '';

  installPhase = ''
    themedir=$out/share/plymouth/themes/${name}
    mkdir -p "$themedir"
    cp frames/frame-*.png "$themedir/"
    frame_count=$(ls frames/*.png | wc -l)

    sed -e "s/FRAME_COUNT_PLACEHOLDER/$frame_count/" \
        -e "s/TICKS_PER_FRAME_PLACEHOLDER/${toString ticks}/" \
        ${./nixos-chase.script} > "$themedir/${name}.script"

    cat > "$themedir/${name}.plymouth" <<EOF
    [Plymouth Theme]
    Name=${name}
    Description=NixOS logo with a light chasing around the snowflake
    ModuleName=script

    [script]
    ImageDir=$themedir
    ScriptFile=$themedir/${name}.script
    EOF

    install -Dm644 ${./LICENSE-MIT} $out/share/doc/${name}/LICENSE-MIT
  '';

  passthru = { inherit videos; };

  meta = {
    description = "Plymouth boot splash: the NixOS logo with a light chasing around the snowflake";
    homepage = "https://github.com/DanielTallon/nix-packages/tree/main/plymouth-nixos-chase";
    # Scripts: MIT. Logo artwork: CC BY 4.0 (NixOS branding), adapted (animated brightness).
    license = with lib.licenses; [ mit cc-by-40 ];
    platforms = lib.platforms.linux;
  };
}
