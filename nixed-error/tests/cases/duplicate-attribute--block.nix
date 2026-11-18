# The first copy is inside a { } block; the second spells out the whole name.
# expect: duplicate-attribute
# expect-output: `services.openssh.enable` is set twice
# expect-output: They disagree (`true` vs `false`)
{ ... }:
{
  services.openssh = {
    enable = true;
    ports = [ 22 ];
  };
  services.openssh.enable = false;
}
