#!/bin/sh
set -e
cd "$(dirname "$0")"
sudo /bin/sh setup-sudoers.sh
printf "\n설정 완료. Jungwook's Mac Utility의 이동 모드를 껐다 켜면 저전력 모드가 자동 적용됩니다.\n"
printf 'Enter 키를 누르면 닫습니다. '
read -r answer
