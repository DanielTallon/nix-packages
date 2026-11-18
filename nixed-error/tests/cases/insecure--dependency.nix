# An insecure package nothing in your files names (getAttr keeps "pkgs.hello" out of this file),
# with an issue that isn't "discontinued": blame the dependency, suggest waiting, no line to remove.
# expect-output: - CVE-0000-0001: made up for this test
# expect-output: Nothing in your files names it, so something you use depends on it.
# expect-output: Wait for an update that fixes it
{ pkgs, ... }:
{
  environment.systemPackages = [
    ((builtins.getAttr "hello" pkgs).overrideAttrs (o: { meta = o.meta // { knownVulnerabilities = [ "CVE-0000-0001: made up for this test" ]; }; }))
  ];
}
