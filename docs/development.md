# M0 개발·실행 가이드

2026-10-15. **M0 일부 구현**이며 실제 coding loop의 완료가 아니다.
목표 요구사항은 [features.md](features.md), 남은 순서는 [roadmap.md](roadmap.md)를 따른다.

## 현재 제공하는 흐름

프로젝트 폴더 선택 → 세션 생성 → mock 요청 → 스트리밍 → 완료/취소 → 재접속·이력 복원.
SwiftUI/AppKit 앱과 CLI가 동일한 Swift engine 프로세스와 SQLite 데이터를 사용한다.
실제 provider, 파일·shell 도구, 검색, MCP, reasoning/Ultra, 편집기와 디버거는 아직 구현하지 않았다.
프로젝트 선택은 경로를 세션에 연결하며 파일 수집·스크립트 실행을 시작하지 않는다.

| 관련 요구사항 | 이번 구현 | 남은 범위 |
| --- | --- | --- |
| LAT-CORE-001/002/006 | mock 스트림·취소·재접속 기반 | 실제 모델/tool loop·권한·retry·steering |
| SESSION 계열 | 세션·run·이벤트 저장, 이력 페이지, 중복 submit 방지 | fork/rewind/archive/export·작업 복구 확장 |
| UI/CLI 계열 | 네이티브 창·프로젝트 선택·대화·초안·CLI 공통 연결 | 편집기/PTY/diff/검사 화면·완전한 접근성 검증 |

표의 기반 구현은 각 LAT 요구사항의 전체 수용 기준 통과를 뜻하지 않는다.

## 빌드

최소 deployment target은 **macOS 15.0**, Swift 언어 모드는 **6**이다.
Swift 6을 제공하는 Xcode와 해당 Command Line Tools를 선택한다.
외부 Swift 패키지는 없으며 시스템 SQLite를 C module로 연결한다.

```sh
Scripts/build-app.sh
open .build/macos/Lathe.app
```

출력:

- `.build/macos/Lathe.app`: 현재 host 아키텍처의 네이티브 개발 앱.
- `.build/macos/lathe`: CLI.
- `.build/macos/lathe-engine`: CLI가 시작하는 엔진.
- 앱에도 `Contents/Helpers/lathe-engine`이 내장된다.

`--configuration release`로 release configuration을 선택한다.
`--output`, `--scratch-path`, `--derived-data-path`로 빌드 위치를 바꿀 수 있다.
앱은 개발용 ad-hoc 서명이며 Developer ID 서명·공증·universal 배포는 후속이다.

Xcode에서 `Apps/Lathe/Lathe.xcodeproj` → **Lathe** scheme → **My Mac**으로 실행할 수도 있다.
앱 target의 build phase가 engine을 SwiftPM으로 빌드해 내장하므로 Xcode Run에서도 별도 수동 복사가 필요 없다.

코어만 빌드하려면:

```sh
swift build --package-path Packages/LatheKit
swift run --package-path Packages/LatheKit lathe --help
```

`swift run`은 선택 product만 빌드할 수 있으므로 최초에는 위 `swift build`로 CLI와 engine을 모두 준비한다.

## 앱과 CLI 사용

앱에서 **프로젝트 열기**로 폴더를 선택한다. 한글을 포함한 여러 줄 입력을 지원하며
`⌘↩`로 전송, `⌘.`으로 현재 실행 중단, `⌘,`로 엔진 설정을 연다.
최신 실행 4개를 먼저 표시하고 **이전 대화 불러오기**로 오래된 이력을 조회한다.
mock 모드와 실행 상태를 화면에 표시한다. 창을 닫거나 앱을 종료해도 엔진과 작업은 유지된다.

```sh
.build/macos/lathe status --json
.build/macos/lathe new --workspace "$PWD" "첫 작업"
.build/macos/lathe sessions --json
.build/macos/lathe run --session SESSION_UUID "설명을 스트리밍해 줘"
.build/macos/lathe show SESSION_UUID --json
.build/macos/lathe events --session SESSION_UUID --after 0 --follow
```

- `run --detach`는 접수된 run JSON을 반환한다. `cancel RUN_UUID`로 해당 run을 중단한다.
- `run --json`은 새 실행의 이벤트를 NDJSON으로 출력한다. 이미 종료된 요청의 idempotent retry는 run snapshot을 출력한다.
- `run` 중 Ctrl-C는 자신의 run을 취소하고 130으로 종료한다. `events --follow` 중 Ctrl-C는 관찰만 종료한다.
- 성공은 exit 0, 명령·전송 오류는 1, 실행 취소·중단은 130이다.
- `run`은 인자 또는 UTF-8 stdin을 받으며 최대 32 KiB다. title은 120자/512 UTF-8 bytes 이하다.
- 동일 `--session`과 `--request-id` 및 동일 prompt로 retry하면 기존 run을 반환한다. payload가 다르면 충돌 오류다.
- `show`는 최신 4개와 총개수·다음 cursor를 제공한다. `show SESSION_UUID --before RUN_UUID`로 이전 페이지를 읽는다.
- `sessions`는 모든 세션의 metadata를 반환하며 대화 본문은 `show`에서 조회한다.

재접속은 요청을 재전송하지 않는다. 전송 결과가 불명확하면 기존 session/request ID로 조회·retry해야 한다.
서버가 접수를 거절한 확정 오류와 전송 도중 연결이 끊긴 경우를 구분한다.

## 프로세스·저장 경계

기본 데이터 경로는 `~/Library/Application Support/Lathe`다. `LATHE_DATA_DIR` 또는
CLI `--data-dir /absolute/path`를 지정하면 별도 엔진과 DB로 격리할 수 있다.
엔진 실행 파일은 CLI `--engine`/`LATHE_ENGINE_EXECUTABLE`로 지정 가능하며 기본은 CLI 옆 파일이다.
앱은 bundle에 내장된 helper를 사용한다.

```text
SwiftUI/AppKit ─┐
               ├─ EngineClient ─ Unix socket ─ EngineRuntime actor ─ SQLite WAL
lathe CLI ─────┘                              └─ deterministic mock stream
```

- 데이터 루트별 bootstrap flock은 동시 시작을 직렬화한다. 별도 lifetime flock을 DB 열기 전에 획득한다.
- 데이터/소켓 디렉터리는 원자적으로 0700 생성한다. 기존 경로의 owner/type/mode가 다르면 오류를 반환한다.
- Unix socket은 data root hash로 짧은 사용자 임시 경로에 배치하며 0600과 peer UID를 확인한다.
- live socket을 임의 삭제하지 않는다. 독점 lease를 획득한 뒤 연결 불가능한 stale socket만 정리한다.
- 엔진은 별도 process session으로 시작한다. 시작 오류는 데이터 루트의 0600 `startup.log`에 남긴다.
- 엔진 교체 빌드는 이미 실행 중인 프로세스를 교체하지 않는다. 개발 중에는 앱을 종료한 후
  `lathe status`의 PID를 확인해 `kill -TERM PID`로 해당 엔진을 종료하고 다시 접속한다.
- engine 종료 시 running 작업은 다음 시작에서 `interrupted`로 한 번만 기록한다. 자동 재실행하지 않는다.
- OS sandbox/runner 격리는 아직 없다. 현재 파일 변경·외부 명령 도구가 없는 단계이며 경로 권한 검사를 OS 격리로 표시하지 않는다.

## 구현 계약

| 모듈 | 책임 |
| --- | --- |
| LatheDomain | Session/Run/Event/EngineInfo와 오류 타입 |
| LatheProtocol | JSON-RPC DTO·client·Unix transport·bootstrap/lease |
| LathePersistence | SQLite statement binding·schema v1·transaction·paged projections |
| LatheRuntime | actor 직렬화·mock worker·submit/cancel·시작 시 복구 |
| LatheEngine | 별도 process entry·RPC dispatch·종료 signal |
| LatheCLI | headless 입력·출력·현재 run 관찰·SIGINT |
| Apps/Lathe | SwiftUI/AppKit presentation·선택/초안·재연결·상태 projection |

IPC v1은 길이 4-byte big-endian + JSON, 프레임 최대 1 MiB, 요청당 한 연결/한 응답이다.
request의 string ID와 `params.protocolVersion`을 검사한다. 지원 명령은 `handshake`, `sessions`,
`session`, `createSession`, `submit`, `cancel`, `events`다. notifications/batch는 지원하지 않는다.
연결은 5초 제한과 최대 16개 동시 handler를 적용한다. streaming은 현재 cursor polling이다.

세션당 하나의 running run을 허용한다. requestID는 DB 전체에서 유일하며 run 생성·request key·
runStarted 이벤트를 같은 transaction에 저장한다. textDelta·response 갱신과 종료 event·state 갱신도
각각 원자적이다. 취소가 commit된 후에는 delta를 추가하지 않는다.
WAL과 `synchronous=FULL`을 사용하며 SQLite wrapper는 `EngineRuntime` actor만 소유한다.

이벤트 sequence는 DB 전체에서 단조 증가한다. session/run 필터와 limit를 지원하며, 페이지가 가득 차면
마지막 반환 sequence, 그 외에는 조회 시점 high-water까지 cursor를 전진시킨다.
CLI는 현재 run으로 필터링하여 오래된 대화 이벤트를 모두 내려받지 않는다.
세션 목록은 immutable rowid 역순 metadata 페이지, 대화는 최신 run부터 페이지 조회 후 시간순 표시한다.
출력·snapshot blob 저장소와 retention 정책은 후속 구현이다.

## 검증과 현재 한계

```sh
swift test --package-path Packages/LatheKit
swift test --package-path Apps/Lathe
Scripts/build-app.sh
python3 Scripts/smoke-engine.py --bin-dir .build/macos
```

테스트는 API 키가 필요 없다. smoke는 임시 프로젝트/데이터로 실제 engine을 시작하고
명령줄 identity를 확인한 해당 테스트 PID만 종료한다. 기본 앱 데이터와 프로젝트는 사용하지 않는다.

- Swift tests: 원자적 저장/실패 rollback, cancel, idempotency, recovery, pagination/최대 입력,
  run 필터 replay, frame 분할/상한/timeout/cancellation, socket·lease·동시 경로 생성.
- 앱 모델 회귀 테스트는 `Apps/Lathe/Package.swift`의 별도 test harness로 실행하며 Xcode 앱 빌드와 분리한다.
  현재 코어 22개, 앱 모델 6개 테스트(매개변수 사례 포함 7건)가 로컬에서 통과했다.
- process smoke: 6개 CLI 동시 bootstrap, RPC 오류, 중복/충돌, 스트림과 저장 결과 일치,
  Ctrl-C, 페이지 이력, SIGKILL 후 stale socket/미완료 복구, sequence replay, 입력 한도,
  SIGTERM 정상 종료 후 socket 정리를 최종 개발 바이너리로 검증했다.
- native manual: 프로젝트 선택, 한글 여러 줄 전송, 완료·중단, 재연결, 앱 종료 후 엔진 유지,
  앱 재실행 이력 복원, 세션 전환, 이전 대화 로드, Settings.
- 로컬 실행 환경: macOS 27.0.1 / Xcode 27.0 / Swift 6.4 / Apple Silicon.
  deployment target 15.0 빌드 성공과 macOS 15 실기기 실행 검증은 구분한다. 후자는 아직 미검증이다.
- `.github/workflows/macos.yml`에 package tests·app build·process smoke·개발 artifact 업로드를 정의한다.
  원격 CI 통과는 GitHub 실행 결과를 확인한 경우에만 별도로 보고한다.

다음 구현 단위는 runner pipe/PTY·process group 취소·sandbox backend·LLDB-DAP spike다.
실제 provider/도구는 그 경계를 검증한 뒤 M1에서 연결한다.
