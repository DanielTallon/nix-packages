# The module's name contains the package name: the report must point at pkgs.zscroll, not line 4.
{ pkgs, ... }:
{
  options.zscroll = { };
  config.environment.systemPackages = [ pkgs.zscroll ];
}
