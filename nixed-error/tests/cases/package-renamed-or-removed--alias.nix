# "The ‘gnome.gedit’ alias was removed": the package is gnome.gedit, not "alias".
# expect: package-renamed-or-removed
# expect-output: Where: hosts/case.nix, line 6
# expect-output: Replace `gnome.gedit` on line 6 of hosts/case.nix with `gedit`.
{ pkgs, ... }:
{ environment.systemPackages = [ pkgs.gnome.gedit ]; }
