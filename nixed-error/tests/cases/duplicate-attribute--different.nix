# expect: duplicate-attribute
# expect-output: They disagree (`"laptop"` vs `"desktop"`)
{ ... }:
{
  networking.hostName = "laptop";
  time.timeZone = "UTC";
  networking.hostName = "desktop";
}
