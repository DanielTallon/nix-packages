# A package your files name, marked broken: point at its line, no chain.
# expect-output: It's pulled in by hosts/case.nix, line 7.
# expect-output: Remove `hello` from line 7 of hosts/case.nix for now.
{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.hello.overrideAttrs (o: { meta = o.meta // { broken = true; }; }))
  ];
}
