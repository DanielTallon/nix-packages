# mode: build
# Your own patch on a package no longer applies after an update (seen in ~/.dotfiles: title.patch on
# areofyl/fetch, a flake input's package, so the override never names `fetch`). `Hunk #1 FAILED` must
# not read as failed tests, and the patch file names you as the owner.
# expect: build-failure
# expect-output: Why the build failed: A patch no longer fits the source
# expect-output: Whose: Your config
# expect-output: The failing patch, `title.patch`, is yours: you add it to `hello` on hosts/case.nix, line 16
# expect-output: Until it's updated, go back to your previous flake.lock (`git checkout flake.lock`), or take the patch out of line 16 for now.
{ pkgs, ... }:
let
  pkg = pkgs.hello;
in
{
  system.build.nixedErrorCase = pkg.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ (pkgs.writeText "title.patch" ''
      --- a/src/hello.c
      +++ b/src/hello.c
      @@ -1,6 +1,7 @@
       this line is not in hello.c
       nor is this one
       or this one
      +/* added by a patch written for an older version */
       still not in hello.c
       not this either
       nor this
    '') ];
  });
}
