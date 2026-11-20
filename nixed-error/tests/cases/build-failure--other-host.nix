# mode: build
# A failed build that a package you install needs, named in two files: this host's and another machine's
# (seen in ~/.dotfiles: overlord.nix's `discord` was blamed for the desktop's nixcord Discord). The text search
# finds hosts/a-laptop.nix first, but this host never imports it, so the config itself is asked what installs it.
# untracked: hosts/a-laptop.nix { pkgs, ... }: { environment.systemPackages = [ my-tools ]; }
# expect: build-failure
# expect-output: `my-tools` (hosts/case.nix, line 10) needs `dep-tool`.
{ pkgs, ... }:
let
  my-tools = pkgs.symlinkJoin {
    name = "my-tools-1.0";
    paths = [
      (pkgs.runCommand "dep-tool-1.0" { } ''
        echo "dep.c:3: error: expected ';'" >&2
        exit 1
      '')
    ];
  };
in
{
  environment.systemPackages = [ my-tools ];
  system.build.nixedErrorCase = my-tools;
}
