# 확장 시스템과 Claude Code 호환 계약

작성·공식 문서 확인: 2026-10-15. 구현 상태: **설계만 존재하며 아래 기능은 아직 구현되지 않았다.**
전체 실행 구조는 [아키텍처](architecture.md), 작업 기능과 화면은 [기능 명세](features.md), 구현 순서는 [로드맵](roadmap.md)과 연결한다.
이 문서의 `E`, `N`은 구현 목표이며 현재 지원 여부를 뜻하지 않는다.

## 1. 범위와 호환성 수준

Lathe의 완성 범위에는 프로젝트 지침·메모리, skills·사용자 명령, hooks, subagents,
MCP, plugins·marketplaces, LSP가 모두 포함된다. 채팅과 파일 수정만 구현한 상태를
Claude Code와 동등한 제품으로 부르지 않는다. 다만 모델 응답의 품질, 비공개 서비스,
특정 Claude Code 빌드의 모든 내부 동작까지 같다고 주장하지 않는다.

| 수준 | 의미 | 승격 조건 |
| --- | --- | --- |
| `E — exact contract` | 특정 버전의 공개 파일 형식·이벤트·관찰 가능한 동작과 일치 | 해당 계약의 positive/negative fixture와 왕복 테스트 통과 |
| `N — native equivalent` | 같은 사용자 작업을 수행하되 저장 위치·권한·UI·모델 선택 방식이 다름 | 차이 명시, 같은 작업 시나리오의 완료 기준 통과 |
| `U — unsupported/pending` | 아직 실행하지 못하거나 의미를 보존할 수 없음 | 실행 차단 또는 해당 구성 비활성화, 이유와 필요한 마일스톤 표시 |

호환성은 플러그인 이름 하나에 붙는 불리언이 아니다. `입력 문법`, `필드`, `이벤트`,
`실행 효과`, `사용 중인 모델 capability`별 판정이다. 예를 들어 SKILL.md 파서는 E여도
`model: sonnet`의 다른 제공자 매핑은 N이다. 형식을 읽었다는 이유로 실행 호환을 선언하지 않는다.

기준은 `claude-code-docs-2026-10-15`라는 문서 스냅샷이다. 아직 실제 Claude Code 바이너리와
대조하지 않았으므로 특정 CLI 버전에 대한 E 인증은 없다. 구현 시 테스트한 CLI 버전과
스키마 revision을 고정하고, 그 밖의 신규 필드는 U로 표시한다.

확장 로딩과 실행은 **별도 Swift engine 프로세스의 Extensions 모듈**이 소유한다. macOS GUI와
CLI는 local IPC로 같은 registry·진단·승인·실행 상태를 사용한다. Extensions는 Runtime,
Policy, Context, Tools, Providers, Persistence의 계약을 이용하고 독자적인 실행 우회 경로를 만들지 않는다.
hook·skill 전처리·MCP·subagent·workflow가 요청한 도구도 동일한 `ToolBroker`로 들어가며,
실제 shell/PTY는 helper runner가 담당한다. Claude SDK나 TypeScript wrapper를 핵심 엔진으로 요구하지 않는다.

workspace 시작은 `discovery → passive parse/검증 → trust/activation → executable startup` 순서다.
SessionStart/Setup hook, 프로젝트 인증 helper, 동적 skill 전처리, stdio MCP는 검증된 실행 허가 전 시작하지 않는다.
기존 ExtensionChangeAuthorization 안의 MCP 시험은 policy 재검사 후 staging 실행을 임시 허가할 수 있다.
임시 허가는 시험 run·도구·효과·수명에 한정하며 영속 registry 활성화와 별개다. 일반 세션에는 아직 공개하지 않는다.
agent/hook/shell이 변경한 실행 설정은 pending revision으로 검사한다. 사용자 출처의 유효한
`ExtensionChangeAuthorization`에 포함된 변경은 시험·정책 재검사 후 정확한 revision을 자동 활성화한다.
이 위임은 사용자가 맡긴 MCP 설정/제작의 대상·runtime/dependency·접속·효과·예산 범위를 고정한다.
grant 밖의 실행/권한 확대는 사용자 결정이 필요하다. agent가 grant를 발급하거나 자신의 deny/trust를 바꾸지 못한다.
승인 DB·engine 설정/IPC 경로는 file tool과 검증된 sandbox의 직접 쓰기 대상에서 제외한다.
비격리 same-user process까지 이 규칙만으로 OS 수준에서 막는다고 주장하지 않는다.

## 2. 파일 소유권과 가져오기

Lathe가 쓰는 설정과 Claude Code가 관리하는 설정을 분리한다. `.claude` 파일은 기본적으로
읽기 호환 입력이다. UI에서 수정하면 `.lathe` override를 만들며, 원본 변경은 사용자가
해당 파일 편집을 선택한 경우에만 수행한다.

| 입력/저장 위치 | Lathe 처리 | 목표 |
| --- | --- | --- |
| `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/**` | 프로젝트 지침으로 읽기; 출처·범위·import 기록 | E 문법 / N 신뢰 경계 |
| `AGENTS.md` | Lathe 기본 프로젝트 지침; CLAUDE 계열과 중복되는 파일은 canonical path/hash로 식별 | N |
| `.claude/settings.json`, `.claude/settings.local.json` | 지원 필드를 변환한 읽기 전용 layer | E 필드별 / N 전체 설정 |
| `.claude/skills/**/SKILL.md`, `.claude/commands/**/*.md` | skill·명령 레지스트리로 읽기 | E 문법 / N 실행 정책 |
| `.claude/agents/**/*.md` | subagent 정의로 읽기 | E 문법 / N 모델·권한 |
| `.mcp.json` | 프로젝트 MCP 서버 정의로 읽기 | E 형식 / N 활성화 |
| `~/.claude`의 지침·skills·agents·settings | 사용자가 전역 호환 입력을 켠 뒤 지정된 범위만 읽기 | N |
| `~/.claude.json` | 사용자가 가져오기를 선택하면 MCP 정의만 선별; 계정·토큰·내부 상태는 가져오지 않음 | N |
| Claude Code의 auto memory | 선택한 memory 파일을 미리 보고 Lathe 메모리로 복사하는 일회성 import | N |
| `.claude-plugin/plugin.json`, 플러그인 구성 파일 | 설치 전 파싱·구성 목록·호환성 검사 | E 필드별 |
| `.claude-plugin/marketplace.json` | catalog 읽기; 게시자·source·revision별로 식별 | E 필드별 |

Lathe 소유 파일:

- 전역 `~/.lathe/settings.json`, `~/.lathe/rules/`, `~/.lathe/skills/`, `~/.lathe/agents/`.
- 공유 프로젝트 `.lathe/settings.json`, `.lathe/rules/`, `.lathe/skills/`, `.lathe/agents/`, `.lathe/mcp.json`.
- 개인 프로젝트 `.lathe/settings.local.json`; 프로젝트별 MCP override도 이 파일에 둔다.
- 공유 의존성 고정 `.lathe/plugins.lock.json`: source URL, commit/digest, package version, schema profile. 비밀·승인 토큰은 넣지 않는다.
- 실행 기록·auto memory·캐시·설치 승인·자격 증명 참조는 Application Support의 Lathe 전용 저장소.
  저장소 메모리는 repository ID, agent 메모리는 repository ID + agent ID로 분리한다.
- API key·OAuth token·민감한 plugin user config는 Keychain. plain JSON에는 참조만 기록한다.

`.lathe/settings.local.json`, 세션 출력, 임시 호환 transcript는 Git에 들어가지 않도록 한다.
공유 메모리가 필요하면 사용자가 검토한 내용을 `.lathe/rules/` 또는 `AGENTS.md`로 내보낸다.
다른 앱의 설치 registry, Claude 계정, 구독 상태, 조직 정책 디렉터리를 Lathe가 수정하지 않는다.

## 3. 설정 해석과 지침·메모리

### 설정 우선순위

Claude Code의 공개 우선순위는 managed → session settings → project local → project → user이며,
일부 배열과 환경변수는 별도 규칙을 갖는다. 단순 JSON 덮어쓰기로 동일성을 주장하지 않는다.
[공식 settings 설명](https://code.claude.com/docs/en/settings)

Lathe의 우선순위는 다음과 같이 **별도 명시한 N 계약**이다.

1. 세션에서 사용자가 선택한 override.
2. 프로젝트 local: `.lathe/settings.local.json`이 같은 scope의 `.claude/settings.local.json`보다 우선.
3. 공유 프로젝트: `.lathe/settings.json`이 같은 scope의 `.claude/settings.json`보다 우선.
4. 사용자 전역: `~/.lathe/settings.json`이 선택적으로 읽는 `~/.claude/settings.json`보다 우선.
5. 활성화한 plugin 기본값.
6. 앱 기본값.

권한 판정은 위의 scalar 우선순위와 분리한다. 등록된 deny는 allow로 덮어쓰지 못하며,
권한 rule 삭제는 그 rule의 소유 scope에서 명시적으로 수행한다. project가 `env`에 키를
썼다는 이유로 Keychain 값을 변경하거나 다른 provider로 전송하지 않는다.
Claude의 managed 설정은 개인용 Lathe가 조직 정책으로 자동 채택하지 않고 진단 목록에 표시한다.

`SettingsResolver`는 필드마다 `replace`, `mergeMap`, `orderedUnion`, `permissionRules`,
`hookRegistrations` 중 하나의 merge 전략을 선언한다. 알 수 없는 배열을 임의로 합치지 않는다.
각 resolved 값에는 source file, JSON pointer, scope, overridden source, schema revision을 남긴다.
UI의 설정 상세에서 최종값이 나온 경로와 무시되거나 미지원인 항목을 볼 수 있다.

레지스트리 충돌은 별도 규칙을 사용한다.

| 대상 | Lathe의 결정 규칙 |
| --- | --- |
| Claude 호환 skill 이름 | 사용자 > 프로젝트 순서를 보존; 동일 scope에서는 `.lathe` > `.claude`; plugin은 namespace 사용 |
| subagent 이름 | 세션 > 프로젝트 > 사용자 > plugin; 중첩 프로젝트에서는 작업 위치에 가까운 정의 우선 |
| MCP 서버 이름 | project local > project > user > plugin; server 객체 전체 교체, 필드 혼합 금지 |
| hook | 활성 scope의 등록을 합친 뒤 stable ID로 추적; 동일 파일의 재발견만 제거 |
| 동일 scope의 모호한 중복 | 파일 시스템 열거 순서에 맡기지 않고 충돌 진단·선택 필요 상태로 전환 |

Claude의 skill·subagent·MCP 우선순위는 서로 다르므로 하나의 공용 이름 resolver로 처리하지 않는다.
[Skills](https://code.claude.com/docs/en/skills), [Subagents](https://code.claude.com/docs/en/sub-agents), [MCP](https://code.claude.com/docs/en/mcp)

### 지침을 읽는 계약

지침은 모델 컨텍스트이며 실행 권한 설정이 아니다. `InstructionResolver`는 사용자 전역,
선택한 workspace의 상위 경로, workspace, 접근 파일의 하위 경로를 provenance와 함께 수집한다.
상위에서 하위로 배치하고 같은 경로의 local 지침을 뒤에 놓되, 문자열을 병합해 원문 출처를 잃지 않는다.
Lathe는 정책이 허용한 ancestor 범위까지만 읽으므로 파일 시스템 root까지 무조건 읽는 호환 모드와 구분한다.

`@path` import, 코드 블록 안의 literal, 상대경로 기준, 순환·깊이 제한,
rules의 `paths` glob은 compatibility fixture로 고정한다. workspace 밖으로 나가는 import와
symlink는 해석 결과를 먼저 보여 주고 해당 경로 접근이 허용된 경우에만 읽는다.
일치하지 않는 조건부 rule은 context에 넣지 않는다. 원문 전체 대신 경로·해시만 로그에 남긴다.
CLAUDE.md의 additive 로딩과 auto memory는 별개다.
[공식 memory 문서](https://code.claude.com/docs/en/memory)

Lathe auto memory는 사용자의 수정·선호·반복되는 프로젝트 사실을 후보로 만든 뒤 저장하고,
메모리 화면에서 출처와 수정·삭제·비활성화를 제공한다. 비밀, 일회성 테스트 결과, 완료된 작업 전체를
무차별적으로 장기 기억에 넣지 않는다. 모델이 만든 memory 항목은 도구 권한을 늘리지 않는다.
session snapshot은 적용한 지침·메모리 revision을 기록하므로 resume 후 변경 여부를 설명할 수 있다.

## 4. Skills와 사용자 명령

`SkillRegistry`는 발견 → 구문 검사 → capability 검사 → 활성화 → invocation의 단계를 분리한다.
목록을 읽는 것만으로 shell이나 네트워크 작업을 실행하지 않는다.

호환 파서 대상은 YAML frontmatter와 Markdown 본문, `name`, `description`, `when_to_use`,
`argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools`,
`disallowed-tools`, `model`, `context`, `agent`, `hooks`다. 나머지는 버전별 schema 목록에 따라
진단한다. legacy commands도 같은 내부 `SkillDefinition`으로 변환하되 경로 기반 이름 규칙을 따로 둔다.

invocation 계약:

1. 사용자 호출과 모델의 자동 선택을 구분한다. user-only skill은 모델 목록에 노출하지 않으며,
   model-only skill은 사용자 command palette에서 실행하지 않는다.
2. 인자 치환은 원본 문자열과 tokenized argument를 모두 보관한다. `$ARGUMENTS`, indexed/named
   인자, session/skill 경로 변수를 한 번만 확장하고 사용자 인자에 포함된 명령을 새 문법으로 재해석하지 않는다.
3. supporting file은 skill root에 상대적으로 해석한다. 외부 경로는 일반 파일 접근 정책을 적용한다.
4. 동적 shell 전처리는 `CommandExecutor` 작업으로 만들어 실행·출력·취소를 기록한다.
   description 수집이나 자동완성 중에는 실행하지 않는다.
5. `context: fork`는 격리된 subagent session으로 연결한다. 다른 경우 현재 turn의 context에 삽입한다.
6. tool grant는 invocation/turn 범위로 제한한다. 사용자·프로젝트의 deny와 workspace 경계를
   넘어서는 권한을 skill 파일 혼자 만들 수 없다. 이 부분은 N 계약이다.
7. `model` alias는 명시적 `ModelAliasMap`을 통해 ProviderConnection/ModelProfile로 연결한다.
   매핑이 없으면 설정 오류를 표시하며 다른 회사 모델이나 기본 모델로 조용히 대체하지 않는다.
8. 컴팩션 후에도 현재 작업에 필요한 invocation 출처와 인자를 보존한다. 정확한 재실행은 별도 명령이다.

형식과 원래 호출 의미의 기준은 [공식 skills 문서](https://code.claude.com/docs/en/skills)다.
잘못된 YAML의 자동 fallback, 권한 확대, 미지원 필드 무시는 Lathe가 그대로 재현하지 않는 N 차이다.

## 5. Hooks: 이벤트, 결정, 취소

`HookEngine`은 모델 loop의 바깥에서 명시적인 lifecycle 이벤트를 처리한다.
공개 참조에는 command/http/mcp_tool/prompt/agent handler, event별 입력·출력·exit code가 있다.
모든 이벤트가 같은 hook type이나 차단 결정을 허용하는 것은 아니다.
[공식 hooks reference](https://code.claude.com/docs/en/hooks)

### 지원 목표와 이벤트 등록

| 이벤트 묶음 | 필수 처리 지점 | 단계 |
| --- | --- | --- |
| `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `StopFailure` | 시작·resume·입력·정상/실패 종료 | X3 |
| `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure` | 검증된 호출, 승인, 도구 결과 | X3 |
| `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop` | 요약·자식 실행 경계 | X3/X5 |
| `Setup`, `InstructionsLoaded`, `Notification`, `ConfigChange` | 초기화·지침·알림·설정 변경 | X7 |
| `UserPromptExpansion`, `MessageDisplay`, `PostToolBatch`, `PermissionDenied` | 명령 확장·표시·배치·거부 | X7 |
| `TaskCreated`, `TaskCompleted`, `TeammateIdle` | 작업 목록과 팀 협업 이벤트 | X7 |
| `CwdChanged`, `DirectoryAdded`, `FileChanged`, `WorktreeCreate`, `WorktreeRemove` | workspace와 격리 작업 폴더 변경 | X7 |
| `PreModelSwitch`, `PostModelSwitch`, `Elicitation`, `ElicitationResult` | 모델 전환과 MCP 사용자 입력 | X7 |

이 표는 계약 inventory다. 아직 구현하지 않은 이벤트를 발견하면 U 진단을 내며 등록에 성공했다고
표시하지 않는다. 원래 이벤트에 없는 내부 동작을 가장 가까운 이름으로 흉내 내서 호출하지 않는다.
`MessageDisplay`의 표시 변경은 provider에 재전송할 원문 메시지를 변조하지 않는다.

내부 이벤트는 `schemaVersion`, `eventID`, `sequence`, `sessionID`, `turnID`, `agentID`,
`toolCallID`, `configRevision`, `timestamp`, `payload`를 가진다. CLI 호환 bridge가 이를
공개 snake_case payload로 변환하며 내부 필드를 외부 JSON에 임의로 섞지 않는다.

예를 들어 `PreToolUse` 호환 payload의 형태는 다음과 같다. UUID와 경로는 예시다.

```json
{
  "session_id": "session-example",
  "transcript_path": "/private/tmp/lathe-example/transcript.jsonl",
  "cwd": "/workspace/example",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "tool-example",
  "tool_input": { "command": "swift test" }
}
```

외부 tool 이름/입력 schema는 `ToolCompatibilityMap`으로 변환한다. `run_command`를 `Bash`로
이름만 바꾸고 `argv`를 그대로 넘기는 식의 불완전 호환은 금지한다. 필요한 필드를 손실 없이
표현할 수 없으면 그 hook은 N 또는 U로 판정한다. transcript를 읽는 hook에는 버전이 붙은
호환 projection 파일을 제공하며, Claude 내부 transcript 전체와의 일치를 보장하지 않는다.

결정 적용 계약:

- 도구 순서는 입력 schema 검사 → PreToolUse → 수정된 입력 재검증 → 권한 판단 → 필요한 승인 → 실행 → Post 이벤트다.
- allow/block/ask, updated input, context 추가 등은 event schema가 허용하는 경우에만 적용한다.
  JSON 결과를 받은 뒤에도 deny·scope·path 검사를 다시 수행한다.
- 여러 hook이 같은 입력을 수정하면 정해진 등록 순서로 적용하고 각 변경을 기록한다.
  거부 하나가 허용보다 우선한다. 병렬로 실행한 관찰 hook은 입력을 수정할 수 없다.
- exit status, timeout, parse failure, HTTP failure를 각각 기록한다. 이벤트별 차단 규칙을 schema
  데이터로 관리하며 `exit 2 == 모든 경우 취소` 같은 단일 분기로 구현하지 않는다.
- 정책용 hook은 실패 시 차단으로 설정할 수 있다. 관찰용 실패는 경고로 드러낸다.
  선택한 실패 정책과 Claude 호환 동작의 차이는 N 진단으로 표시한다.
- prompt/agent hook은 해당 session의 명시된 모델 연결을 사용한다. 독립 시간·호출 예산과
  tool 제한이 있으며 자기 자신을 재귀적으로 호출하지 않는다.
- command/http/mcp_tool을 포함한 모든 hook에 origin과 invocation stack을 붙인다.
  hook 내부 실행은 정책·journal·sandbox 검사를 유지하되 stack의 같은 hook/lifecycle을 다시 발행하지 않는다.
  다른 hook chain에도 깊이·횟수 제한을 둔다. 부모 도구의 결과를 저장하고 write lease를 해제한 뒤 post hook을 기다리며,
  hook 쓰기는 자신의 lease를 얻어 재진입 교착을 막는다.
- Plan에서는 mutation hook·동적 skill 전처리·MCP write/효과 미확인 호출을 비활성화한다.
  이미 실행 중인 세션 소유 writer/process는 중지·대기 barrier를 통과해야 한다. 필요한 확장 process는
  검증된 읽기 전용 환경에서만 유지한다. 다른 editor/세션까지 파일을 동결하는 보장은 아니다.

취소 계약:

- 취소는 대기 hook, HTTP 요청, prompt hook의 모델 요청, agent hook의 자식 작업까지 전달한다.
  command hook은 프로세스 그룹에 종료 요청 후 grace timeout으로 정리한다.
- 사용자가 중지한 작업을 Stop hook이 다시 시작할 수 없다. 정상 완료를 계속 작업으로 바꾸는
  Stop 결정에는 반복 한도와 `stop_hook_active` 대응 상태를 둔다.
- async 관찰 hook은 이미 완료한 도구를 소급 취소하지 못한다. turn 종료 뒤 결과는 통지 또는
  다음 입력 이벤트가 되며 이미 확정한 실행 결과를 덮어쓰지 않는다.
- 앱 종료·crash 후 실행 여부가 모호한 hook은 `interrupted`로 남기고 자동 재실행하지 않는다.
  HTTP 서버나 외부 프로세스가 이미 만든 효과는 취소했다고 되돌아간 것으로 표시하지 않는다.

## 6. Subagents와 agent teams 연결

subagent는 별도 context·모델·예산·tool scope·메모리를 가진 `AgentSession`이다.
부모는 요청과 결과 요약을 주고받으며 자식의 전체 transcript가 부모 context로 자동 복사되지 않는다.
정의 형식은 frontmatter + prompt이며 필요한 field는 compatibility schema에서 검증한다.
[공식 subagent 문서](https://code.claude.com/docs/en/sub-agents)

Lathe 구현 계약:

- `name`, `description`, `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`,
  `skills`, `mcpServers`, `hooks`, `memory`, `background`, `isolation`을 우선 구현한다.
  snapshot의 나머지 필드도 X7에서 지원 여부를 닫고 U 항목을 남기면 호환 완료가 아니다.
- permission은 부모가 실제로 허용한 범위와 자식 제한의 교집합이다. `bypassPermissions` 등
  위험도가 달라지는 값을 가져오면 변환 결과를 표시하고 사용자 설정 없이 자동 활성화하지 않는다.
- 재사용 가능한 모델 이름은 `ModelAliasMap`으로 해석한다. `inherit`는 시작 시 부모의 profile revision을 캡처한다.
- 지정한 skills를 preload하고 source revision을 기록한다. 실행 권한과 model-only/user-only 규칙을 생략하지 않는다.
- 상태는 queued/running/waiting/completed/partial/failed/cancelled/interrupted.
  최대 turn 도달은 성공으로 꾸미지 않고 partial 결과와 continuation handle을 반환한다.
- background 작업의 transcript·출력·실행 도구를 UI에서 열 수 있다. 부모 중지는 기본적으로
  자식 전체로 전파하며 사용자가 분리한 작업만 독립 session으로 남긴다.
- 같은 workspace에 쓰는 자식은 write lease로 조정한다. 격리가 필요하면 Git worktree를 만들고
  branch/base commit/미커밋 변경/정리 상태를 추적한다. 변경이 있으면 자동 삭제하지 않는다.
- team의 메시지·작업 할당·완료 이벤트는 공통 task store를 사용한다. depth, 동시 실행 수,
  총 예산을 명시하여 재귀 spawn과 무한 대기를 막는다. 팀 메시지 자체가 실행 권한을 늘리지는 않는다.

## 7. MCP 연결과 외부 도구

`MCPConnectionManager`는 provider와 독립적이다. 모델이 어느 회사 것이든 동일한 도구 registry를
사용하고, 각 model adapter가 도구 schema를 제공자 형식으로 옮긴다.
Swift SDK를 후보로 사용하되 SDK 채택만으로 모든 capability가 구현되었다고 보지 않는다.
[공식 Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

MCP 연결은 `IntegrationService`이며 모델을 호출하는 `ModelConnection`, 파일·shell을 실행하는
`ExecutionEnvironment`와 별개다. 원격 MCP endpoint를 등록해도 모델 provider나 workspace 실행
위치가 자동으로 바뀌지 않는다. stdio 서버는 해당 integration에 지정한 실행 환경에서 시작한다.

필수 범위는 stdio와 Streamable HTTP, legacy SSE 호환, tools/resources/prompts discovery,
pagination·list 변경, progress·cancel·연결 복구, 인증과 사용자 입력이다.
transport와 protocol version은 협상 결과를 저장한다.
[MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

Lathe 연결 계약:

1. discovery는 구성 검사와 실행을 구분한다. stdio command/args/env 또는 원격 URL/header의
   실제 해석 결과를 보여 준 후 활성화한다. `.mcp.json`을 발견했다고 프로세스를 시작하지 않는다.
2. `${VAR}`와 기본값 확장을 지원하되 비밀은 로그에 남기지 않는다. env 전체를 서버에 넘기지 않고
   명시적 env와 필요한 실행 환경을 조합한다. raw credential을 model schema에 포함하지 않는다.
3. 도구에는 server instance ID·source·schema revision을 붙인다. 연결이 바뀌거나 schema가
   교체되면 이전 승인과 pending call을 그대로 재사용하지 않는다.
4. MCP tool 결과의 오류와 transport 오류를 구분한다. read-only/destructive 같은 annotation은
   서버의 자기 선언이며 승인 면제의 증거가 아니다. 반환된 텍스트·resource는 외부 데이터다.
5. resources/prompts는 선택·미리보기·context budget을 거친다. server가 보낸 prompt가
   Lathe의 전역 지침이나 permission policy를 바꾸지는 않는다.
6. OAuth는 OS 브라우저를 사용하는 authorization flow와 PKCE·state 검증, Keychain 저장,
   만료·refresh·로그아웃을 지원한다. 서버 origin이 바뀌면 token을 전달하지 않는다.
   [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
7. elicitation은 native form/외부 인증 링크로 표시한다. 승인·거부·취소를 별도로 반환하며,
   서버 입력을 사용자가 아직 승인하지 않은 사실처럼 모델에 돌려주지 않는다.
   [MCP elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)
8. roots·sampling 등 client capability는 실제 지원할 때만 advertise한다. sampling은 선택된
   모델과 별도 예산·정책을 적용하며 무제한 모델 호출 통로로 만들지 않는다.

cancel은 request ID에 연결한 protocol cancellation을 보낸다. 뒤늦게 온 결과는 cancelled 작업의
성공으로 재분류하지 않는다. 연결 재시도는 가능하지만 부작용이 있을 수 있는 tool call을 자동
재전송하지 않는다. 서버가 취소를 무시할 수 있으므로 `cancel requested`와 실행 효과를 구분한다.
[MCP cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)

### 자연어 설정과 서버 제작

MCP 지원 범위에는 기존 서버 사용과 함께 자연어 연결 설정, 필요한 서버의 scaffold/구현/build/test,
등록·활성화·실제 호출·진단·업데이트가 포함된다. [도구·MCP 제작 계약](tools-and-mcp-authoring.md)이
stage·산출물·검증을 정의하며 `LAT-MCP-001~008`, `X9`, `E2E-20/21`로 추적한다.
사용자에게 이미 맡겨진 scope 안에서는 설정·제작·검증·활성화를 이어가고 매 단계 확인을 요구하지 않는다.
누락한 credential과 외부 OAuth 상호작용, 허용 범위 밖의 효과만 필요한 시점에 요청한다.

ToolSearch는 등록된 도구를 검색하고 선택 schema만 로드한다. 웹 검색과 프로젝트 코드 검색은 별도 도구다.
도구를 찾았다는 사실은 실행 권한이 아니며 연결·schema revision과 실제 인자를 ToolBroker에서 다시 확인한다.
서버가 만든 설정이나 자체 test 성공 주장으로 활성화하지 않는다. engine이 code/config digest와 검증 결과를 묶고
사용자 출처 grant 및 현재 policy와 대조한다. `.claude` 원본 대신 `.lathe` 설정으로 등록하는 기본 규칙도 유지한다.

위 링크의 2025-11-25 protocol은 baseline 참조다. 이후 protocol은 version 협상·capability·fixture를 추가해
지원 상태를 승격한다. 선택 SDK가 지원하는 version과 최신 specification을 같다고 가정하지 않는다.

## 8. Plugins·marketplaces·LSP

### 설치와 구성

plugin은 skills, commands, agents, hooks, MCP, LSP 등을 묶는 package다.
`.claude-plugin/plugin.json`과 default component 경로, manifest override 규칙을 따로 파싱한다.
marketplace는 package 자체가 아니라 source를 찾는 catalog다.
[Manifest reference](https://code.claude.com/docs/en/plugins/manifest-reference),
[Marketplace reference](https://code.claude.com/docs/en/plugins/marketplace-reference)

`PluginManager`는 다음 수명을 관리한다.

`discovered → downloaded → validated → awaitingActivation → enabled → disabled → removed`

- 로컬 directory, Git/GitHub source, 지원 archive source를 해석한다. source URL·ref·resolved commit·digest를 고정하고 설치 전 inventory를 만든다.
- marketplace 이름과 plugin 표시 이름만으로 신뢰를 판단하지 않는다. 같은 이름의 다른 source는 다른 package ID다.
- 파일을 cache에 받는 일과 실행 가능한 component를 활성화하는 일을 분리한다.
  archive path traversal, 외부 symlink, 구성 경로 escape를 검증한다.
- `plugins.lock.json`과 설치 registry를 일치시킨다. 업데이트는 staging에서 검사한 후 atomic하게
  교체하며 실패하면 이전 revision이 계속 실행된다. 실행 중 session은 자신이 시작한 revision을 유지한다.
- plugin namespace를 skills/agents/MCP 식별자에 보존한다. disabled plugin의 등록은 새 turn에
  적용하지 않고 진행 중 호출의 종료·취소를 명시적으로 처리한다.
- user config는 typed native form으로 제공한다. sensitive 필드는 Keychain으로 연결한다.
- `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}` 등의 호환 변수는 Lathe의 package/data
  경로를 가리킨다. 원래 Claude cache 경로인 것처럼 가장하지 않는다.
- 제거는 등록과 실행을 중지하고 cache/data 삭제를 구분한다. 사용자 작업 파일이나 worktree를
  plugin 소유 파일로 오인해 삭제하지 않는다.

기존 플러그인도 사용자 권한으로 코드를 실행할 수 있다. Lathe의 tool 승인 UI가 외부 hook,
MCP/LSP 프로세스의 모든 filesystem/network 동작을 격리하는 것은 아니다.
활성화 화면은 실행 command·접속 origin·설정 전달 범위를 보여 준다. 신뢰 기록은 실행 파일과
config revision에 연결하고, 새 실행 component가 추가되는 업데이트를 무음으로 활성화하지 않는다.
[공식 plugin security 설명](https://code.claude.com/docs/en/plugins/security)

Swift native sandbox 실험과 escape/deny 검증을 통과하기 전에는 OS 수준의 격리나 Claude Code와
동일한 sandbox를 제공한다고 표시하지 않는다. 실행 경로를 broker로 통일하는 것과 subprocess가
직접 수행하는 모든 시스템 호출을 격리하는 것은 별도 완료 기준이다.

### 최신 확장 항목의 처리

현재 공식 plugin surface에는 output styles, `bin/`, workflows, monitors, themes, mods도 있다.
기본 plugin bundle만 지원하면서 이들까지 지원한다고 표시하지 않는다.
[Plugin components](https://code.claude.com/docs/en/plugins/components),
[Mods overview](https://code.claude.com/docs/en/plugins/mods/overview)

| 항목 | 목표 계약 | 완료 전 동작 |
| --- | --- | --- |
| output style | prompt style과 native 표시 설정으로 N 매핑 | 미지원 필드 진단 |
| plugin `bin/` | 활성 session의 command 환경에만 경로 추가, 사용자/system PATH 뒤에 배치 | 실행 불가 표시 |
| monitors | 수명·출력·취소를 추적하는 background process로 N 구현 | 자동 시작 금지 |
| workflows | 버전이 있는 workflow 실행 계약과 native 진행 UI | 실행 중단·필요 runtime 표시 |
| themes | 지원하는 색상·서체·표시 토큰을 native theme으로 N 변환 | 변환하지 못한 토큰 표시 |
| JS/TS mods | native extension bridge로 가능한 이벤트·command·pane 동작을 N 제공 | 미구현 host API별 U; package 전체 exact 주장 금지 |

이 항목은 X7의 정식 작업 범위다. Claude의 in-process API나 terminal renderer에 의존한 코드를
SwiftUI에서 무조건 그대로 실행할 수 있다는 약속은 하지 않는다. 필요한 함수/렌더링 계약을
명시적으로 이식하거나 해당 plugin의 호환성 미완료 상태를 남긴다.
JS/TS 확장 import를 지원하더라도 extension host의 선택적 compatibility 기능이며 Swift engine을
Node 기반 엔진으로 교체하는 근거가 되지 않는다. host API를 구현하지 않은 package는 실행하지 않는다.

### LSP

`.lsp.json`과 manifest의 LSP 선언을 `LanguageServiceConfiguration`으로 변환한다.
`command`, `args`, `env`, 언어별 확장자 매핑, 초기화 옵션, timeout/restart 설정을 검증한다.
plugin 설치와 language-server executable 설치는 별개다.
[LSP 구성](https://code.claude.com/docs/en/plugins/components#lsp-servers),
[Code intelligence](https://code.claude.com/docs/en/plugins/code-intelligence)

`LanguageServiceManager`는 workspace·server별 프로세스를 소유한다. initialize와 capability 협상,
문서 버전·열기/변경/닫기 동기화, diagnostics, definition/references/hover/symbol 조회를 제공한다.
workspace edit·rename·code action처럼 쓰는 작업은 공통 patch/승인/복구 경로로 통과시킨다.
오래된 문서 버전의 진단은 현재 오류처럼 표시하지 않는다.

중복 언어 서버는 사용자가 고른 우선순위를 따르고 충돌을 보여 준다. crash는 제한된 횟수만
재시작하며 무응답·잘못된 protocol output·실행 파일 누락을 구분한다. Swift 프로젝트의
SourceKit-LSP와 다른 언어 서버 하나로 구현을 검증하고, 나머지는 서버 capability에 따라 동작한다.

## 9. 미지원 항목과 활성화 원칙

파서 결과는 `ResolvedComponent`와 `CompatibilityDiagnostic[]`를 함께 반환한다.
진단에는 source, line/JSON pointer, field/event, original value, selected profile,
E/N/U 판정, 적용 결과, 수정 방법, 구현 milestone을 기록한다.

- 알려진 표현/UI 차이는 warning + N 표시. 기능에 영향 없는 metadata만 선택적으로 보존한다.
- 미지원 permission·executable·transport·handler·model 필드는 관련 component 활성화를 막는다.
- parse 실패를 빈 권한/무조건 적용 rule로 바꾸지 않는다. permission/hook/trust 설정 실패는 마지막 정상 revision을
  유지하거나 관련 실행을 차단하며, 최초 로드라 정상 revision이 없으면 해당 workspace 실행을 보류한다.
  비보안 metadata만 분리해 제외할 수 있고, 필수 hook/deny가 사라진 상태로 나머지 설정을 활성화하지 않는다.
- 부분 설치는 사용자가 component 목록을 보고 선택했을 때만 허용한다. 핵심 hook이 빠진 plugin을
  전체 enabled로 표시하지 않고 `partially enabled`와 제외 항목을 유지한다.
- 신뢰할 수 없는 project 파일은 approval DB에 직접 쓰지 못한다. skill/agent/hook/shell이 만든
  실행 설정은 pending revision으로 검사하며 사용자 출처 위임 범위 안에서만 자동 활성화한다.
  실제 권한 확대는 새로운 사용자 결정이 필요하며 MCP 제작 요청을 무제한 권한 위임으로 해석하지 않는다.
- 이미 허용된 범위에 매번 재승인을 요구하지 않는다. 위임 안의 새 코드도 digest 고정·시험·정책 검사를 거친다.
  위임 밖의 실행 코드·접속 대상·권한 범위만 사용자 검토 대상으로 만든다. grant 철회/만료/Plan 전환은 진행 중 작업에도 적용한다.

## 10. 필수 마일스톤과 검증

아래 단계는 생략 가능한 아이디어 목록이 아니다. 전체 확장 지원 완료에 필요한 작업 순서다.
각 단계는 검증 가능한 기능 커밋으로 나누고 검증·diff 검토 후 GitHub에 반영한다.
`X`는 이 문서의 작업 ID다. 전체 로드맵에서는 X1–X4와 X6/X9의 기반이 M4,
X5와 X7의 병렬·workflow 기능이 M5, native UI 확장이 M6, 원격 실행·service 연동이 M7에 대응한다.
OAuth와 remote MCP는 M4의 integration 지원이며, remote workspace 실행은 M7의 별도 범위다.

| ID | 결과물 | 수용 기준 / 커밋 단위 예시 |
| --- | --- | --- |
| X1 | config·지침·memory resolver | scope 충돌·외부 import·잘못된 YAML·native override 검사; `feat(config): resolve instructions and imported settings` |
| X2 | skills·legacy commands | 자동/수동 호출, 인자·reference·동적 전처리, source 표시; `feat(skills): add invocation and command compatibility` |
| X3 | hook engine·기본 lifecycle | command/http, payload, 결정, 취소, timeout, recursion 검증; `feat(hooks): dispatch lifecycle events with decisions` |
| X4 | MCP 완성 경로 | stdio/HTTP/legacy SSE, discovery, auth, resource/prompt, 취소·복구; `feat(mcp): connect servers and expose tools` |
| X5 | subagents·team 연결 | isolated context, model map, skill preload, worktree, budget·resume·취소; `feat(agents): run scoped subagents` |
| X6 | plugins·marketplaces·LSP | 실제 bundle 설치·disable·update·rollback과 진단/탐색; `feat(plugins): manage versioned extension packages` |
| X7 | 확장 고급 호환성 | 나머지 lifecycle, prompt/agent/mcp_tool hooks, workflows·monitors·styles·mods bridge와 MCP client capability; 기능별 커밋 |
| X8 | 전체 호환성 gate | 아래 fixture·통합 시나리오와 미지원 inventory 검토, 사용자에게 정확한 지원표 제공 |
| X9 | MCP 자동 설정·제작 | 위임→scaffold/build→protocol/agent 왕복 시험→등록/활성화→진단/rollback; `feat(mcp): build and activate servers within delegated scope` |

X4는 X3, X5와 일부 병렬 개발할 수 있지만 활성화·권한·취소 primitive는 공유한다.
plugin runtime을 먼저 만들고 나중에 권한을 붙이지 않는다.

### 버전별 fixture

`Tests/Fixtures/Compatibility/<profile>/`에 최소 입력·기대 결과만 저장한다. fixture는
source URL, 확인일, 검증한 CLI 버전 또는 `docs-only`, Lathe schema version, expected level을 가진다.
공식 문서 전체·실제 사용자 메모리·토큰·프로젝트 transcript를 복사하지 않는다.

필수 fixture 묶음:

- 설정: 중첩 scope, 배열 merge, deny, env, duplicate name, 모르는 필드, malformed JSON/YAML.
- 지침: nested file, import cycle, escaped path, symlink, 조건부 rule, 범위 밖 파일.
- skill: manual/model-only, positional/named 인자, literal 치환, fork, dynamic command failure/cancel.
- hook: 각 event 입력·출력, 결정 불가 event, 충돌 수정, 모든 handler, timeout, nonzero exit,
  invalid output, late async result, Stop 재진입, 사용자 중지 우선.
- MCP: 모의 stdio/HTTP 서버, pagination·schema 변경, OAuth 만료, elicitation 거절,
  remote disconnect, late response, 재전송 금지, server restart.
- MCP 제작: 위임 범위 자동 활성화, source/config digest 교체, dependency 실패, schema/protocol 오류,
  실제 새 도구 왕복, grant 만료/철회·Plan 전환, last-good rollback, 자동 권한 확대 거절.
- subagent: 부모/자식 권한 교집합, 미지원 모델 alias, partial/resume, 취소 전파,
  write lease와 worktree의 사용자 변경 보존.
- plugin/LSP: source pin, archive escape, 변경된 manifest, rollback, 누락 executable,
  부정 protocol frame, stale diagnostic, namespace 충돌, 부분 설치 표시.

E 승격은 문법 parse 테스트만으로 하지 않는다. fake provider와 fake process를 사용한 결정적
contract test, 실제 MCP/LSP server를 사용한 통합 테스트, 선택한 Claude Code 버전과의
fixture 차등 검증을 구분한다. 실제 모델을 사용하는 평가는 별도 task 성공률로 기록하며
랜덤 응답 차이를 설정·protocol 호환성 실패와 혼동하지 않는다.

전체 수용 시나리오는 `프로젝트 지침 로드 → plugin skill 호출 → subagent 분리 → MCP 조회 →
코드 수정 → hook 검사 → LSP 진단 → 수정 완료 → 세션 resume`이다. 같은 흐름을 Claude 연결과
다른 도구 호출 지원 provider에서 수행한다. 모델 capability가 부족하면 시작 전에 구체적으로
표시하고 silent degradation 없이 해당 기능을 사용할 수 없는 상태로 유지한다.
