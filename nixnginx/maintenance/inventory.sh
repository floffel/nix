export PATH=/run/current-system/sw/bin:/run/current-system/bin:/usr/bin:/bin
PHP=/nix/store/sfrha54dgcgkrpwmyw6z9xwv22aayfsr-php-with-extensions-8.4.27/bin/php
S=/var/lib/nc-s3-migration
su -s /run/current-system/sw/bin/bash nextcloud -c "$PHP $S/nc-s3-inventory.php dump"
su -s /run/current-system/sw/bin/bash nextcloud -c "$PHP $S/nc-s3-inventory.php check"
