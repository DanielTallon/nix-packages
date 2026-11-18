# mode: build
{ pkgs, ... }:
{
  system.build.nixedErrorCase = pkgs.runCommand "my-broken-script" { } ''
    echo "compiling..."
    echo "main.c:12: error: expected ';' before 'return'" >&2
    exit 2
  '';
}
