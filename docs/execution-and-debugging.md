# 실행 환경·빌드·테스트·네이티브 디버깅 계약

설계·공식 문서 확인: 2026-10-15. **제안 계약이며 아직 구현되지 않았다.**
[기능 명세](features.md)의 명령 실행·테스트·개발 서버·worktree·네이티브 화면을 구체화한다.
`LAT-EXEC-001~003`, `LAT-DEBUG-001~003`과 E2E-22/23에 연결한다.
[아키텍처](architecture.md)의 Swift engine, ExecutionEnvironment, helper runner, ToolBroker, PolicyEngine을 그대로 사용한다.
앱 UI·선택적인 개발 client·Ultra agent가 앱 내부 runtime의 실행과 디버깅 상태를 관찰하며 UI 전용 우회 경로를 만들지 않는다.
headless 독립 실행은 명시적인 개발/CI harness다. 일반 배포는 단일 앱이며 앱 밖 상주 service를 설치하지 않는다.

## 1. 기능 동등성과 추가 네이티브 기능

| 범위 | 분류와 목표 |
| --- | --- |
| shell로 build/run/test, 개발 서버·환경·worktree 준비 | Claude coding workflow의 기능 동등성; 기존 실행 요구를 완성 |
| `.claude/launch.json`, `.worktreeinclude` 읽기 | 공개 형식별 E 목표, Lathe 저장·권한·UI는 N; fixture 통과 전 E 선언 금지 |
| 재사용 실행 profile·구조화 테스트 결과·toolchain 진단 | 네이티브 개발 경험 강화; 기존 명령을 재현·검토 가능하게 함 |
| LLDB-DAP debugger와 agent의 구조화된 디버깅 도구 | 추가 네이티브 기능; Claude Code의 내장 DAP 지원과 동일하다는 주장이 아님 |

shell에서 `lldb`를 실행할 수 있다는 사실만으로 breakpoint·stack·variables UI나 DAP client가 구현되었다고 표시하지 않는다.
첫 debugger 범위는 local macOS의 Swift/C/C++ 실행 파일이다. 다른 언어 adapter, simulator/device, SSH debug는 별도 capability 게이트다.
실행 profile은 generic command부터 지원하며 Xcode 프로젝트가 아닌 저장소도 동일한 흐름을 사용한다.

## 2. 실행 profile과 파일 소유권

`ExecutionProfile`은 kind(build/run/test/server/debug), workspace/root ID, executable/argv, cwd,
environment profile revision, prerequisite, timeout, output/result adapter, artifact 위치와 권한 효과를 가진다.
한 번 실행한 `ExecutionAttempt`는 profile revision·source revision·toolchain fingerprint·실제 인자·환경 참조를 고정한다.
재실행은 새 attempt이며 이전 결과·source hash·실패 로그를 덮어쓰지 않는다.

| 입력 | 처리 |
| --- | --- |
| `.claude/launch.json` | JSONC 읽기 전용 import; version/configurations/autoVerify와 name/runtimeExecutable/runtimeArgs/program/args/cwd/env/port/url/autoPort 검증 |
| `.lathe/launch.json` | Lathe의 versioned native profile 저장; import 수정은 같은 ID의 명시적 override로 기록 |
| `.lathe/settings.local.json` | 개인 실행 환경 override와 credential 참조; 공유 파일에 secret을 기록하지 않음 |
| Xcode scheme/test plan·package script | 발견한 후보와 출처를 표시; 선택한 항목만 실행 profile에 연결 |

같은 scope에서는 native override가 import보다 우선하며 partial JSON 필드 혼합으로 command의 의미를 바꾸지 않는다.
알 수 없는 실행 필드·지원하지 않는 변수 치환은 해당 profile을 진단하고 활성화하지 않는다.
`.claude/launch.json`은 dev-server 설정이지 VS Code DAP `launch.json`과 동일한 형식이 아니다.
`autoVerify`는 preview 검증 정책으로 변환하며 browser capability가 없으면 지원 불가를 표시하고 검증을 완료로 꾸미지 않는다.
공식 Desktop은 여러 server 설정·cwd/env·port/autoPort·URL을 제공한다. [공식 preview 설정](https://code.claude.com/docs/en/desktop#configure-preview-servers)

profile 발견·파싱은 passive 작업이다. 시작할 때만 기존 trust/grant와 ToolBroker로 명령·pre/post step을 검증한다.
승인된 작업의 build→test→run은 허용 범위에서 이어지며 각 command에 같은 승인을 반복하지 않는다.
port를 자동 할당하면 실제 할당값·인자/env 반영·최종 URL을 기록한다. 고정 callback port는 임의로 바꾸지 않는다.
기존 server 연결과 Lathe가 시작한 server를 구분하여 외부 server를 종료하거나 소유권을 가져오지 않는다.

## 3. 환경 진단과 worktree 초기화

`EnvironmentSnapshot`은 OS/architecture, selected toolchain, executable 절대 경로·version,
PATH 출처, cwd, 필요한 runtime/package manager, credential 참조, bootstrap revision을 기록한다.
환경 값 원문은 기본 로그·모델 context에 넣지 않으며 provider credential을 개발 subprocess에 자동 상속하지 않는다.
Dock/Finder/CLI 시작 방식에 따른 차이는 doctor에서 진단한다. shell profile 실행은 별도 실행 단계로 timeout·효과·출처를 기록한다.
프로젝트의 env script·direnv류 자동 초기화는 발견만으로 실행하지 않고 해당 trust/grant 범위를 확인한다.
참고로 Claude Desktop도 GUI 시작 환경과 shell export가 다를 수 있음을 설명한다. [공식 local 환경](https://code.claude.com/docs/en/desktop#local-sessions)

Xcode profile은 developer directory/toolchain, project 또는 workspace, scheme, configuration,
SDK/destination, test plan/selection, build products·DerivedData 경로를 명시한다.
서로 다른 checkout의 빌드 산출물을 무심코 공유하지 않으며 cache 공유는 별도 정책과 key로 결정한다.
Xcode의 scheme은 build/run/test/profile 대상과 구성·인자·환경을 결정한다. [Apple scheme 설명](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project)
도구 미설치·Xcode 선택 오류·SDK/destination 없음·서명/실행 권한 부족은 구분하며 설정이 없을 때 임의로 시스템 선택을 바꾸지 않는다.

`WorkspaceBootstrap` 상태는 discovered → planned → preparing → ready 또는 failed/cancelled다.
dependency install, 허용된 config 복사, 로컬 서비스 준비를 순서와 receipt가 있는 단계로 실행한다.
setup key는 checkout ID + setup revision + lockfile/toolchain fingerprint이며 resume 때 무조건 다시 실행하지 않는다.
중간 실패 후 재시도는 완료 receipt와 단계의 idempotency를 검사한다. checkout 생성만으로 ready로 표시하지 않는다.
이미 사용자가 설정한 runtime은 재사용하되 필요 version이 다르면 차이를 보여 주고 허용된 범위에서 환경을 구성한다.

`.worktreeinclude`는 공식 `.gitignore` 문법 입력으로 읽고, 일치하며 gitignored인 파일의 copy manifest를 만든다.
native include·bootstrap 정의는 `.lathe/launch.json`의 versioned bootstrap 영역에 저장한다.
copy 대상·source/destination·mode/hash를 기록하며 tracked 파일을 덮어쓰거나 외부 symlink를 따라 권한을 넓히지 않는다.
secret 파일은 허용된 scope에서만 복사하고 내용은 로그·모델 입력·Git에 넣지 않는다. 제외·실패 항목을 숨기지 않는다.
dependency directory의 공유 symlink는 copy와 별개 opt-in 정책이며 source checkout까지 변경될 수 있는 효과를 계산한다.
공식 worktree는 fresh checkout이고 환경 준비와 ignored 파일 복사가 필요할 수 있다. [공식 worktree 환경·include](https://code.claude.com/docs/en/worktrees)

## 4. 구조화된 빌드·테스트 결과

`BuildResult`는 attempt ID, source/toolchain/profile revision, status, diagnostics, artifact, 원본 log를 연결한다.
실행 파일 artifact에는 경로·hash·architecture·debug info·build receipt를 기록하고 debug 시작 때 현재 파일과 대조한다.
빌드 실패 후 이전 artifact를 실행하려면 그 artifact의 이전 revision임을 명시하고 사용자의 실행 의도와 정책을 확인한다.

`TestRun`은 adapter/version, 선택된 suite/test ID, 발견된 목록, 시작/종료 시각과 원본 result artifact를 가진다.
test case 상태는 discovered/running/passed/failed/skipped/cancelled/unknown이며 run 상태와 분리한다.
실패에는 message·source location·stack/attachment, 반복 실행에는 attempt를 보존하고 flaky를 임의 성공으로 합치지 않는다.
Xcode result bundle, Swift test, JUnit 계열을 adapter로 해석하되 미지원 형식은 raw log와 해석 불가 상태로 남긴다.
Apple은 result bundle과 `xcresulttool`을 통한 결과 접근을 제공한다. CLI/schema는 설치 버전별 검증이 필요하다.
[Apple 테스트 결과 자동화](https://developer.apple.com/videos/play/wwdc2019/413/)

exit code 0, 테스트 0개, 로그에 보이는 “passed” 문자열만으로 선택한 테스트 전체 성공을 판정하지 않는다.
partial/corrupt result, discovery 실패, build만 성공, 일부 test 미실행을 별도 표시한다.
취소된 run에서 이미 완료된 case 결과는 보존하되 나머지를 passed로 채우지 않는다.
오래된 진단·test 성공은 원 source revision에 붙이고 현재 변경 검증 완료로 재사용하지 않는다.
실패 case 재실행은 실제 test selector를 사용하고 지원하지 않는 runner는 전체 실행 또는 미지원 사실을 명시한다.

## 5. LLDB-DAP 세션과 도구

`DebugSession`은 execution attempt, workspace, artifact, adapter/toolchain fingerprint, owner,
launch/attach 종류, 대상 process identity, capability snapshot, state, stoppedGeneration을 가진다.
Debugger service는 engine 소유이며 helper runner로 adapter를 실행한다. DAP protocol과 앱 IPC는 별개 transport다.
LLDB-DAP는 LLDB를 DAP client에 연결하며 macOS에서는 toolchain의 `lldb-dap` 발견 경로를 제공한다.
Swift 지원은 실제 선택 toolchain의 language integration까지 검사한다. [공식 LLDB-DAP](https://lldb.llvm.org/use/lldbdap.html)

상태: created → initializing → configuring → running ↔ stopped → terminating → ended; 오류는 failed/unknown으로 구분한다.
initialize capability 교환 뒤 launch/attach와 initialized/configurationDone 순서를 adapter 계약에 따라 처리한다.
source mapping, line/column 기준, URI/path, UTF-16 column, schema/메시지 크기·timeout을 adapter별 검증한다.
adapter의 `runInTerminal` 등 역방향 요청도 ToolBroker를 거치며 임의 process 실행을 직접 허용하지 않는다.
launch/attach는 composite handshake로 처리하며 부모 workspace write lease를 점유하지 않는다.
launch 응답 대기 중에도 event pump가 initialized/configurationDone·허가된 runInTerminal을 처리한다.
runInTerminal의 실제 process 시작 leaf만 필요한 lease를 얻고 receipt 후 해제한다. 내부 후속 요청은 같은
debugSession/owner/handshake revision에 묶어 검증하며 사용자 권한을 새로 부여하지 않는다.

| debugger operation | 필요한 계약 |
| --- | --- |
| launch | artifact·argv·cwd·환경·debug info·권한·process ownership 검증 |
| attach | PID뿐 아니라 시작 시각·실행 파일·사용자·대상 환경 확인; 외부 process 범위를 명시 |
| breakpoints | source/function/condition/hit count/exception/logpoint capability, requested와 verified 위치 구분 |
| threads/stack | thread ID, frame ID, source revision, pagination·최대 frame 수, 없는 source 표시 |
| scopes/variables | frame별 lazy expansion, pagination·출력 budget, 현재 stop에 속한 handle |
| continue/pause/next/stepIn/stepOut | 대상 thread와 all-threads 의미, 요청 이후 실제 stopped/continued event |
| evaluate | expression/context/frame, 효과 분류, timeout·결과 truncation·오류 |
| disconnect/stop | 소유한 launch와 외부 attach의 종료 정책 분리 |

client는 initialize에서 확인한 capability만 노출한다. 없는 flag를 지원으로 추정하지 않는다.
reverse step, memory write, register 변경, data breakpoint 등 추가 기능은 개별 검증 전 U다.
[DAP capability와 기본 흐름](https://microsoft.github.io/debug-adapter-protocol/overview)

## 6. 오래된 handle·부수효과·종료 경계

frame/scopes/variables reference는 `(debugSessionID, stoppedGeneration, adapterReference)`로 감싼다.
continue/step/restart/종료 시 generation을 무효화하고 늦게 도착한 이전 응답을 현재 상태로 표시하지 않는다.
재정지 후 같은 숫자의 reference가 와도 새 객체로 취급한다. snapshot은 열람 가능하지만 실행 가능한 handle이 아니다.
DAP의 중단 상태 reference 수명은 재개 시 끝난다. [공식 reference 수명](https://microsoft.github.io/debug-adapter-protocol/overview#lifetime-of-objects-references)

evaluate·condition·logpoint expression·getter/formatter는 실행 코드나 부수효과를 포함할 수 있다.
inspection과 arbitrary evaluation을 분리하며 Plan/읽기 전용 모드에서 임의 expression 실행·메모리 변경을 허용하지 않는다.
안전성이 입증되지 않은 자동 hover/watch/getter 평가도 실행 효과로 취급하고 기존 grant·시간·출력 제한을 적용한다.
`readOnly` 표시만으로 실제 부수효과 없음이 증명되었다고 간주하지 않는다.
Plan 진입은 launch/continue/step/evaluate 등 실행 제어를 차단하고 세션이 소유한 debuggee의 중지/정지 상태를
확인하는 barrier를 거친다. pause만으로 이미 발생한 파일 효과를 되돌렸다고 표시하지 않는다.
외부 attach 대상은 다른 사용자의 실행이므로 임의 종료하지 않는다. detach 뒤 그 대상의 지속 실행은
Lathe 세션의 읽기 전용 보장 밖이며, 외부 프로세스까지 정지시켰다고 주장하지 않는다.
[DAP variable/evaluate 계약](https://github.com/microsoft/debug-adapter-protocol/blob/main/specification.md)

Lathe가 launch한 process는 stop 정책에 따라 종료하되 external attach의 기본 stop은 detach이며 대상은 계속 실행한다.
external process 종료는 별도 명시적 작업이다. adapter 종료·DAP terminated·debuggee exited는 같은 상태가 아니다.
요청 cancel은 실제 process 중단과 다르며 확인 이벤트 전 취소 완료를 표시하지 않는다.
adapter crash 뒤 debuggee 생존을 확인하고 unknown을 표시한다. 재launch/재attach/이전 evaluate를 자동 replay하지 않는다.
재연결을 지원하지 않는 adapter는 새 세션으로 연결하며 breakpoint 설정은 새 capability와 source revision으로 재검증한다.
[DAP 종료 흐름](https://microsoft.github.io/debug-adapter-protocol/overview#debug-session-end), [cancel 명세](https://github.com/microsoft/debug-adapter-protocol/blob/main/specification.md#cancel-request)

## 7. UI·headless·Ultra 수용 게이트

UI는 실행 profile 선택, 준비 상태, diagnostic/test tree, source-linked breakpoint, thread/stack/variables, debug console을 제공한다.
headless는 같은 구조화 도구와 event를 사용한다. 질문/승인 client가 없으면 needsInput/needsApproval로 종료하고,
명시적으로 연결된 client를 기다리는 모드만 정해진 시간 안에서 대기한다.
Ultra의 child는 위임받은 debugSession만 접근하고 mutation/control owner는 하나다. 관찰자는 immutable snapshot을 읽는다.
한 agent가 step하는 중 다른 agent가 이전 frame으로 evaluate하지 못하도록 owner lease와 generation을 함께 검사한다.
debugger가 pause 상태여도 GUI 입력·agent 취소·다른 workspace 실행은 반응해야 한다.

| 게이트 | 실제 수용 조건 |
| --- | --- |
| 실행 재현 | Swift package와 일반 command 프로젝트에서 profile→build→test→run, 환경 차이·zero tests·partial 결과 검증 |
| worktree 준비 | 새 checkout→허용 include→dependency setup→ready, 중간 실패/재개·secret 비노출·source 보존 |
| DAP 기본 | Swift fixture launch→verified breakpoint→stack/scopes/variables→step→변경된 값→continue→exit |
| DAP 시작 재진입 | launch 응답 전 runInTerminal·initialized/configurationDone을 요구하는 adapter에서 leaf 실행과 후속 요청이 교착 없이 완료 |
| attach | 허용 process에 attach→pause/관찰→detach 후 대상 생존; PID 재사용·권한 거부 구분 |
| 복구·권한 | stale handle·adapter crash·timeout·취소·부수효과 evaluate 차단·owner 교대·headless 동일성 |

문서 snapshot과 실제 테스트한 OS/Xcode/LLDB-DAP version을 함께 고정한다. 최신 문서 표만으로 설치 adapter의 지원을 보장하지 않는다.
mock DAP fixture는 protocol 회귀용이며 실제 toolchain 통합 테스트와 분리한다. 미검증 플랫폼·언어·동작은 상태를 그대로 표시한다.
