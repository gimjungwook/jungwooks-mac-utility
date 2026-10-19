# 설치와 제거

이 안내는 v0.26 미공증 Apple Silicon 미리보기에 해당합니다. macOS 14 이상이 필요하며, 실기 확인 기기는 MacBook Pro M1 Max입니다.

## 앱 설치

DMG의 앱을 Applications로 끌어 놓고, 응용 프로그램 폴더에서 실행합니다. 기존 버전이 실행 중이면 패널의 종료 버튼으로 먼저 종료합니다. 기존 개인용 앱은 이 다운로드만으로 교체되지 않습니다.

Apple 공증을 받지 않았으므로 첫 실행이 차단될 수 있습니다. 앱을 한 번 열어 본 뒤 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기로 허용할 수 있습니다. [Apple 안내](https://support.apple.com/en-us/102445)를 확인하세요. Gatekeeper 전체를 끄는 명령은 필요하지 않습니다.

손쉬운 사용에서 앱을 허용한 뒤 다시 실행합니다. 패널이 안 보이면 노치 근처로 마우스를 옮기거나 Control+Option+P를 누릅니다. Dock에 항상 남는 앱이 아닙니다.

## 팬·이동 모드 권한

이 기능을 쓸 때만 DMG의 `절전 권한 설정.command`를 실행합니다. 관리자 암호는 Terminal의 입력창에 입력하며 글자가 표시되지 않습니다. 스크립트 내용을 먼저 확인할 수 있습니다. `.command` 실행이 차단되면 Terminal에서 DMG 폴더로 이동해 다음을 실행합니다.

```sh
cd "/Volumes/Jungwook's Mac Utility Preview"
sudo /bin/sh setup-sudoers.sh
```

설정은 root 소유의 팬 도우미를 `/Library/PrivilegedHelperTools/macutility-fan`에 설치합니다. 현재 사용자에 대해 아래 8개 명령만 암호 없이 허용하는 `/etc/sudoers.d/macutility`를 만듭니다.

- `pmset -a disablesleep 0` 및 `1`
- `pmset -b powermode 0`, `1`, `2`
- 팬 도우미의 `auto`, `4000`, `max`

권한 설정 자체는 팬 속도나 전원 모드를 바꾸지 않습니다. 설정 후 앱에서 이동 모드를 켜고 팬을 선택합니다. 관리자 권한 설정을 하지 않아도 창 배치와 입력 표시는 사용할 수 있습니다.

앱은 시작 시 로그인 항목 등록을 시도합니다. macOS가 승인을 요구하면 시스템 설정의 로그인 항목에서 허용합니다. 앱을 종료해도 등록은 남으므로, 자동 실행을 끄려면 그곳에서 앱을 비활성화합니다.

## 제거·복구

1. 앱에서 이동 모드를 끄고 팬을 자동으로 돌린 뒤 종료합니다.
2. 시스템 설정의 로그인 항목에서 앱을 비활성화하고, 응용 프로그램 폴더의 앱을 휴지통으로 옮깁니다.
3. 팬·전원 권한 설정을 설치했다면 아래 두 파일만 제거합니다.

```sh
sudo rm /etc/sudoers.d/macutility /Library/PrivilegedHelperTools/macutility-fan
```

앱이 충돌해 시스템 절전 방지가 남았을 때만 다음 명령으로 해제합니다.

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

강제 종료 뒤 밝기나 전원 모드가 남았다면 시스템 설정에서 원하는 값으로 바꿉니다. 이동 모드의 덮개·화면 동작은 기기와 macOS에 따라 다를 수 있습니다. 밀폐된 가방에서 장시간 사용은 검증하지 않았습니다.
