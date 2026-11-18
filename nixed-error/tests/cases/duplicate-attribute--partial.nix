# A pasted block where one value disagrees: it can't go as a whole, so its repeats are listed one by one, in order.
# expect: duplicate-attribute
# expect-output: line 11: enable = true; (`services.pipewire.enable`, also on line 18; same value) line 12: alsa.enable = false; (`services.pipewire.alsa.enable`, also on line 19; `false` vs `true`: keep the one you want)
{ ... }:
{
  hardware.bluetooth.enable = true;

  services.pulseaudio.enable = false;

services.pipewire = {
  enable = true;
  alsa.enable = false;
  jack.enable = true;
};
services.pulseaudio.enable = false;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
  };
}
