# mode: build
# A failed build that something else needs: the report names the chain (from `nix why-depends`).
# expect: build-failure
# expect-output: It's needed through my-tools-1.0 → dep-tool-1.0.
{ pkgs, ... }:
{
  system.build.nixedErrorCase = pkgs.symlinkJoin {
    name = "my-tools-1.0";
    paths = [
      (pkgs.runCommand "dep-tool-1.0" { } ''
        echo "dep.c:3: error: expected ';'" >&2
        exit 1
      '')
    ];
  };
}
