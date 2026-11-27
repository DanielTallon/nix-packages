# mode: captured
# Real `nh os switch --update` output (2026-11-27): the user's title.patch on areofyl/fetch (a flake
# input's package, overridden as `…packages.${system}.default.overrideAttrs`, which never names `fetch`)
# stopped applying after the input moved. Was reported as failed tests ("Hunk #4 FAILED" read as
# "4 failed") from an upstream package; it's the user's own patch.
# expect: build-failure
# expect-output: Why the build failed: A patch no longer fits the source
# expect-output: Whose: Your config
# expect-output: The failing patch, `title.patch`, is yours: you add it to `fetch` on configuration.nix, line 5
{ inputs, pkgs, ... }:
{
  home-manager.users.fredrick.home.packages = [
    (inputs.areofyl-fetch.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./title.patch ];
    }))
  ];
}
