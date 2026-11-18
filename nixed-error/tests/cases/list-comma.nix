{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.git, pkgs.vim ];
}
