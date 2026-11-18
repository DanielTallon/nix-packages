# A list where a single string is wanted: drop the brackets.
# expect-output: On line 5: it's a list (`[ ]`), but a single string is wanted. Remove the brackets. networking.hostName = "desktop";
{ ... }:
{
  networking.hostName = [ "desktop" ];
}
