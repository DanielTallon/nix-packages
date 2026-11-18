# expect: missing-opener
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "hello" "echo hi"
    pkgs.git
  ];
}
