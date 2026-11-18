# mode: build
# A nixpkgs package broken by your own overrideAttrs (seen in ~/.dotfiles with hello): blame your
# config, not upstream, and point at the line the log's last output comes from.
# expect: build-failure
# expect-output: Whose: Your config
# expect-output: `hello` comes from nixpkgs, but you change it with `overrideAttrs` on hosts/case.nix, line 11
# expect-output: The build log's line `nixed-error test: failing on purpose` comes from line 12 of your file.
# expect-output: Where: hosts/case.nix, line 12
# expect-output: > …/coreutils-9.11/bin/install -c hello '…/hello-2.12.3/bin'
{ pkgs, ... }:
{
  system.build.nixedErrorCase = pkgs.hello.overrideAttrs (old: {
    postInstall = "echo 'nixed-error test: failing on purpose'; exit 1";
  });
}
