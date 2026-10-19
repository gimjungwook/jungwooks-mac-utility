#!/bin/sh
# One time: sudo sh setup-sudoers.sh
# Undo:     sudo rm /etc/sudoers.d/macutility /Library/PrivilegedHelperTools/macutility-fan
# Installs the fan helper (root-owned) and lets your user run exactly these commands without a password:
#   pmset -a disablesleep 0 | 1      pmset -b powermode 0 | 1 | 2      macutility-fan auto | 4000 | max
set -e
[ "$(id -u)" = 0 ] && [ -n "$SUDO_USER" ] || { echo "sudo sh setup-sudoers.sh 로 실행하세요"; exit 1; }
cd "$(dirname "$0")"
[ -x build/macutility-fan ] || { echo "먼저 sh build.sh 를 실행하세요"; exit 1; }
HELPER=/Library/PrivilegedHelperTools/macutility-fan
[ -d /Library/PrivilegedHelperTools ] || install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools
install -m 0755 -o root -g wheel build/macutility-fan "$HELPER"
T="$(mktemp)"
echo "$SUDO_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -b powermode 0, /usr/bin/pmset -b powermode 1, /usr/bin/pmset -b powermode 2, $HELPER auto, $HELPER 4000, $HELPER max" > "$T"
visudo -cf "$T"
install -m 0440 -o root -g wheel "$T" /etc/sudoers.d/macutility
rm -f "$T"
echo "installed: $HELPER and /etc/sudoers.d/macutility"

