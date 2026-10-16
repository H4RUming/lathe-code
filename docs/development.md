# 개발·실행 가이드

2026-10-16. **단일 앱 수명으로 통합한 M0 실행 기반과 M1의 첫 코딩 흐름 구현**. M1 전체와 기능 동등성은 미완료다.
사용 가능한 모델·권한·도구 계약은 [첫 코딩 흐름](coding-preview.md), 목표와 남은 순서는
[features.md](features.md)와 [roadmap.md](roadmap.md)를 따른다.

## 현재 제공하는 흐름

프로젝트 선택 → 모델 연결·권한 선택 → 스트리밍 → 도구 승인·실행 → 결과 전달 → 완료/취소·재접속.
SwiftUI/AppKit 앱 프로세스 안의 EngineHost가 runtime, SQLite와 blob 저장소를 소유한다.
개발용 CLI는 실행 중인 앱에 연결하는 선택 도구이며 일반 배포/설치 구성 요소가 아니다.
기본 mock은 외부 API나 파일 도구를 호출하지 않는다. 실제 연결을 고르면 Responses 또는 Chat API와
list/read/write/run_command와 파일명·내용 검색을 사용한다. Google·Claude 전용 adapter, 웹 검색·MCP·Ultra·편집기·디버거는 후속이다.
프로젝트를 선택하는 것만으로 파일 수집이나 스크립트 실행을 시작하지 않는다.

| 관련 요구사항 | 현재 구현 | 남은 범위 |
| --- | --- | --- |
| LAT-CORE-001/002/006 | 실제 단일 모델/tool loop, 스트림·취소·재접속 | steering·retry·질문·context 관리 확대 |
| SESSION 계열 | 세션/run/event, context blob, 중복 submit 방지·복구 | fork/rewind/archive/export·실패한 작업 재개 |
| UI/CLI 계열 | 네이티브 연결 설정·Keychain 입력·승인 카드·개발 client 공통 연결 | 편집기/PTY/diff/전체 결과 조회·접근성 검증 확대 |
| TOOL/EXEC/PERM 기반 | 여섯 도구·bounded 코드 검색·SHA 사전조건·일회 승인·runner journal | 정규식/ignore·웹 검색·풍부한 편집·실행 profile·production 격리·background |

일부 구현은 각 LAT 요구사항의 전체 수용 기준 통과를 뜻하지 않는다.

## 앱 문구와 현지화

앱의 고정 표시 문구는 `LatheLocalization`의 한국어·영어 `.strings` 리소스에서 관리한다.
`Interface`는 화면·설정·권한·도구 상태 등 UI 문구를, `AppMessages`는 연결 상태·오류 안내·프로젝트 선택
패널·종료 경고·백그라운드 메뉴를 담는다. 버튼뿐 아니라 tooltip과 접근성 설명도 같은 경로를 사용한다.
Swift 코드는 일반 문구의 `L10n.text/format`과 오류 문구의 `L10n.errorText/errorFormat`에
문장 대신 의미를 나타내는 key와 table을 전달한다.
예를 들어 `app.error.connectionFailed`는 한국어와 영어의 전체 오류 안내 문장을 보유하며 원래 오류는
`%@`로 삽입한다. 단어·문장 조각 연결로 어순을 고정하지 않는다.

코어에서 만드는 오류도 같은 리소스 경로를 사용한다. `DomainErrors`, `ProviderErrors`, `ProtocolErrors`,
`HostErrors`, `StorageErrors`, `ExecutionErrors`는 검증·연결·저장·실행 오류를 담고, `RuntimeMessages`,
`ToolMessages`, `RunnerMessages`, `CLIMessages`는 승인·복구·도구 요약·mock 응답·개발 도구 안내를 담는다.
한국어·영어에 같은 key와 호환되는 placeholder를 유지한다. 설정의 일반 탭에서 **앱 언어**는 시스템 설정/
한국어/영어, **오류 메시지 언어**는 앱 언어와 같게/시스템 설정/한국어/영어 중 각각 선택한다.
기본값은 앱 언어가 시스템 설정, 오류 언어가 앱 언어와 같게이며 두 선택은 함께 저장되어 재시작 후 복원된다.
일반 문구는 `L10n.text/format`, 오류와 오류 안의 고정 설명은 `L10n.errorText/errorFormat`을 사용한다.
한국어 표시 자체가 하드코딩을 뜻하지 않으며, 지원하지 않는 명시적 locale과 누락 번역은 한국어로 fallback한다.
앱 소유 화면과 메뉴는 선택 직후 갱신하지만 초안·실행·설정 입력을 다시 만들지 않는다.
OS가 소유하는 기본 메뉴 항목과 패널 내부 문구는 운영체제의 언어를 따른다.

서버·OS·SQLite의 원문 진단, 사용자 입력, 모델 응답, 명령 출력, 모델용 지시문과 protocol 식별자는
그대로 유지한다. errno·HTTP 상태·프로토콜 버전·PID 같은 진단값도 숫자 서식을 바꾸지 않고 전달한다.
따라서 원문 진단의 언어는 앱과 다를 수 있다. DB의 기존 이벤트와 실행 결과는 생성 당시 문자열을
보존하며, 언어 변경 후 과거 기록이나 이미 표시된 오류를 재번역하지 않는다. 오류 언어 변경은 새 오류부터 적용한다.

번역 번들은 `.app/Contents/Resources`에 하나만 포함한다. `Contents/Helpers/lathe-runner`도 이 번들을
찾고 `LATHE_DISPLAY_LANGUAGE`와 `LATHE_ERROR_LANGUAGE`로 앱/오류 언어를 각각 전달받는다.
대상 명령의 환경은 변경하지 않는다. 선택적인 개발 빌드에만 실행 파일
옆에 번역 번들을 추가하며, 기본 앱 빌드에서는 이 개발용 복사본을 제거한다.

`python3 Scripts/check-localization.py`는 한국어·영어 table/key 일치, 중복 key, format 인자 타입,
앱과 전체 Swift 코어 호출의 누락 key, 고정 UI 문구와 알려진 오류 표시 지점의 문자열을 검사한다.
정적 검사는 Swift 컴파일러를 대신하지 않으므로 새 표시 API를 추가할 때 검사 범위도 확인한다.
`Scripts/test-localization.py`는 영문·한글 오류 하드코딩을 실제로 거부하는지 검사한다.
코어 테스트는 두 언어로 실제 오류를 발생시키며 진단값과 원문 보존도 확인한다.
`Scripts/smoke-localization.py --bin-dir .build/macos`는 개발 빌드를 별도 임시 위치로 복사한 후,
앱 내부 helper와 개발 도구의 두 언어 오류·도움말 및 번들 포함 여부를 확인한다. 이 검증들은 CI에서도 실행한다.

## 빌드

최소 deployment target은 **macOS 15.0**, Swift 언어 모드는 **6**이다.
Swift 6을 제공하는 Xcode와 해당 Command Line Tools를 선택한다.
외부 Swift 패키지는 없으며 시스템 SQLite와 macOS Keychain을 사용한다.

```sh
Scripts/build-app.sh
open .build/macos/Lathe.app
```

기본 출력은 현재 host 아키텍처용 **`.build/macos/Lathe.app` 하나**다.
앱에는 실행에 필요한 `Contents/Helpers/lathe-runner`만 내장한다. runtime과 DB writer는 앱 안에서 실행한다.
독립 `lathe-engine`, CLI, 로그인 agent를 사용자 시스템에 설치하지 않는다.
`--configuration release`, `--output`, `--scratch-path`, `--derived-data-path`를 지정할 수 있다.
개발용 ad-hoc 서명이며 Developer ID 서명·공증·universal 배포는 후속이다.

Xcode에서는 `Apps/Lathe/Lathe.xcodeproj`의 **Lathe** scheme을 **My Mac**으로 실행한다.
앱 target은 EngineHost library를 link하고 build phase는 runner만 내장한다.
CLI와 독립 테스트 engine이 필요할 때만 개발 도구를 추가 빌드한다.

```sh
Scripts/build-app.sh --developer-tools
swift test --package-path Packages/LatheKit
```

opt-in 출력에는 `lathe`, `lathe-engine`, `lathe-runner`가 추가된다. 이 파일들은 개발 디렉터리에만
생성하며 PATH·로그인 항목·시스템 서비스에 등록하지 않는다. 다시 기본 빌드를 하면 해당 출력 디렉터리의
이전 standalone 실행 파일을 제거한다. CI는 검증용 도구를 빌드하되 배포 artifact에는 앱 ZIP만 담는다.

## 앱과 개발 client 사용

앱에서 **프로젝트 열기**로 폴더를 고른다. `⌘,`의 **모델 연결**에서 profile을 저장하고 작성창에서
선택한다. 새 실행에 적용할 권한도 작성창에서 고른다. `⌘↩` 전송, `⌘.` 중단, 여러 줄 입력을 지원한다.
최신 run 네 개를 먼저 표시하고 **이전 대화 불러오기**로 이력을 조회한다.
도구 카드에는 정확한 요청 인자·실행 상태·결과 일부와 일회 승인/거절을 표시한다.
진행 중 작업이나 미전송 입력이 있을 때 마지막 작업 창 닫기·종료에서는
**중단 후 종료 / 백그라운드 유지 / 취소**를 선택한다. 미완료 작업이 없으면 바로 종료한다.
백그라운드 유지에서는 앱 프로세스가 계속 실행되며 메뉴 막대에서 다시 열거나 종료할 수 있다. 별도 daemon으로 옮기지 않는다.
정상 종료는 HTTP와 runner 정리 및 socket 해제까지 기다린다.

아래 명령은 opt-in 개발 도구를 빌드하고 Lathe 앱을 실행한 상태에서 사용한다. 기본 client는 앱이 없으면
연결 오류로 끝나며 독립 engine을 자동 시작하지 않는다.

```sh
.build/macos/lathe status --json
.build/macos/lathe new --workspace "$PWD" "첫 작업"
.build/macos/lathe sessions --json
.build/macos/lathe run --session SESSION_UUID "모의 스트림을 확인해 줘"
.build/macos/lathe show SESSION_UUID --json
.build/macos/lathe events --session SESSION_UUID --after 0 --follow
```

실제 모델 설정과 `provider-set`, `tools`, `tool`, `approve/deny --hash` 예시는
[첫 코딩 흐름](coding-preview.md#개발-client)을 따른다. CLI에서 `--provider`를 생략하면 mock이고,
실제 모델의 기본 권한은 읽기까지 승인하는 `requestApproval`이다. `requestApproval/autoApprove/acceptEdits`는
승인 대기가 가능하므로 `--detach`가 필요하며, 명시적으로 선택한 `fullAccess`만 `--detach` 없이 실행할 수 있다.
Auto는 일반 소스·문서 경로와 인자 없는 `/bin/pwd`에 대한 좁은 결정 규칙이며 그 외 호출은 승인한다.
Plan은 권한 모드가 아니고 `dontAsk`는 새 실행에서 제공하지 않는다. 이전 `manual/plan/dontAsk` 기록은
`requestApproval`로 보수적으로 읽으며 실행을 자동 재개하지 않는다.

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

기본 데이터 경로는 `~/Library/Application Support/Lathe`다. 격리된 앱 검증은 앱 프로세스의
`LATHE_DATA_DIR`를 지정한다. 개발 client의 `--root /absolute/path`는 그 앱 데이터 root에 연결한다.
client는 `LATHE_ENGINE_EXECUTABLE`이나 이웃 실행 파일을 발견했다고 engine을 시작하지 않는다.

```text
Lathe.app process: SwiftUI/AppKit → EngineClient → EngineHost / IPC → EngineRuntime
                                                                 ├─ SQLite + blobs
optional dev client ──────────────── local IPC ────────────────────┤
                                                                 ├─ ModelClient / HTTP
                                                                 └─ ToolBroker → bundled runner
```

- 앱 내부 EngineHost가 data root의 독점 lease를 얻은 뒤 runtime과 DB를 연다. handshake PID는 앱 PID다.
- 같은 root를 이미 소유한 프로세스가 있으면 앱은 충돌을 표시한다. 다른 standalone engine에 몰래 attach하지 않는다.
- 데이터/소켓 디렉터리는 0700으로 원자적으로 생성하고 owner/type/mode를 검사한다.
- Unix socket은 root hash로 만든 사용자 임시 경로에 두며 0600과 peer UID를 검사한다.
  stale socket은 독점 lease 아래에서만 정리한다.
- 종료 시 새 요청 수락을 멈추고 HTTP·runner를 취소/정리한 뒤 socket·lease를 해제한다.
- profile 메타데이터는 SQLite, 키는 profile ID+Base URL에 묶인 Keychain 항목에 저장한다.
  저장된 키는 화면에 다시 표시하거나 실행 환경에 자동 상속하지 않는다.
- 변경 전 파일 내용은 쓰기 승인 결정 후 실행 직전에 읽어 SHA-256 blob으로 저장한다. 결과·model context도 blob으로 보존하며 `beforeBlobID`와 결과 `blobID`를 구분한다.
- 실행 전 상태와 runner intent를 durable 기록한다. 재시작 시 대기/승인은 취소하고 실행 중 효과는
  `unknown`, 진행 중 run은 `interrupted`로 남기며 모델/도구를 자동 재실행하지 않는다.
- runner의 process group 정리는 OS sandbox가 아니다. 승인된 명령은 사용자 권한으로 실행한다.
- 앱 bundle을 삭제하면 포함된 실행 파일도 제거된다. Application Support의 세션·설정과 Keychain 항목은
  사용자 데이터로 남을 수 있다. 데이터 잔존을 실행 중인 engine이나 설치된 서비스로 표현하지 않는다.

독립 engine은 앱 없는 CI fixture를 위한 개발 harness로만 남긴다. 실행 파일과 격리 root를 모두 명시한다.

```sh
.build/macos/lathe --developer-engine "$PWD/.build/macos/lathe-engine" \
  --root /absolute/test-data status --json
```

이 모드의 독립 프로세스는 probe가 소유·정리한다. 일반 앱이나 기본 CLI 경로에는 적용하지 않는다.
현재 IPC/DB schema는 v2이며 v1 DB를 migration한다. 과거 개발 빌드의 standalone engine이 이미 해당
root를 소유하면 새 앱은 시작 충돌을 표시한다. 그 테스트 프로세스를 확인해 종료한 뒤 앱을 다시 연다.
앱 교체 빌드가 현재 앱이나 예전 프로세스를 자동으로 죽이지 않으며 구버전 DB downgrade는 지원하지 않는다.

## 구현 계약

| 모듈 | 책임 |
| --- | --- |
| LatheDomain | 세션/run/event, provider profile, 실행 설정, tool snapshot |
| LatheProtocol | JSON-RPC DTO·client·Unix transport·bootstrap/lease |
| LathePersistence | SQLite schema/migration·원자적 상태 저장·content-addressed blobs |
| LatheProviders | Responses/Chat codec·SSE·HTTP 취소/한도·credential port와 Keychain |
| LatheTools | 도구 schema·정책·경로/SHA 검사·runner bridge |
| LatheRuntime | actor·mock/실제 loop·승인·write lease·context·복구 |
| LatheEngineHost | 앱 내부 runtime·RPC listener·lease·종료 수명 |
| LatheEngine / LatheCLI | opt-in 독립 테스트 harness / 실행 중 앱에 attach하는 개발 client |
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

2026-10-16 언어 설정 분리·코드 검색 검증: 코어 119개·앱 상태 23개 테스트, 네이티브 빌드,
localhost agent fixture 13개와 이동된 helper의 한국어/영어 혼합 설정 검사가 통과했다.
검색에는 네 모드 왕복·승인 전 비노출·링크/root 교체·UTF-8·페이지/작업량 한도 검사를 포함한다.
격리된 실제 앱에서 화면 언어 전환·미저장 연결 폼 보존·앱 영어/오류 한국어 선택과 재실행 복원을 확인했다.

2026-10-16 권한 개편 검증: 코어 84개·앱 모델 19개 테스트, 네이티브 앱 빌드,
localhost agent fixture 11개와 격리된 실제 앱 수명 검사 4개가 통과했다.
전체 권한/자동 승인/편집 허용/승인 요청과 읽기 승인 전 비노출·baseline 저장 경계를 포함한다.
이 검증에는 외부 모델 서비스나 사용자 프로젝트를 사용하지 않았다.

```sh
swift test --package-path Packages/LatheKit
swift test --package-path Apps/Lathe
Scripts/build-app.sh --developer-tools
python3 Scripts/smoke-app.py --bin-dir .build/macos --output .build/probes/app-lifecycle.json
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
- 초기 권한 구현 시 실제 HTTP 통합 fixture의 9개 검사가 로컬에서 통과했다. 개발 harness의 같은 runtime/CLI/runner를 통해
  read→승인된 write→승인된 shell→최종 응답, hash 불일치·중복 요청·권한 거절,
  중간 EOF, 대기·shell·HTTP 취소, Responses reasoning replay, HTTP 307 redirect 거절을 확인했다.
  네 모드로 바꾼 뒤의 정책·저장 호환·HTTP 왕복 회귀 결과는 변경 후 실행 보고서로 별도 확인한다.
- 별도 live probe는 원격 vLLM 0.27.1의 Qwen 계열 모델 한 구성에서 6개 검사를 통과했다.
  [실제 서버 검사](probes/provider.md)는 합성 파일 편집과 고정 명령 왕복까지이며 다른 구성, OpenAI 계정과 Ollama는 미검증이다.
  Keychain 구현과 메모리 credential fixture 검증도 실제 사용자 키로 API를 호출한 검증과 구분한다.
- `smoke-app.py`는 실제 앱 PID와 runtime PID 일치, idle 종료·socket 해제, 강제 종료 뒤 runner 정리·재시작 복구,
  앱 없는 기본 CLI의 자동 spawn 금지를 검사한다. 기존 사용자 앱과 충돌하지 않도록 임시 복사본에 고유 bundle ID와
  ad-hoc 서명을 적용한다. 2026-10-16 로컬 macOS 27에서 네 검사가 통과했다.
- 같은 로컬 환경에서 코어 78개(실제 runner 종료 포함)와 앱 모델 18개 테스트가 통과했다.
  네이티브 창 닫기·⌘Q 경고, 취소 후 초안 보존, 백그라운드 accessory 전환·재열기와 정상 종료를 별도 임시 앱에서 확인했다.
- 앱 모델 테스트는 `Apps/Lathe/Package.swift`의 별도 harness다. native 앱 build와 실제 화면 조작 검증은 따로 기록한다.
- native 조작 검증은 프로젝트·mock 입력·중단·재접속·이력·Settings 흐름을 포함한다. 새 연결 설정 저장과 모델·권한 선택 화면도 확인했다. 격리된 프로젝트와 localhost fixture에서 앱의 일회성 파일 수정 승인 → 명령 승인 → 최종 응답 완료를 확인했다. 실제 API 키 저장은 이 조작 검증에 포함하지 않았다.
- 로컬 환경은 macOS 27.0.1 / Xcode 27.0 / Swift 6.4 / Apple Silicon이다. deployment target 15 빌드와
  macOS 15 실제 앱 실행 검증은 구분하며 후자는 미검증이다. 원격 CI 성공은 실행 결과 확인 후 보고한다.
- [sandbox probe](probes/sandbox.md)는 host fixture 7개 통과지만 deprecated backend 실험이며 production 격리는 없다.
- [LLDB-DAP probe](probes/lldb-dap.md)는 컴파일·initialize 성공, 실제 launch/attach timeout으로 실패 상태다.
  CI의 수동 `debugger_probe`는 timeout을 실패로 기록하고 명시적인 환경 제한만 unsupported로 구분한다.

`find_files`와 `search_content`는 앱 내부에서 제한된 파일명 glob·일반 문자열 검색을 수행한다.
자동 승인에서도 재귀 검색은 승인받고, 결과에는 제외 범위·페이지·작업량 한도를 명시한다.
입력·출력·미지원 정규식/ignore 범위는 [코드 검색 계약](coding-preview.md#프로젝트-코드-검색)을 따른다.

다음 M1 단위는 코드 검색 확장·웹 검색, 편집·변경 미리보기, 실행 profile과 테스트 증거, budget·모델 capability다.
debugger timeout과 production sandbox는 독립된 미완료 게이트로 추적한다.
