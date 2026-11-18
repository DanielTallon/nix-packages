# mode: captured
# The hm-backup-exists fixture with home-manager's message for no backupFileExtension
# (modules/files/check-link-targets.sh), plus a second file: every file in the way is listed.
# expect-output: home-manager wants to manage `~/.config/fastfetch/config.jsonc` and `~/.config/git/config`
# expect-output: mv ~/.config/fastfetch/config.jsonc ~/.config/fastfetch/config.jsonc.old
# expect-output: mv ~/.config/git/config ~/.config/git/config.old
# expect-output: sudo systemctl restart home-manager-fredrick.service
# expect-output: home-manager.backupFileExtension = "backup";
