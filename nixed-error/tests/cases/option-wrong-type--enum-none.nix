# An enum value nothing in the list is close to: just list the allowed values.
# Nothing reads consoleMode unless systemd-boot is on, so the case reads it in an /etc file.
# expect: option-wrong-type
# expect-output: ✗ "huge" isn't an allowed value for this option
# expect-output: On line 8: use one of the allowed values: "0", "1", "2", "5", "auto", "max", "keep".
{ config, ... }:
{
  boot.loader.systemd-boot.consoleMode = "huge";
  environment.etc.case.text = config.boot.loader.systemd-boot.consoleMode;
}
