# 기능 동등성 구현·검증·커밋 계획

2026-10-15 설계 기준. 모든 단계는 아직 미구현이다.
[기능 요구사항](features.md)의 LAT-* ID와 [확장 계약](extensions.md)의 X1–X9를 구현·검증에 연결한다.
전체 구조는 [architecture.md](architecture.md), 모델 연결은 [providers.md](providers.md)를 따른다.
[추론·Ultra](reasoning-and-ultra.md)와 [도구·MCP 제작](tools-and-mcp-authoring.md)의 상세 검증도 포함한다.

## 1. 변경과 커밋 규칙

사용자 지시에 따라 **코드·설계·문서·설정의 의미 있는 변경 단위마다 검증 후 커밋하고 GitHub에 push한다.**
파일 저장 한 번마다 깨진 중간 상태를 남긴다는 의미가 아니라, 독립적으로 설명·검토할 수 있는 변경을 작은 커밋으로 기록한다.
설계 수정도 기능 구현 전까지 쌓아두지 않는다. 기존 이력을 임의 amend/squash하지 않는다.

작업 순서:

1. 관련 요구사항 ID, 현재 동작, 만들 동작, 완료 조건을 정한다.
2. 해당 범위만 변경한다. 사용자 변경과 무관한 파일을 섞지 않는다.
3. 변경에 필요한 build/contract/integration/manual 검증을 수행한다.
4. diff와 검증 결과를 확인하고 한 가지 목적의 commit을 만든다.
5. GitHub에 push하고 commit ID와 검증 결과를 남긴다. push 실패는 로컬 commit 성공과 구분한다.

커밋 예: `docs: define session recovery contracts`, `feat(runtime): persist tool execution receipts`,
`fix(providers): preserve tool calls across split stream frames`.
큰 단계는 여러 기능 커밋으로 나눈다. 필요할 때 `codex/<feature>` branch를 사용한다.
API key·access token·개인 프로젝트·실제 대화는 fixture/커밋에 넣지 않는다.

## 2. 전체 마일스톤

| 단계 | 목표 | 선행 | 대표 요구사항 | 완료 게이트 |
| --- | --- | --- | --- | --- |
| M0 | 실행 구조·contract·기술 검증 | 설계 | CORE/CLI/UI 기반 | GUI+CLI mock 동일 engine, IPC/DB/runner/sandbox 검증 결과 |
| M1 | 실제 단일 agent coding loop·검색 | M0 | CORE, TOOL-001~012, PERM, REASON 기반 | 코드/웹 탐색→수정→테스트→설명, 승인/취소/한도 |
| M2 | 장기 사용 가능한 세션·변경 관리 | M1 | SESSION, CTX, GIT-001~005 | resume/fork/rewind/compaction, crash 복구 |
| M3 | 요청한 모든 provider·추론 제어 | M1, M2 | PROVIDER, REASON-001/002/006/007 단일 agent, TOOL-013~014 | provider별 tool 왕복·native 옵션·Off/On·외부 endpoint |
| M4 | 설정·확장·MCP 제작 | M1~M3 | MEM, MCP, 확장 X1~X4/X6/X9 | 기존 MCP 사용과 새 서버 제작→검증→등록→실제 사용 |
| M5 | Ultra·병렬 agent·workflow | M2~M4 | TASK, REASON 전체, X5/X7 | 추론 활성 child/team, server queue/worktree/budget, resume/cancel |
| M6 | 네이티브 작업 환경·자동화 | M2~M5 | UI/CLI, TOOL-013~014, CORE-008, TASK-008~009, GIT-006 | PTY·preview·side chat·goal·schedule·연동 |
| M7 | 원격 실행·서비스/실험 기능 | 관련 기반 | INTEGRATION, X7/X8 | SSH/remote control/cloud·채널 등 각각 독립 검증 |

M1을 완성해도 전체 Claude Code 기능 동등성 달성이라고 부르지 않는다.
M0~M6는 로컬 코딩 에이전트와 네이티브 사용 흐름의 완성 범위다. M7도 요구사항 목록에 남아 있으며 실행 환경/서비스가 준비된 항목부터 닫는다.
실험 기능은 별도 상태를 표시하고 안정 기능과 같은 지원 등급으로 묶지 않는다.
단계 번호는 의존 순서다. 같은 기반을 쓰는 UI/adapter/fixture 작업은 병렬 수행 가능하다.

## 3. 커밋 가능한 작업 묶음

### M0 — 실행 기반

- Xcode 앱·로컬 Package·Swift 6 설정, 최소 UI/mock provider, macOS CI build.
- Domain IDs/events/tool schemas, versioned IPC command/event 계약.
- Swift engine startup/attach/detach, GUI/CLI 공통 client, event subscription/replay.
- SQLite writer·migration·blob store의 최소 구현. **side-effect tool보다 journal을 먼저** 만든다.
- runner process/pipe/PTY·child cancellation spike, sandbox filesystem/network probe.
- 결정 기록: SQLite wrapper, PTY renderer, sandbox backend, deployment target 실제 검증 범위.

게이트: GUI+CLI 동시 시작에도 engine이 하나이며 bootstrap/migration lock과 stale socket 복구가 동작한다.
GUI 창을 닫고 CLI로 다시 연결해 동일 mock 작업을 확인한다. 새 client가 중복 실행을 시작하지 않는다.
검증되지 않은 sandbox/PTY 조합은 분명하게 남기고 필요한 대안을 결정한다.

### M1 — 공통 coding loop

- 연결 설정·Keychain·환경 profile·URL prefix와 원격 인증.
- OpenAI Responses와 OpenAI-compatible Chat(vLLM)의 첫 adapter, stream/tool 결과 왕복.
- 선택 모델의 native 추론/Off·On capability와 요청 snapshot. Ultra UI는 M5 검증 전 미지원으로 표시.
- ModelStep/ToolInvocation 상태 머신, cancellation·budget·질문/steering mailbox.
- ToolBroker/PolicyEngine: 읽기·Manual/Accept edits/Plan/Don't ask, approval grant.
- list/search/read와 ignore/encoding/output 한도.
- URL fetch·독립 검색 backend 첫 구현, 출처/필터/한도/실패 계약. local LLM 검색 왕복을 함께 검증.
- create/edit/patch/move/delete, precondition·intent journal·기본 snapshot/diff.
- shell 실행·stdout/stderr·exit code·timeout·background task 기본 수명.
- 결과 보고에서 실행 증거와 파일 변경을 연결.

게이트: 같은 fixture 저장소의 실패 테스트를 OpenAI와 원격 vLLM에서 각각 조사→수정→검증한다.
취소·승인 거절·파일 충돌·잘못된 tool JSON에서도 사용자 변경을 보존한다.
검색 backend를 붙인 local 모델로 검색→본문 읽기→출처 있는 수정 근거를 확인한다(E2E-19 기본).

### M2 — 세션과 복구

- session list/search/name/archive/export, continue/resume, lease와 읽기 observer.
- fork/branch, provider/context revision, conversation-only/file-only/both rewind.
- 다중 파일 crash recovery, subagent를 위한 change ownership 기반, snapshot retention.
- context inspector, tool-output 축약, manual/auto compaction, 관련 provider signature 검증.
- Git status/diff/branch/worktree, 명시적 commit/push, GitHub PR 기본 연동.
- CLI text/JSON/stream JSON, exit state, 비대화형 입력/승인 실패 계약.

게이트: 편집 전·직후·중간에 프로세스를 종료해도 재시작 후 정확한 상태를 알 수 있다.
shell 부수효과를 자동 복원했다고 표시하지 않으며 불명확한 명령을 재실행하지 않는다.

### M3 — 모든 모델 경로

- Anthropic Messages와 thinking/tool-result 보존.
- Gemini GenerateContent와 AI Studio 인증·thought signature.
- Vertex project/location·gcloud ADC helper·토큰 재획득·quota 설정.
- Ollama NDJSON와 모델 옵션, local/LAN/external proxy.
- 기타 실제 호환 서버 프리셋과 API flavor 선택; 호환되지 않는 서버는 adapter 계획 표시.
- 모델 capability 진단·수동 override·사용량/비용 추정·turn 경계 모델 전환.
- native effort/level/budget/mode와 local Off/On. 모델/API/server별 미지원 옵션·sampling 충돌·무시 가능성 진단.
- typed 이미지/문서 attachment 전달. 미지원 vision/structured output의 명시적 처리.

게이트: OpenAI/AI Studio/Vertex/Claude/vLLM/Ollama 각각 stream→tool→result→답변을 실제로 검증한다.
키/서버가 없으면 fixture test만 통과한 상태와 live 검증 완료를 구분한다.
추가 API flavor(Google Interactions, Vertex Express, vLLM Responses)는 별도 커밋/검증으로 추가한다.
E2E-17과 추론 계약의 단일 agent 사례를 통과한다. 실제 Off를 지원하지 않는 모델은 명확히 비활성화한다.

### M4 — 설정과 확장

- X1: native/imported settings, nested instructions/rules, memory UI, trust/source diagnostics.
- X2: skills/legacy commands, 인자·reference·동적 전처리·수동/자동 호출.
- X3: hook lifecycle/command/HTTP, input mutation 재검증, 오류·취소·순환 방지.
- X4: MCP stdio/Streamable HTTP/legacy SSE, tools/resources/prompts, OAuth/elicitation/cancel.
- X4: ToolSearch/schema 지연 로드·revision 재검사, MCP 검색 backend와 builtin registry 연결.
- X9: 자연어 MCP 설정·server scaffold·build/test·등록/활성화·진단/rollback. 사용자 출처 scope grant와 실행 증거 보존.
- X6: plugin/marketplace manifest, source pin, 설치/비활성/업데이트/rollback.
- X6: LSP process/capability, 진단/정의/참조와 patch broker를 통한 workspace edit.
- M1의 승인 모드 확대: explicit bypass 및 별도 Auto reviewer. reviewer 검증 전 Auto 비활성.

게이트: 실제 프로젝트 설정과 fixture plugin으로 skill→MCP→편집→hook→LSP 흐름을 두 provider에서 실행한다.
unsupported 필드가 필요한 component는 실행하지 않고 명확히 표시한다.
E2E-20/21에서 기존 서버 연결과 새 서버 제작을 실제 호출까지 완료한다. 위임 범위 내 단계별 재승인은 없고
권한 확대·secret 부재·OAuth 상호작용을 필요한 경계에서만 기다린다. 실패한 업데이트는 정상 revision을 유지한다.

### M5 — 병렬 실행

- X5: named subagent, isolated/forked context, model map, tool scope, memory, partial/resume.
- worktree 생성/보존/정리, child task tree, 동시성·예산 예약·cancel propagation.
- team task board/claim/message/종료, agent 메시지와 사용자 권한 출처 구분.
- UltraCoordinator의 계획/조사/구현/독립 검토/검증 DAG, 역할별 reasoning/model snapshot.
- 동일 serving resource 큐·coordinator 포함 요청 상한·root 예산 예약, 동시성 1과 병렬 서버 각각 검증.
- Ultra UI/CLI의 역할·동시성·반복·시간/token/비용 조절, 단계 변경·partial 결과·실패/취소/복구.
- X7: 조건·반복·fan-out/fan-in workflow와 durable 중간 결과.
- X7: agent/prompt/mcp_tool hooks, 나머지 lifecycle와 task 이벤트 통합.

게이트: 세 작업을 다른 worktree에서 실행하고 일부 실패·취소 뒤 결과를 합친다.
부모보다 넓은 권한, 중복 claim, orphan process, dirty worktree 삭제가 없어야 한다.
E2E-18과 추론 계약 전체를 통과한다. 동일 local 모델 Ultra와 명시적 혼합 모델 구성을 각각 검증하며,
모델 요청 동시성 1에서도 교착 없이 역할 인계가 되어야 한다. 테스트 실행 증거와 agent 의견을 구분한다.

### M6 — 네이티브 생산성·자동화

- PTY 완성·resize/input/attach, native diff comments/editor, context/usage inspector.
- side chat, cross-session 메시지, 파일/이미지 mention, command palette·VoiceOver·IME.
- 검색 출처·도구 탐색·MCP 진단의 native 화면, PDF/notebook 입력과 관련 capability 완성.
- preview server 수명/포트 연결, PR/CI 상태 조회·watch, 사용자 알림.
- loop/goal/durable local schedule, timezone/DST·sleep·overlap·승인 대기·예산.
- X7: plugin monitors/styles/themes 및 지원 가능한 mods bridge.

게이트: GUI/CLI가 동일한 작업과 상태를 보고, 장기 서버·schedule·agent를 각각 중지할 수 있다.
로컬 스케줄은 machine-off 실행을 약속하지 않는다. preview 표시와 browser 자동화를 구분한다.

### M7 — 원격·서비스 영역

각 항목은 독립 integration 설계·구현·검증을 수행한다. 전용 backend 없이 placeholder UI만 만든 상태를 완료로 표시하지 않는다.

- SSH execution backend: 파일/PTY/worktree/checkpoint/port-forward/reconnect.
- remote control: 인증·연결/relay·동기화·모바일/웹 client·세션 권한.
- cloud execution/routines: runner provisioning, credential/secret 전달, job 상태·비용·회수.
- hosted PR review/security 및 artifact hosting: source 연결·변경/공유 정책·결과 증거.
- channels/Slack/mobile 입력: identity·메시지 출처·승인·재전송/dedup.
- browser/computer-use/simulator: 각 도구 프로토콜과 OS 권한, 모델별 지원 검증.
- X7/X8: 확장 host API의 남은 호환 항목과 전체 parity inventory 마감.

게이트: 기능별 실제 backend를 연결한 시나리오와 실패/취소/재연결을 검증한다.
Claude의 전용 계정 서비스에 임의 provider key로 접속할 수 있다고 가정하지 않는다.

## 4. 공통 품질 게이트

테스트는 구현을 그대로 따라 쓰기보다 외부에서 관찰 가능한 계약을 검증한다.

| 종류 | 핵심 경계 |
| --- | --- |
| Provider contract | byte 분할/UTF-8/JSON, 다중 tool, signature, incomplete/EOF/cancel |
| Reasoning/Ultra | 실제 control payload, unsupported/ignored 옵션, 역할 인계, root budget, 공유 서버 큐, writer/취소/복구 |
| Policy contract | deny/ask/allow, hook 인수 수정·재귀, 승인 hash, scope, child 권한, 잘못된 설정의 마지막 정상 revision, startup trust/Plan barrier |
| Workspace | 경로·symlink/hardlink·대소문자·revision conflict·부분 patch |
| Execution | pipe 폭주, PTY stdin/resize, child group timeout, detach/reconnect |
| Recovery | journal intent/result crash injection, unknown 외부 효과, migration |
| Extensions | import/profile/schema, hooks decision, MCP/LSP protocol, plugin lifecycle |
| MCP authoring | scoped 위임, build/schema/protocol/agent 왕복, digest/lock 고정, 자동 활성화, grant 철회, rollback |
| Search | code/web/tool 구분, 실제 근거·필터·quota·출력 제한·부분 실패, local 모델 backend 왕복 |
| Native UI | IME/VoiceOver/키보드, 긴 transcript, 승인/질문, 창·작업 수명 |
| Integration | HTTPS/auth/prefix, SSH disconnect, remote MCP, schedule overlap/misfire |

CI는 키 없는 deterministic fixture/모의 HTTP·MCP server로 package test와 macOS 앱 build를 수행한다.
실제 모델 평가는 별도 opt-in이며 provider/model/server version/parser/OS/설정·결과를 기록한다.
Claude와 Lathe 차등 검증은 사용자 동작·설정 계약을 비교하며 모델 출력의 문구 일치를 요구하지 않는다.
최소 OS에서 실행하지 못한 경우 최신 SDK 빌드만으로 해당 OS 검증 완료를 주장하지 않는다.
문서 변경은 link/ID/모순/diff 검사를 수행하며 앱 구현 테스트를 실행했다고 보고하지 않는다.

## 5. 다음 구현 단위

현재 요청은 기능·구조 설계다. 다음 실제 구현은 M0의 Swift 앱/engine/CLI skeleton과
mock provider를 통한 attach→stream→cancel→reconnect 수직 흐름을 권장한다.
이것을 먼저 검증하면 이후 기능이 UI 수명이나 특정 모델 API에 묶이는 문제를 피할 수 있다.
