# 개발·실행 가이드

2026-10-15. **M0 실행 기반과 M1의 첫 코딩 흐름 구현**. M1 전체와 기능 동등성은 미완료다.
사용 가능한 모델·권한·도구 계약은 [첫 코딩 흐름](coding-preview.md), 목표와 남은 순서는
[features.md](features.md)와 [roadmap.md](roadmap.md)를 따른다.

## 현재 제공하는 흐름

프로젝트 선택 → 모델 연결·권한 선택 → 스트리밍 → 도구 승인·실행 → 결과 전달 → 완료/취소·재접속.
SwiftUI/AppKit 앱과 CLI가 같은 Swift engine, SQLite와 blob 저장소를 사용한다.
기본 mock은 외부 API나 파일 도구를 호출하지 않는다. 실제 연결을 고르면 Responses 또는 Chat API와
list/read/write/run_command를 사용한다. Google·Claude 전용 adapter, 검색·MCP·Ultra·편집기·디버거는 후속이다.
프로젝트를 선택하는 것만으로 파일 수집이나 스크립트 실행을 시작하지 않는다.

| 관련 요구사항 | 현재 구현 | 남은 범위 |
| --- | --- | --- |
| LAT-CORE-001/002/006 | 실제 단일 모델/tool loop, 스트림·취소·재접속 | steering·retry·질문·context 관리 확대 |
| SESSION 계열 | 세션/run/event, context blob, 중복 submit 방지·복구 | fork/rewind/archive/export·실패한 작업 재개 |
| UI/CLI 계열 | 네이티브 연결 설정·Keychain 입력·승인 카드·CLI 공통 연결 | 편집기/PTY/diff/전체 결과 조회·접근성 검증 확대 |
| TOOL/EXEC/PERM 기반 | 네 도구·SHA 사전조건·일회 승인·runner journal | 검색·풍부한 편집·실행 profile·production 격리·background |

일부 구현은 각 LAT 요구사항의 전체 수용 기준 통과를 뜻하지 않는다.

## 빌드

최소 deployment target은 **macOS 15.0**, Swift 언어 모드는 **6**이다.
Swift 6을 제공하는 Xcode와 해당 Command Line Tools를 선택한다.
외부 Swift 패키지는 없으며 시스템 SQLite와 macOS Keychain을 사용한다.

```sh
Scripts/build-app.sh
open .build/macos/Lathe.app
```

출력은 현재 host 아키텍처용 `.build/macos/Lathe.app`, `lathe`, `lathe-engine`, `lathe-runner`다.
앱에는 `Contents/Helpers/lathe-engine`과 `lathe-runner`가 내장된다.
`--configuration release`, `--output`, `--scratch-path`, `--derived-data-path`를 지정할 수 있다.
개발용 ad-hoc 서명이며 Developer ID 서명·공증·universal 배포는 후속이다.

Xcode에서는 `Apps/Lathe/Lathe.xcodeproj`의 **Lathe** scheme을 **My Mac**으로 실행한다.
앱 target build phase가 engine/runner를 SwiftPM으로 빌드해 내장하므로 수동 복사가 필요 없다.
코어만 준비하려면 다음을 사용한다. 최초 `swift build`는 CLI와 engine/helper를 함께 준비한다.

```sh
swift build --package-path Packages/LatheKit
swift run --package-path Packages/LatheKit lathe --help
```

## 앱과 CLI 사용

앱에서 **프로젝트 열기**로 폴더를 고른다. `⌘,`의 **모델 연결**에서 profile을 저장하고 작성창에서
선택한다. 새 실행에 적용할 권한도 작성창에서 고른다. `⌘↩` 전송, `⌘.` 중단, 여러 줄 입력을 지원한다.
최신 run 네 개를 먼저 표시하고 **이전 대화 불러오기**로 이력을 조회한다.
도구 카드에는 정확한 요청 인자·실행 상태·결과 일부와 일회 승인/거절을 표시한다.
창이나 앱을 닫아도 엔진과 작업은 유지되며 명시적인 중단 명령으로 취소한다.

```sh
.build/macos/lathe status --json
.build/macos/lathe new --workspace "$PWD" "첫 작업"
.build/macos/lathe sessions --json
.build/macos/lathe run --session SESSION_UUID "모의 스트림을 확인해 줘"
.build/macos/lathe show SESSION_UUID --json
.build/macos/lathe events --session SESSION_UUID --after 0 --follow
```

실제 모델 설정과 `provider-set`, `tools`, `tool`, `approve/deny --hash` 예시는
[첫 코딩 흐름](coding-preview.md#cli)을 따른다. CLI에서 `--provider`를 생략하면 mock이고,
실제 모델의 기본 권한은 `dontAsk`다. 승인 모드 `manual/acceptEdits`는 `--detach`가 필요하다.

- `run --detach`는 접수된 run JSON을 반환한다. `cancel RUN_UUID`로 중단한다.
- `run --json`은 실행 이벤트를 NDJSON으로 출력한다. 이미 종료된 동일 요청은 run snapshot을 반환한다.
- `run` 중 Ctrl-C는 자신의 run을 취소하고 130으로 종료한다. `events --follow`의 Ctrl-C는 관찰만 끝낸다.
- 성공 exit 0, 오류·실패 1, 취소·중단 130이다.
- prompt는 인자 또는 UTF-8 stdin이며 최대 32 KiB다. title은 120자/512 UTF-8 bytes 이하다.
- 같은 session/request ID와 같은 prompt·설정으로 retry하면 기존 run을 반환한다. 다른 payload는 충돌이다.
- `show`는 최신 네 run과 총개수·다음 cursor를 제공한다. `show SESSION_UUID --before RUN_UUID`로 이전 페이지를 읽는다.
- `tools`는 최근 네 호출이며 `tool INVOCATION_UUID`로 개별 조회한다. 전체 raw blob 다운로드 UI/CLI는 아직 없다.

재접속은 요청을 재전송하지 않는다. 전송 결과가 불명확할 때는 기존 session/request ID로 조회한다.
확정된 거절과 연결 도중 결과를 받지 못한 경우를 구분한다.

## 프로세스·저장 경계

기본 데이터 경로는 `~/Library/Application Support/Lathe`다. `LATHE_DATA_DIR` 또는 CLI
`--data-dir /absolute/path`는 별도 엔진/DB를 선택한다. 엔진은 CLI `--engine` 또는
`LATHE_ENGINE_EXECUTABLE`로 지정하며 기본은 CLI 옆 파일이다. 앱은 내장 helper를 쓴다.

```text
SwiftUI/AppKit ─┐
               ├─ EngineClient ─ Unix socket ─ EngineRuntime actor ─ SQLite + blobs
lathe CLI ─────┘                              ├─ ModelClient ─ Responses / Chat HTTP
                                             └─ ToolBroker / Policy ─ files / native runner
```

- bootstrap/lifetime flock으로 data root별 engine과 DB writer를 단일화한다.
- 데이터/소켓 디렉터리는 0700으로 원자적으로 생성하고 기존 owner/type/mode를 검사한다.
- Unix socket은 root hash로 만든 짧은 사용자 임시 경로에 두며 0600과 peer UID를 검사한다.
- 독점 lease를 획득한 뒤 연결할 수 없는 stale socket만 정리한다. live socket을 임의 삭제하지 않는다.
- 엔진은 별도 process session으로 시작한다. 시작 오류는 0600 `startup.log`에 남긴다.
- profile 메타데이터는 SQLite, 키는 profile ID+Base URL에 묶인 Keychain 항목에 저장한다.
  설정 화면의 키는 다시 읽어 표시하지 않는다. API 키를 실행 환경에 자동 상속하지 않는다.
- 변경 전 내용·결과·model context는 SHA-256 blob으로 저장한다. `beforeBlobID`와 결과 `blobID`를 구분한다.
- 실행 전 tool state와 runner intent를 durable 기록한다. 재시작 시 대기/승인은 취소하고 실행 중 효과는
  `unknown`으로 남긴다. 진행 중 run은 `interrupted`이며 모델/도구를 자동 재실행하지 않는다.
- runner process group 정리는 OS sandbox가 아니다. 명시적으로 승인한 명령은 사용자 권한으로 실행한다.

빌드로 이미 실행 중인 엔진이 교체되지는 않는다. 현재 IPC는 **v2**, DB schema는 **v2**이며
v1 DB를 migration한다. 이전 엔진과 연결하면 버전 오류와 PID를 확인한 뒤 작업을 정리하고 해당 엔진을
`kill -TERM PID`로 종료해 다시 연결한다. client가 구버전 엔진을 자동 종료하지 않는다.
DB migration 후 구버전 바이너리로 되돌려 여는 동작은 지원하지 않는다.

## 구현 계약

| 모듈 | 책임 |
| --- | --- |
| LatheDomain | 세션/run/event, provider profile, 실행 설정, tool snapshot |
| LatheProtocol | JSON-RPC DTO·client·Unix transport·bootstrap/lease |
| LathePersistence | SQLite schema/migration·원자적 상태 저장·content-addressed blobs |
| LatheProviders | Responses/Chat codec·SSE·HTTP 취소/한도·credential port와 Keychain |
| LatheTools | 도구 schema·정책·경로/SHA 검사·runner bridge |
| LatheRuntime | actor·mock/실제 loop·승인·write lease·context·복구 |
| LatheEngine / LatheCLI | 별도 엔진과 RPC dispatch / headless 입력·조회·승인·SIGINT |
| LatheExecution / CLatheExecution | Swift 실행 수명·byte stream·입력/한도·POSIX spawn/PTY |
| LatheRunner | helper·NDJSON 제어·fsync intent/events/result journal |
| Apps/Lathe | SwiftUI/AppKit presentation·profile 설정·대화·승인·재연결 |

IPC는 4-byte big-endian 길이 + JSON, 프레임 최대 1 MiB, 요청당 한 연결/응답이다.
request ID와 protocol version을 검사하고 notifications/batch는 받지 않는다.
세션/submit/cancel/events 외에 profile 저장·조회, invocation 조회, 정확한 hash에 대한 승인 명령을 제공한다.
연결은 5초 제한·최대 16개 동시 handler이며 화면 스트리밍은 cursor polling이다.

세션에는 하나의 running run을 허용한다. run 생성·중복 요청 key·runStarted 이벤트, textDelta·response,
종료 event·state는 각각 transaction으로 저장한다. 취소가 commit된 뒤에는 delta를 추가하지 않는다.
SQLite는 WAL과 `synchronous=FULL`을 사용하며 `EngineRuntime` actor만 wrapper를 소유한다.
이벤트 sequence는 DB 전체에서 증가한다. session/run 필터를 적용해도 high-water cursor로 재접속한다.

같거나 겹치는 workspace의 변경 도구는 write lease를 사용한다. tool arguments/권한은 실행 중 바꾸지 않는다.
context는 바로 앞 완료 run의 동일 profile snapshot만 이어간다. 실패/중단/모델 변경 뒤에는 새 context다.
자동 compaction, token·비용 budget, 저장 데이터 retention과 checkpoint 복원은 아직 없다.

## 검증과 한계

```sh
swift test --package-path Packages/LatheKit
swift test --package-path Apps/Lathe
Scripts/build-app.sh
LATHE_TEST_RUNNER="$PWD/.build/macos/lathe-runner" swift test --package-path Packages/LatheKit --filter ToolTests
python3 Scripts/smoke-engine.py --bin-dir .build/macos
python3 Scripts/smoke-runner.py --runner .build/macos/lathe-runner
python3 Scripts/smoke-agent.py --bin-dir .build/macos --output .build/probes/agent.json
python3 Scripts/probe-sandbox.py --output .build/probes/sandbox.json
python3 Scripts/probe-lldb-dap.py --output .build/probes/lldb-dap.json
```

실제 OpenAI 호환 서버는 사용자가 지정할 때만 별도로 검사한다. 다음 probe는 인증 없는 서버를 대상으로
새 임시 프로젝트와 엔진을 만들고 합성 파일 읽기 → 정확한 수정 승인 → 고정 `printf` 승인 → 최종 응답을 확인한다.
기존 연결·프로젝트·API 키를 사용하지 않으며 CI에서 자동 실행하지 않는다.

```sh
python3 Scripts/probe-provider.py --bin-dir .build/macos \
  --base-url http://SERVER:8000/v1 --model MODEL_ID --allow-http \
  --output .build/probes/live-provider.json
```

HTTPS에서는 `--allow-http`를 생략한다. probe는 최대 180초·8 model steps로 제한하고,
지정한 합성 파일 수정과 단일 `printf` 외의 변경 요청은 거절한 뒤 중단한다.
보고서에는 검사 결과·도구 상태만 기록하며 응답·추론·세션 transcript는 저장하지 않는다.

테스트에는 실제 API 키가 필요 없다. smoke는 임시 프로젝트와 데이터, localhost HTTP fixture를 사용하며
기본 앱 데이터와 개인 프로젝트를 사용하지 않는다. 테스트 전체 개수와 최종 CI 결과는 해당 commit의 실행 결과를 따른다.

- 저장/전송 테스트는 transaction rollback·중복 방지·migration·복구·pagination·프레임 한도·취소·lease를 검사한다.
- provider 계약 테스트는 split SSE·tool 왕복·opaque reasoning/continuation·종료 상태를 검사한다.
- Chat의 `reasoning`과 이전 `reasoning_content`는 원래 필드명을 유지해 다음 도구 왕복에 전달한다.
  두 필드 합산 UTF-8 1 MiB 한도와 잘못된 타입 거절을 검사한다.
- tool 테스트는 경로·SHA·권한·승인 지연 뒤 cwd 교체·raw byte·timeout·취소·receipt 누락과 journal 재사용 금지를 검사한다.
- 실제 HTTP 통합 fixture의 9개 검사가 로컬에서 통과했다. 공통 engine/CLI/runner를 통해
  read→승인된 write→승인된 shell→최종 응답, hash 불일치·중복 요청, Plan/dontAsk/거절,
  중간 EOF, 대기·shell·HTTP 취소, Responses reasoning replay, HTTP 307 redirect 거절을 확인했다.
- 별도 live probe는 원격 vLLM 0.27.1의 Qwen 계열 모델 한 구성에서 6개 검사를 통과했다.
  [실제 서버 검사](probes/provider.md)는 합성 파일 편집과 고정 명령 왕복까지이며 다른 구성, OpenAI 계정과 Ollama는 미검증이다.
  Keychain 구현과 메모리 credential fixture 검증도 실제 사용자 키로 API를 호출한 검증과 구분한다.
- 앱 모델 테스트는 `Apps/Lathe/Package.swift`의 별도 harness다. native 앱 build와 실제 화면 조작 검증은 따로 기록한다.
- native 조작 검증은 프로젝트·mock 입력·중단·재접속·이력·Settings 흐름을 포함한다. 새 연결 설정 저장과 모델·권한 선택 화면도 확인했다. 격리된 프로젝트와 localhost fixture에서 앱의 일회성 파일 수정 승인 → 명령 승인 → 최종 응답 완료를 확인했다. 실제 API 키 저장은 이 조작 검증에 포함하지 않았다.
- 로컬 환경은 macOS 27.0.1 / Xcode 27.0 / Swift 6.4 / Apple Silicon이다. deployment target 15 빌드와
  macOS 15 실제 앱 실행 검증은 구분하며 후자는 미검증이다. 원격 CI 성공은 실행 결과 확인 후 보고한다.
- [sandbox probe](probes/sandbox.md)는 host fixture 7개 통과지만 deprecated backend 실험이며 production 격리는 없다.
- [LLDB-DAP probe](probes/lldb-dap.md)는 컴파일·initialize 성공, 실제 launch/attach timeout으로 실패 상태다.
  CI의 수동 `debugger_probe`는 timeout을 실패로 기록하고 명시적인 환경 제한만 unsupported로 구분한다.

다음 M1 단위는 코드/웹 검색, 편집·변경 미리보기, 실행 profile과 테스트 증거, budget·모델 capability다.
debugger timeout과 production sandbox는 독립된 미완료 게이트로 추적한다.
