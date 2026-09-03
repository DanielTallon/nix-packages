{ lib, stdenv, dpkg, autoPatchelfHook, wrapGAppsHook3, fetchurl, gtk3, glib, libdrm, libGL, alsa-lib, atk, pango, cairo, gdk-pixbuf, cups, dbus, expat, fontconfig, freetype, fribidi, harfbuzz, libX11, libXcomposite, libXcursor, libXdamage, libXext, libXfixes, libXi, libXinerama, libXrandr, libXrender, libXtst, libxcb, libxkbcommon, mesa, nspr, nss, at-spi2-atk, at-spi2-core, libglvnd, libsm, libice, ...}:

# Ported from the real dotfiles derivation (modules/kenku-fm/default.nix).
# Kenku FM ships upstream as a .deb, not an AppImage — this extracts it with
# dpkg-deb and relinks it against nixpkgs libs via autoPatchelfHook, same as
# the version that's been running in your dotfiles.

stdenv.mkDerivation rec {
  pname = "kenku-fm";
  version = "1.5.5"; # bump alongside url/sha256 when upstream releases a new version

  src = fetchurl {
    url = "https://github.com/owlbear-rodeo/kenku-fm/releases/download/v${version}/kenku-fm_${version}_amd64.deb";
    sha256 = "sha256-oDpDpeYVBXfE/teg/xmpfI142mIGeywpxVbEKhHcO28=";
  };

  nativeBuildInputs = [ dpkg autoPatchelfHook wrapGAppsHook3 ];

  buildInputs = [
    gtk3 glib libdrm libGL alsa-lib atk pango cairo gdk-pixbuf cups dbus
    expat fontconfig freetype fribidi harfbuzz libX11 libXcomposite
    libXcursor libXdamage libXext libXfixes libXi libXinerama libXrandr
    libXrender libXtst libxcb libxkbcommon mesa nspr nss at-spi2-atk
    at-spi2-core libglvnd libsm libice
  ];

  unpackPhase = "true";

  installPhase = ''
    mkdir -p $out/bin $out/lib $out/share
    dpkg-deb --fsys-tarfile $src | tar -x --exclude='./usr/lib/kenku-fm/chrome-sandbox' -C $out
    mv $out/usr/bin/* $out/bin/
    mv $out/usr/lib/* $out/lib/
    mv $out/usr/share/* $out/share/
    rm -rf $out/usr
  '';

  postFixup = ''
    wrapProgram $out/bin/kenku-fm \
      --add-flags "--no-sandbox" \
      --prefix XDG_DATA_DIRS : "$out/share" \
      --set DEFAULT_BROWSER "brave"
  '';

  meta = {
    description = "Offline-capable text-to-speech and voice changer for tabletop audio";
    homepage = "https://www.kenku.fm/";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "kenku-fm";
  };
}
