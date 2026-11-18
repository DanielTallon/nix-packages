{ lib, ... }:
{
  boot.kernelParams = lib.concatMap (x: [ x ]) "quiet";
}
