# mode: build
{ pkgs, ... }:
{
  system.build.nixedErrorCase = pkgs.runCommand "my-fixed-thing" {
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  } "echo hello > $out";
}
