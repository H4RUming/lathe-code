# M0 LLDB-DAP toolchain probe

`Scripts/probe-lldb-dap.py`는 선택된 Xcode의 실제 `lldb-dap`와 Swift compiler를 검사하는 개발용 probe다.
앱의 debugger service, ToolBroker 권한 경계, breakpoint UI를 구현한 것은 아니다.
`LAT-DEBUG-001~003`의 기반 검증이며, [실행·디버깅 계약](../execution-and-debugging.md)의 전체 수용 게이트와 구분한다.

## 실행과 판정

```sh
python3 Scripts/probe-lldb-dap.py --output .build/probes/lldb-dap.json
```

API key·외부 서버·사용자 프로젝트 없이 저장소의 `Scripts/Fixtures/lldb-probe.swift`만 임시 디렉터리에 빌드한다.
`xcrun --find`로 현재 선택된 toolchain을 발견하며 Xcode 선택, Developer Mode, 디버깅 권한 설정을 바꾸지 않는다.
adapter와 compiler subprocess는 credential이 없는 최소 환경과 임시 HOME을 사용한다.
LLDB의 init-file 비활성화 test extension도 LLVM 20 이전 및 21 형식으로 보낸다.

| 결과 | 조건 | 기본 exit code |
| --- | --- | --- |
| `pass` | Swift breakpoint·stack/scopes/variable·step·정상 종료와 별도 owned-child attach/detach 생존 검증 모두 통과 | 0 |
| `unsupported` | macOS/toolchain 없음 또는 adapter가 명시적으로 OS 디버깅 권한 제한을 반환 | 2 |
| `fail` | 컴파일, DAP 메시지/순서, 검증 assertion, timeout 등 다른 실패 | 1 |

CI에서 진단을 수집하되 runner의 디버깅 권한 유무를 필수 조건으로 삼지 않을 때만 `--allow-unsupported`를 붙인다.
이 옵션은 `unsupported`의 exit code만 0으로 바꾸며 JSON 상태·이유를 보존한다. `fail`은 항상 실패한다.
`unsupported`를 디버깅 지원 검증 완료로 해석하지 않는다.

보고서에는 OS/architecture, adapter·compiler 경로와 version, Xcode version, fixture/artifact SHA-256,
각 시나리오 결과, 실제 initialize capability, bounded protocol trace·진단과 거부한 reverse request 이름을 기록한다.
개인 세션·API credential은 사용하지 않으며 산출물은 Git에 넣지 않는다.

## 2026-10-15 로컬 관찰 결과

검사 환경은 arm64 macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4,
lldb-dap LLVM 21.0.0 / liblldb `lldb-2103.0.34.103`이다.

| 검사 | 실제 결과 |
| --- | --- |
| toolchain 발견·Swift debug fixture 컴파일 | 통과 |
| DAP initialize와 capability 응답 | 통과 |
| 별도 LLDB CLI의 동일 fixture `target create` | 통과, 약 0.84초 |
| 실제 DAP launch | `initialized` 또는 launch 응답 전 15초 timeout, `fail` |
| 실제 DAP attach | `initialized` 또는 attach 응답 전 15초 timeout, `fail`; 소유 child 종료·wait 완료 |
| breakpoint·변수·step·continue, detach 후 생존 | 시작 단계 실패로 미검증 |

호스트 명령 실행 권한으로 실행한 결과이며, 도구 sandbox 안에서는 launch/attach가 `no such process`로 실패했다.
별도의 읽기 전용 `DevToolsSecurity -status`는 Developer mode가 disabled라고 반환했다.
이는 권한 환경의 단서이며 timeout 원인 확정은 아니다. timeout을 `unsupported`나 성공으로 바꾸지 않는다.
권한 설정 변경은 하지 않았다. 따라서 **실제 debugger 수용 게이트는 아직 미충족**이다.

## 실제 검증 범위

1. `initialize` 후 `launch`를 전송하고 응답을 기다리는 동안에도 이벤트를 처리한다.
   `initialized`에서 fixture source breakpoint를 설정하고 `verified`를 확인한 뒤 `configurationDone`을 보낸다.
2. breakpoint 정지 후 thread ID와 `inspectLocal` stack frame, scopes와 `probeValue == 41`을 확인한다.
   `next` 후 새 정지 이벤트에서 frame/scopes/reference를 다시 조회하고 값이 42인지 확인한다.
3. continue 후 debuggee `exited`의 code 0, `terminated`와 fixture stdout을 각각 확인한다.
4. 별도 adapter에서 probe가 직접 생성해 아직 wait하지 않은 child에만 attach한다.
   정지 상태 stack을 관찰하고 `disconnect(terminateDebuggee: false)` 후 child 생존과 heartbeat 진행을 확인한다.
   검증 후에는 probe 소유 child만 종료하고 wait한다. 외부 PID·실행 파일을 입력하는 옵션은 없다.

프로토콜은 stdio의 Content-Length framing을 사용하며 frame 1 MiB, trace 100개, 진단 8 KiB,
요청/이벤트 대기 15초로 제한한다. adapter의 reverse request는 실패 응답으로 거부하고 기록한다.
`runInTerminal`을 통한 실제 터미널 실행은 이 probe의 범위 밖이다.
attach fixture의 정상 실행 loop는 60초로 제한하며 launch fixture에도 60초 alarm을 둔다.
debugger가 process를 정지한 시간은 실제 종료 지연을 늘릴 수 있으므로 이 제한을 OS 강제 종료 보장으로 취급하지 않는다.

## 남은 구현과 한계

- Swift-native production DAP client, engine 소유 DebugSession, helper runner·ToolBroker 연동과 UI는 후속 구현이다.
- 이 검증은 알려진 직접 child에 대한 attach다. 임의 외부 PID의 시작 시각·소유자·실행 경로 검증을 대체하지 않는다.
- 임의 evaluate, 조건부 breakpoint, formatter 효과, stale handle 거부, adapter crash 복구, owner 교대,
  승인된 runInTerminal 실행, simulator/device/SSH와 C/C++은 검증하지 않는다.
- OS의 authorization 제한은 환경 결과로 기록한다. 기존 권한을 자동 변경하거나 재시도 승인으로 우회하지 않는다.
- 현재 설치 toolchain의 통과를 다른 macOS/Xcode 조합의 지원 보장으로 확대하지 않는다.

## 근거

2026-10-15 공식 문서와 설치된 `xcrun lldb-dap --help`를 확인했다.
[LLDB-DAP 공식 문서](https://lldb.llvm.org/use/lldbdap.html)의 toolchain 발견·launch/attach 설정과
[DAP overview](https://microsoft.github.io/debug-adapter-protocol/overview)의 초기화·설정·event pump·종료 흐름을 따른다.
capability는 문서 표에서 복사해 지원을 추정하지 않고 실행한 adapter의 응답을 보고서에 남긴다.
init-file extension 이름은 [LLVM 21 protocol parser](https://github.com/llvm/llvm-project/blob/release/21.x/lldb/tools/lldb-dap/Protocol/ProtocolRequests.cpp)에서 확인했다.
