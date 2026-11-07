# Brave Origin: Brave with Rewards, Wallet, VPN, Leo AI, News, Tor and the
# telemetry pings taken out, keeping Shields. Free on Linux.
#
# Repackages the .deb from Brave's own apt repo. Adapted from the nixpkgs
# `brave-origin` package, which was removed in November 2026 for lack of a
# maintainer with commit access. The version and hashes live in
# sources.json, which update.sh (run daily by
# .github/workflows/update-brave-origin.yml) keeps current.
#
# Policies: Brave reads /etc/brave/policies/managed/*.json. The NixOS
# programs.chromium module no longer writes there, so set
# environment.etc."brave/policies/managed/<name>.json" yourself.
{
  lib,
  stdenv,
  fetchurl,
  buildPackages,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dpkg,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  qt6,
  libx11,
  libxscrnsaver,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxtst,
  libdrm,
  libkrb5,
  libuuid,
  libxkbcommon,
  libxshmfence,
  libgbm,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  snappy,
  speechd-minimal,
  udev,
  wayland,
  xdg-utils,
  coreutils,
  libxcb,
  vulkan-loader,
  zlib,
  libpulseaudio,
  libGL,
  libva,
  # Flags always passed to the browser, e.g. "--password-store=kwallet6".
  commandLineArgs ? "",
  # Video acceleration via VA-API.
  enableVideoAcceleration ? true,
  # Vulkan (--enable-features=Vulkan); off by default as it tends to break VA-API.
  enableVulkan ? false,
}:

let
  sources = lib.importJSON ./sources.json;

  debArch = {
    x86_64-linux = "amd64";
    aarch64-linux = "arm64";
  };

  # Paths inside the .deb.
  optDir = "opt/brave.com/brave-origin";
  fileBase = "brave-origin";
  appId = "com.brave.Origin";

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    gtk4
    libdrm
    libx11
    libGL
    libxkbcommon
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxshmfence
    libxtst
    libuuid
    libgbm
    nspr
    nss
    pango
    pciutils # ANGLE dlopens libpci to identify GPUs, including for VA-API.
    pipewire
    udev
    wayland
    libxcb
    zlib
    snappy
    speechd-minimal # Text-to-speech via speech-dispatcher.
    libkrb5
    vulkan-loader # Chromium and Dawn dlopen libvulkan.so.1 by name.
    qt6.qtbase
    libpulseaudio # USB audio devices.
    libva
  ];

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;

  enableFeatures =
    lib.optionals enableVideoAcceleration [
      "AcceleratedVideoDecodeLinuxGL"
      "AcceleratedVideoEncoder"
    ]
    ++ lib.optional enableVulkan "Vulkan";

  disableFeatures = [
    # Nix handles updates; don't nag about an "outdated" build.
    "OutdatedBuildDetector"
  ]
  # Needed for VA-API: https://github.com/brave/brave-browser/issues/20935
  ++ lib.optional enableVideoAcceleration "UseChromeOSDirectVideoDecoder";

  system = stdenv.hostPlatform.system;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "brave-origin";
  inherit (sources) version;

  __structuredAttrs = true;
  strictDeps = true;

  src =
    assert lib.assertMsg (debArch ? ${system}) "brave-origin is not available for ${system}";
    fetchurl {
      url = "https://brave-browser-apt-release.s3.brave.com/pool/main/b/brave-origin/brave-origin_${finalAttrs.version}_${debArch.${system}}.deb";
      hash = sources.hashes.${system};
    };

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  doInstallCheck = true;

  nativeBuildInputs = [
    dpkg
    # override doesn't preserve splicing: https://github.com/NixOS/nixpkgs/issues/132651
    (buildPackages.wrapGAppsHook3.override { makeWrapper = buildPackages.makeShellWrapper; })
  ];

  buildInputs = [
    # GSETTINGS_SCHEMAS_PATH
    glib
    gsettings-desktop-schemas
    gtk3
    gtk4
    # XDG_ICON_DIRS
    adwaita-icon-theme
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp -R usr/share $out
    cp -R opt $out/opt

    wrapper=$out/${optDir}/${fileBase}
    substituteInPlace $wrapper \
      --replace-fail /bin/bash ${stdenv.shell} \
      --replace-fail 'CHROME_WRAPPER' 'WRAPPER'
    ln -sf $wrapper $out/bin/brave-origin

    for exe in $out/${optDir}/{brave,chrome_crashpad_handler}; do
      patchelf \
        --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
        --set-rpath "${rpath}" $exe
    done

    substituteInPlace $out/share/applications/{${fileBase},${appId}}.desktop \
      --replace-fail /usr/bin/brave-origin-stable $out/bin/brave-origin
    substituteInPlace $out/share/gnome-control-center/default-apps/${fileBase}.xml \
      --replace-fail /opt/brave.com $out/opt/brave.com
    substituteInPlace $out/${optDir}/default-app-block \
      --replace-fail /opt/brave.com $out/opt/brave.com

    for size in 16 24 32 48 64 128 256; do
      mkdir -p $out/share/icons/hicolor/''${size}x''${size}/apps
      ln -s $out/${optDir}/product_logo_$size.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/${fileBase}.png
    done

    # ANGLE loads this by absolute path; the NixOS loader finds ICDs under
    # /run/opengl-driver, the bundled one doesn't.
    rm $out/${optDir}/libvulkan.so.1
    ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/${optDir}/libvulkan.so.1

    ln -sf ${xdg-utils}/bin/xdg-settings $out/${optDir}/xdg-settings
    ln -sf ${xdg-utils}/bin/xdg-mime $out/${optDir}/xdg-mime

    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : ${rpath}
      --prefix PATH : ${lib.makeBinPath deps}
      --suffix PATH : ${lib.makeBinPath [ xdg-utils coreutils ]}
      --set CHROME_WRAPPER brave-origin
      ${lib.optionalString (enableFeatures != [ ]) ''
        --add-flags "--enable-features=${lib.concatStringsSep "," enableFeatures}\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+,WaylandWindowDecorations --enable-wayland-ime=true}}"
      ''}
      --add-flags "--disable-features=${lib.concatStringsSep "," disableFeatures}"
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto}}"
      --add-flags ${lib.escapeShellArg commandLineArgs}
    )
  '';

  installCheckPhase = ''
    # Skip upstream's wrapper, which hides errors.
    $out/${optDir}/brave --version
  '';

  meta = {
    description = "Brave without Rewards, Wallet, VPN, AI, News or telemetry";
    homepage = "https://brave.com/origin/";
    changelog =
      "https://github.com/brave/brave-browser/blob/master/CHANGELOG_DESKTOP_ORIGIN.md#"
      + lib.replaceStrings [ "." ] [ "" ] finalAttrs.version;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    license = lib.licenses.mpl20;
    platforms = builtins.attrNames debArch;
    mainProgram = "brave-origin";
  };
})
