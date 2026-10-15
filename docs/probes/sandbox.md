# M0 macOS sandbox 기술 검증

2026-10-15. `LAT-PERM-006`, `E2E-09`, M0 sandbox filesystem/network probe에 대한
**개발용 실험**이다. 앱·engine의 production `SandboxBackend`나 전체 실행 격리는 아직 구현하지 않았다.

## 실행과 판정

```sh
python3 Scripts/probe-sandbox.py --output .build/probes/sandbox.json
```

Python 표준 라이브러리와 macOS에 설치된 `/usr/bin/sandbox-exec`만 사용한다.
Python은 검증 harness 의존성이며 앱/engine의 runtime 의존성이 아니다.
매 실행마다 임시 디렉터리와 IPv4 loopback listener를 만들고 종료 시 정리한다.
네트워크 검증은 `127.0.0.1`의 임시 포트만 대상으로 하며 외부 서버와 실제 사용자 파일에는 접근하지 않는다.
fixture 프로세스에는 PATH/HOME/TMPDIR/LC_ALL만 전달한다.
각 fixture 실행은 별도 process group을 사용하며 10초 timeout이나 중단 시 해당 group을 종료한다.

stdout와 `--output`에 같은 JSON을 기록한다. report에는 macOS 버전·build, CPU, Swift/Python 버전,
OS에 포함된 sandbox-exec의 SHA-256, 실제 profile, check별 관찰값이 포함된다.
이 바이너리에는 version flag가 없어 OS build와 hash를 함께 기록한다.

| 결과 | 종료 코드 | 의미 |
| --- | --- | --- |
| `passed` | 0 | 현재 host에서 아래 fixture의 모든 통제가 관찰됨 |
| `failed` | 1 | 예상과 다른 허용/차단, 실행 오류, timeout 또는 잘못된 worker 결과 |
| `unsupported` | 2 | 도구 부재·sandbox activation 불가·fixture 자체의 비격리 control 불가 |

어떤 check라도 실패하면 전체 결과는 `failed`다. 실패는 없지만 미지원 check가 있으면 `unsupported`다.
unsupported는 성공으로 취급하지 않는다. sandbox 설치가 안 되는 경우 실제 명령을 비격리로 다시 실행하는
fallback은 없다. **비격리 control은 허용·차단 효과를 비교하기 위한 동일한 임시 fixture**에만 사용한다.

## 검증 범위

| Check | 성공 조건 |
| --- | --- |
| backend activation | 고정 profile을 적용한 `/usr/bin/true`가 성공 |
| 허용 디렉터리 쓰기 | 허용 영역에 marker 생성 |
| 허용 밖 쓰기 | 비격리 control은 성공, sandbox에서 EPERM/EACCES와 파일 미생성 |
| symlink 우회 쓰기 | 허용 영역의 symlink가 가리키는 sibling 영역에 쓰기 차단 |
| child의 쓰기 차단 상속 | sandbox 안 Python이 새 Python child를 생성해도 sibling 쓰기 차단 |
| child의 쓰기 허용 상속 | 같은 descendant 경로에서 허용 영역 쓰기는 성공 |
| loopback TCP 차단 | 비격리 연결·accept는 성공, sandbox 연결은 EPERM/EACCES |

“허용 밖”은 이 probe가 만든 임시 fixture 안의 sibling 디렉터리를 뜻한다.
임의의 사용자의 home이나 설정 파일을 테스트 대상으로 삼지 않는다.
파일 쓰기의 각 case에 대해 동일 대상·동일 Python worker의 비격리 control을 먼저 실행한다.

profile은 기본 동작을 허용한 뒤 파일 쓰기를 허용 디렉터리로 제한하고 모든 network operation을 거부한다.
**읽기 격리는 없다.** 이것은 kernel 차단 동작을 관찰하기 위한 최소 profile이며 제품용 정책 template이 아니다.
Shell tool, MCP, hook에 이 profile을 그대로 연결하면 안 된다.

## 근거와 backend 결정

설치된 `/usr/share/man/man1/sandbox-exec.1`은 명령을 deprecated로 표시하고 App Sandbox를 안내한다.
Apple DTS도 custom sandbox profile 언어가 제3자용으로 문서화·지원되는 API가 아니며 제품 기반으로
삼기에 적합하지 않다고 설명했다. 이 probe의 성공은 그 지원 상태를 바꾸지 않는다.
[Apple Developer Forums의 DTS 설명](https://developer.apple.com/forums/thread/661939)

Apple이 공식 지원하는 App Sandbox는 앱의 entitlement 기반 접근 제어다. helper tool은 부모의
sandbox 설정을 상속하는 방식이므로 임의의 workspace별 shell 정책을 즉시 제공하는 backend로
간주하지 않는다. Lathe 앱 자체의 App Sandbox와 runner의 격리는 별도로 결정한다.
[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[embedded helper 계약](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

M0 결정은 다음과 같다.

1. `sandbox-exec`는 **실험 backend 후보**로만 유지한다. 이 변경에는 production launcher 연결이 없다.
2. 후속 `SandboxBackend`는 OS/tool 상태, 검사한 capability, 정책 revision을 반환해야 한다.
   사용자가 sandbox 실행을 선택했는데 activation이 실패하면 실행을 중단하고 `unsupported/failed`를 반환한다.
   별도로 선택한 비격리 실행 profile은 표시와 정책을 갖추어야 하며 자동 fallback이 되어서는 안 된다.
3. 이 인터페이스에 장기 지원을 전제하지 않는다. 지원되는 격리가 필요한 실행은 별도 VM backend를 평가한다.
   Apple Virtualization은 macOS guest 구성의 공식 API를 제공하지만, 이 프로젝트는 아직 VM 실행·파일 공유·
   네트워크 정책을 검증하지 않았다. VM도 기본 설정만으로 Lathe의 요구를 충족했다고 표시하지 않는다.
   [Apple의 macOS VM 예제](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)

## 다음 게이트와 한계

- 최소 지원 macOS 15와 지원 OS/CPU matrix에서 동일 probe 실행. 로컬 최신 OS 통과만으로 최소 OS 지원을 확정하지 않는다.
- 실제 Swift/clang/Git/패키지 도구의 정상 실행과 최소 읽기 grant, engine DB·credential/config 접근 거부 검증.
- 이미 열린 FD, hardlink·rename·symlink 교체 race, workspace 삭제/교체, process escape, Mach IPC와 UNIX socket 검증.
- IPv6·DNS·UDP·Unix socket, 허용 endpoint proxy와 redirect 정책. 현재 TCP 거부는 endpoint allowlist의 검증이 아니다.
- runner pipe/PTY와 sandbox의 조합, 취소된 child tree, timeout, debugger 권한과 상호작용 검증.
- ToolBroker의 승인·journal·권한 변경 경계와 통합. probe 통과로 승인 정책을 생략하지 않는다.
- backend capability와 violation 원인을 GUI/CLI 실행 결과에 일관되게 표시.

이 게이트 이전에는 `LAT-PERM-006`이나 E2E-09 전체를 완료 상태로 바꾸지 않는다.

## 이번 실행 기록

제한된 개발 실행 환경에서는 sandbox 설치가 `sandbox_apply: Operation not permitted`로 거부되어
`unsupported`가 기록되었다. 이는 중첩 sandbox 적용 제한이며, 파일·network 차단 성공 결과가 아니다.

같은 fixture를 host에서 실행해 **7개 check가 모두 passed**인 것을 확인했다.
검증 host는 macOS 27.0.1 (`26A434`), arm64, Swift 6.4이며 최소 지원 macOS 15 실행은 아직 미검증이다.
허용 영역 쓰기, 허용 밖·symlink 쓰기 거부, child의 거부·허용 상속,
loopback control 성공과 sandbox 연결 거부가 모두 관찰되었다.
정확한 실행 결과는 `.build/probes/sandbox.json`의 check와 OS build를 기준으로 확인한다.
생성 JSON은 로컬/CI artifact이며 저장소에 실제 경로를 포함한 실행 기록을 커밋하지 않는다.
