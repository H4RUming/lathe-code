# 도구·검색·MCP 설치와 설정

요구사항 수정: 2026-10-16. **아래 검색·MCP 기능은 구현 전 요구사항이다.**
[아키텍처](architecture.md)의 앱 내부 Swift runtime·ToolBroker·PolicyEngine과 [확장 계약](extensions.md)의 E/N/U 등급을 따른다.
[기능 명세](features.md)의 LAT-MCP-001~008과 [확장 계약](extensions.md)의 X9를 구체화한다.
사용자가 GitHub 저장소, Markdown 파일, 설치 문서 링크를 주면 agent가 내용을 읽고 적합성을 판단하여
**이미 존재하는 MCP 서버 또는 관련 설정을 설치·구성·검증·적용**하는 흐름이 목표다.
필요한 dependency 설치와 기존 서버의 소스 build는 포함한다. 앱이나 API를 분석해 새로운 MCP 서버,
adapter, tool 구현이나 scaffold를 제작하는 기능은 이 범위에 포함하지 않는다.
링크 문서와 저장소의 지시문은 참고 자료이며 사용자 요청이나 권한을 대신하지 않는다.

## 1. 하나의 도구 카탈로그와 실행 계약

Tools 모듈의 `ToolRegistry`는 built-in, MCP, integration 도구를 동일한 descriptor로 관리한다.
앱 GUI·선택적인 개발 CLI·main agent·subagent는 앱 내부의 같은 registry snapshot을 사용하고, 실행은 모두 `ToolBroker`를 통과한다. 일반 배포는 앱 하나이며 개발 CLI를 별도로 설치하지 않는다.

| 필드 | 계약 |
| --- | --- |
| `toolID`, `revision`, `namespace` | 안정적인 내부 식별자, 스키마/구현 revision, built-in 또는 server origin |
| `name`, `description`, `aliases` | 모델에 공개할 이름·설명과 검증된 호환 별칭; 설명은 권한의 근거가 아님 |
| `inputSchema`, `outputSchema` | 지원 JSON Schema profile과 검증기; 변환으로 의미를 보존할 수 없는 schema는 U |
| `effects`, `scopeResolver` | 파일·프로세스·네트워크·외부 변경 효과, 인자로부터 실제 경로/host/계정 범위 계산 |
| `timeout`, `outputBudget`, `cancellation` | 최대 시간·출력량·취소 방식, 외부 부수효과 취소 가능 여부 |
| `origin`, `capabilities`, `availability` | 서버/패키지 출처, 요구 capability, ready/deferred/connecting/failed/disabled |

provider의 이름 길이·문자 제한에는 가역적인 name map을 사용하고 충돌을 검출한다.
내부 ID, 모델 노출 이름, Claude 호환 이름, MCP 원래 이름은 실행 기록에 함께 남긴다.
Claude Code의 도구 이름은 권한 규칙·subagent 목록·hook matcher에서도 쓰이므로 이름만 비슷하게 바꾸어 E로 표시하지 않는다.
[Claude Code 도구 참조](https://code.claude.com/docs/en/tools-reference)

| 도구 계열 | Lathe 기본 계약 | 권한 평가 대상 |
| --- | --- | --- |
| `ListFiles`, `Glob`, `Grep`, `Read`, `LSP` | 로컬 파일·코드 탐색, 경로/행/결과 한도 | canonical path, symlink, workspace scope |
| `Write`, `Edit`, `NotebookEdit`, `Bash` | 파일 변경·프로세스 실행 | 실제 변경 경로, 실행 환경, network, 부수효과 |
| `WebSearch`, `WebFetch` | 웹 발견과 원문 조회를 분리 | backend, query, URL, credential scope |
| `ToolSearch` | 연결된 registry에서 관련 도구 발견·schema 로드 | 사용 가능한 서버·도구 목록; 실행 권한은 별도 |
| MCP tool/resource/prompt | 원래 계약을 보존한 호출·읽기·prompt 선택 | server revision, 계정, URI, 인자별 효과 |
| `MCPManage`, `MCPSetup` | 기존 서버 조사·설치·연결 설정의 typed operation | 현재 ExtensionChangeAuthorization과 결과의 실제 권한 |

호출 순서: `JSON decode → schema 검증 → scope/effect 계산 → hard deny → pre-hook → 변경 인자 재검증 → policy → journal → 실행 → 결과 검증`.
write lease·post-hook·실행 receipt의 정확한 순서는 아키텍처의 공통 ToolBroker 계약을 따른다.
실패 결과는 `invalid_arguments`, `permission_required`, `configuration_required`, `unavailable`, `timeout`, `cancelled`, `execution_failed`로 구분한다.
`ToolResult`는 text/structured/image/audio/resource link/embedded resource, artifact·citation 참조,
truncation, 실행 receipt, 재시도 안전성을 typed content로 보존한다.
원격 오류·인증 실패·tool의 `isError`를 성공적인 검색 내용이나 빈 결과로 바꾸지 않는다.

이미지 결과는 MIME/크기/유효성 검사를 거쳐 blob으로 보존하고 provider별 tool-result/attachment 경로에 매핑한다.
UI 미리보기와 모델이 실제 받은 이미지·크기 변환을 구분하며 call ID·source·원본 digest를 유지한다.
vision 미지원 모델은 이미지 내용을 읽었다고 보고하지 않는다. audio 등 미지원 유형도 삭제하지 않고 artifact와 이유를 남긴다.
resource link의 목록 발견과 원문 읽기는 별개며 follow-up fetch/read도 기존 scope·credential·budget을 통과한다.
`LAT-MCP-009`는 screenshot 결과의 실제 vision 왕복과 후속 재사용으로 검증한다.
[공식 MCP 결과 형식](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#tool-result),
[Claude Code 이미지 도구 결과](https://code.claude.com/docs/en/mcp#images-in-tool-results)

## 2. 검색은 모델과 독립적인 기능

로컬 코드 검색, 웹 검색, MCP 도구 검색은 서로 다른 작업이다.

| 기능 | 입력 → 결과 | 구현 경계 |
| --- | --- | --- |
| 코드 검색 | pattern/path/symbol → 파일·행·match·definition/reference | rg/glob/LSP adapter, ignore·encoding·symlink 정책 |
| 웹 검색 | query/filter → title/URL/snippet/source ID | 독립 `SearchConnection`의 SearchBackend |
| 웹 조회 | URL/extraction request → 원문 artifact·추출 결과 | FetchBackend, redirect·content type·크기 검증 |
| MCP ToolSearch | 작업 설명/server/name → descriptor와 사용 가능 schema | 로컬 registry index; 웹이나 패키지 registry 검색과 구별 |

코드 검색 자체는 로컬에서 수행한다. 결과가 선택한 외부 모델의 context로 전달되는지는 ModelConnection의 데이터 경계를 따른다.
`SearchConnection`은 `ModelConnection` 및 `ExecutionEnvironment`와 별도이며 credential·endpoint·quota·필터 capability를 가진다.
OpenAI, Claude, Gemini, vLLM, Ollama 어느 모델에서도 같은 `WebSearch` 계약을 호출할 수 있어야 한다.
backend는 검색 API, 명시적으로 설정한 MCP 검색 도구, self-hosted SearXNG adapter를 지원한다.
provider 자체 검색은 capability가 있을 때 선택 가능한 adapter이며, 다른 모델에서 검색을 못 하게 만드는 필수 경로가 아니다.

Claude Code의 WebSearch는 Anthropic backend를 사용하며 결과 URL의 페이지 본문을 가져오지는 않는다.
Lathe는 같은 사용자 기능을 N으로 제공하며 같은 비공개 검색 결과·랭킹·과금·쿼터를 재현한다고 주장하지 않는다.
[WebSearch/WebFetch 동작](https://code.claude.com/docs/en/tools-reference#websearch-tool-behavior)

SearXNG의 `/search?format=json`은 서버에서 JSON 출력이 허용되어야 하며 비활성화 시 403을 반환할 수 있다.
설정 화면에서 이 capability를 검사한다. self-hosted여도 query가 upstream 검색 엔진에 전송될 수 있음을 연결 정보에 표시한다.
[SearXNG Search API](https://docs.searxng.org/dev/search_api.html)

검색 결과에는 `queryID`, 실제 query, backend, title, canonical URL, snippet, retrievedAt, 선택적 publishedAt을 저장한다.
snippet과 fetched body를 구분하며, 본문을 읽지 않은 인용에는 원문 확인 완료 표시를 붙이지 않는다.
`WebFetch`는 최종 URL·redirect chain·HTTP status·content hash·원문 artifact를 보존하고 HTML 정규화와 모델 추출을 별도 단계로 기록한다.
추출 모델을 사용했다면 해당 ModelConnection과 요약 결과를 표시하고, 추출문을 원문으로 저장하지 않는다.
인용 링크는 실제 검색/조회 receipt에 연결하며 모델이 지어낸 URL이나 출처 ID를 유효한 검색 증거로 승격하지 않는다.

초기 기본 한도는 검색 호출당 query 4개·결과 10개, 세션 전체 query 100개, URL당 body 5 MiB·30초로 둔다.
값은 사용자 설정과 backend 제한으로 조정하되 child agent도 부모의 공통 세션 예산을 소비한다.
날짜·도메인·언어 filter는 backend capability를 확인한다. 지원하지 않는 filter를 적용했다고 표시하지 않는다.
429·결과 truncation·부분 실패·quota 소진을 구조화하고, 정책이 허용한 retry만 남은 예산 안에서 수행한다.
backend 미설정은 `configuration_required`다. 추측 답변을 검색 결과로 만들거나 다른 backend로 몰래 query·secret을 보내지 않는다.
fetch는 redirect마다 host·credential scope를 재검사하고 loopback/private network 접근도 기존 정책을 따른다.
취소하면 진행 중 HTTP 요청·추출 모델 호출·후속 page fetch를 중단하며 이미 받은 자료와 부분 결과 표시는 보존한다.

## 3. MCP client와 자연어 구성 흐름

MCP는 별도 provider가 아니라 IntegrationService다. 앱 내부 Swift runtime의 Extensions 모듈이 연결·registry 수명을 소유한다.
stdio, Streamable HTTP, 호환용 legacy SSE를 지원하고 transport·protocol revision을 명시적으로 협상한다.
tools/list·call뿐 아니라 pagination, prompts, resources/templates, subscriptions, listChanged, progress, cancellation,
roots, logging, OAuth, elicitation, sampling의 지원 여부를 negotiated capability별로 관리한다.
sampling 요청은 지정 ModelConnection·예산·ToolBroker를 통하며 MCP 서버가 새로운 모델 계정 권한을 얻지 않는다.
roots는 서버에 전달하는 작업 범위 정보이며 OS sandbox를 대신하지 않는다.
이 client 흐름과 provider adapter의 tool 변환은 분리한다. [공식 client 가이드](https://modelcontextprotocol.io/docs/develop/build-client)

`ToolSearch`는 연결된 도구의 name·description·namespace를 검색해 필요한 JSON schema만 다음 모델 요청에 주입한다.
provider 전용 deferred tool reference는 선택적 최적화이고, 이를 지원하지 않는 로컬 모델도 같은 기능을 사용한다.
서버가 connecting이면 한도 내에서 기다리고, failed이면 연결 오류를 반환한다. 둘 다 “해당 도구 없음”으로 숨기지 않는다.
listChanged 후 새 snapshot을 검증해 원자적으로 교체하며 갱신 실패 시 이전 목록은 stale로 표시한다.
잘못된 schema의 개별 도구는 이유와 함께 제외한다. MCP annotations는 권한 부여의 근거로 신뢰하지 않는다.
[MCP tools 계약](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)

사용자의 “이 GitHub/Markdown/설치 문서를 읽고 MCP를 설치해서 연결해” 요청은 아래 상태 머신으로 처리한다.

1. `read`: 제공한 링크의 원문·필요한 참조 문서를 읽고 URL, repository/release revision, 읽은 내용의 digest를 기록한다. 읽지 못한 문서를 추측해 설치하지 않는다.
2. `assess`: 기존 서버의 목적·도구, transport, macOS/runtime 호환성, 설치 위치, 필요한 의존성과 계정·권한을 판단한다. 문서의 실행 예시를 사용자 지시로 승격하지 않는다.
3. `draft`: user/project/project-local scope, source/revision, endpoint 또는 command/args, 환경 변수 참조와 설정 diff를 만든다. 설치가 불필요한 원격 연결이나 설정 변경만으로 끝나는 경우도 구분한다.
4. `install`: 허용한 위치에 고정 revision의 기존 패키지를 설치하거나 기존 저장소를 checkout·build한다. dependency fetch·설치 script·build도 현재 권한 모드와 grant를 통과한다.
5. `credentials`: 기존 Keychain 참조를 범위 내에서 연결한다. 새 OAuth 로그인·없는 secret은 해당 입력만 요청한다.
6. `test`: staging 연결로 handshake·capability·목록·schema·허용된 health/read probe를 확인한다. 빌드 성공과 실제 MCP 연결 성공을 구분한다.
7. `register/activate`: 검증 receipt와 config revision, scope 충돌을 확인한 뒤 원자적으로 등록·reload하고 요청한 실제 작업을 수행한다.
8. `diagnose`: 실패 단계·로그·권한·버전 차이를 보여 주고 범위 내 설정 수정·재검증 또는 이전 revision 복구를 수행한다.

`test`는 기존 ExtensionChangeAuthorization을 재검사해 시험 run에 한정된 staging 실행 허가를 받는다.
프로세스 시작/health probe/시험 agent 왕복만 제한적으로 허용하며 일반 세션 registry에는 노출하지 않는다.
이는 사용자 재승인이나 영속 활성화가 아니다. 시험 완료·실패·취소 시 임시 process/연결/registry를 회수하고,
검증된 revision만 `register/activate`에서 영속 사용 대상으로 승격한다.

`MCPManage`의 operation은 inspect/status/reload/diagnose/disable/rollback이고, `MCPSetup`은 read/assess/draft/install/build/validate/test/register/activate를 묶는다.
각 operation은 typed input과 receipt를 가지며 관리 도구라는 이유로 임의 shell 실행 권한을 얻지 않는다.
복합 operation은 전체 workspace write lease를 점유하지 않는 orchestration 호출이다. parent intent/grant를
기록한 뒤 실제 문서 읽기·설정 변경·dependency 설치·기존 서버 build·등록 leaf를 같은 broker로 보내고 leaf별 필요한 lease를 얻는다.
parent가 lease를 잡고 child 완료를 기다리는 재진입 교착을 금지한다. child에서도 현재 policy/grant를 재검사한다.
프로젝트 파일은 `.lathe/mcp.json`, 개인 override는 `.lathe/settings.local.json`, secret은 Keychain에 둔다.
`.mcp.json` 읽기와 scope 우선순위는 [확장 계약](extensions.md)을 재사용하며, imported 원본을 자동 덮어쓰지 않는다.
실행 경로에는 절대 경로와 고정된 패키지 revision을 기록한다. 검증된 서버를 다음 실행에서 `latest`로 바꾸지 않는다.

## 4. 설치 위임과 권한

사용자가 지정한 링크와 설치 요청에서 목적·대상 서버·설정 scope를 정하고 선택한 권한 모드를 적용한다.
`fullAccess`는 그 범위 안의 도구를 추가 승인 없이 실행하고, `autoApprove`는 낮은 위험으로 분류된
도구만 자동 실행하며 나머지는 승인한다. `acceptEdits`는 읽기·파일 편집을 자동 실행하되 설치·build·서버
시작 같은 실행은 승인한다. `requestApproval`은 읽기·쓰기·실행 모두 실행 전에 승인한다.
승인되어 있는 정확한 호출이나 유효한 위임을 같은 경계에서 중복 확인하지 않되, “설치해”라는 요청을
선택한 권한 모드의 승인 절차를 무시하는 근거로 사용하지 않는다. 상세 모드는 [권한 계약](features.md)을 따른다.

PolicyEngine은 사용자 출처 요청과 실제 승인 기록에서 `ApprovalGrant`의 scoped subtype인
`ExtensionChangeAuthorization`을 만들고 모델에는 불투명한 참조만 준다.
grant에는 목적, workspace, 허용 operation, 서버 source/revision·dependency 범위,
파일·네트워크·계정 효과, credential 참조, 예산·만료를 묶는다. 설치 artifact digest와 설정 revision을
해당 위임에 연결한다. 같은 서버의 허용된 build 산출물이 달라졌다는 이유만으로 위임을 새로 발급하지 않는다.
다른 서버·출처·범위 밖 경로·새 외부 쓰기·권한 확대는 기존 위임 안의 변경으로 가장할 수 없다.

문서의 `curl`, package manager, env 설정이나 MCP의 readOnly annotation은 실행 권한의 증거가 아니다.
프로젝트 파일·검색 결과·설치 문서·hook·MCP 출력은 grant나 현재 모드, deny/trust를 발급·수정하지 못한다.
낯선 repository에서 설정을 발견하는 것과 사용자가 그 서버를 설치하라고 요청하는 것은 구분한다.
인증이 없거나 새 계정·OAuth의 인간 동의가 필요하면 필요한 입력에서 기다리며 성공을 위조하지 않는다.
`fullAccess`도 OS 권한·자격 증명을 새로 만들거나 사용자가 지정한 목적 밖의 설치를 허용한다는 뜻은 아니다.

승인 근거·적용 scope·활성 revision을 앱과 개발 client에서 조회·철회한다. 만료·철회 뒤에는 새 호출을
막고 진행 중 설치·build·시험 process를 취소 정책에 따라 정리한다. 계획 작업은 권한 모드와 별개다.
사용자가 계획만 요청한 동안에는 실제 설치·설정 쓰기·활성화를 실행하지 않는다. 계획 검토를 마쳤어도
후속 구현에는 선택한 권한 모드와 현재 grant가 그대로 적용된다.

## 5. 기존 서버 설치·검증·적용 파이프라인

`MCPSetupService`는 사용자 링크에서 확인한 기존 배포물이나 저장소 revision을 도입한다.
공식 설치법이 package manager 설치, release 다운로드, 기존 source build, 원격 URL 등록 중 무엇을
요구하는지 판단한다. 설치 문서가 없거나 호환되지 않으면 근거와 미완료 상태를 남긴다.
부족한 기능을 채우기 위해 새 MCP 서버나 adapter를 생성하여 원래 서버 설치를 완료했다고 표시하지 않는다.

설치·검증 기록에는 다음을 남긴다.

- 읽은 GitHub/Markdown/설치 문서 URL과 revision/digest, 선택한 서버와 선택 이유.
- 기존 package/source revision, runtime 요구사항, dependency lock, 실제 설치·build 명령과 receipt.
- 설치 경로와 소유 범위, artifact digest, command/args 또는 endpoint, secret 없는 설정 diff.
- handshake·목록·호출 결과, 실패 진단, 활성화한 config revision과 이전 정상 revision.

runtime과 dependency는 기존 서버의 요구사항에 맞춰 선택한다. Swift 앱이 Node/Python 서버를
연결할 수 있다는 뜻이지 앱 코어를 그 런타임의 wrapper로 바꾸거나 새 서버 source를 만든다는 뜻은 아니다.
설치 script·dependency fetch·기존 build/test도 같은 ToolBroker와 현재 모드를 따른다.
OS 격리가 검증되지 않았으면 sandbox 완료라고 표시하지 않으며, 요구한 격리를 제공할 수 없으면
해당 설치 또는 활성화를 완료로 처리하지 않는다. 검증은 허용한 fixture·health/read 작업을 우선하며,
운영 시스템 쓰기·결제·메시지 전송은 설치 검증이라는 이유로 추가 실행하지 않는다.

| 검증 단계 | 통과 조건 |
| --- | --- |
| 설치·환경 | 고정 revision과 runtime/dependency 확인, 실행 파일 존재, 필요한 경우 기존 서버 build 성공 |
| 설정 | command/args/cwd 또는 URL, scope 우선순위, credential 참조, secret 노출 없음 |
| Protocol | initialize/version/capability, tools/resources/prompts 목록, schema, malformed frame·stdio 오염·종료 진단 |
| Client integration | 실제 transport 왕복, 허용한 tool 호출, auth·progress·timeout·cancel·연결 오류 |
| Agent roundtrip | 선택한 모델이 schema를 보고 기존 서버의 허용 도구를 호출하고 결과를 활용 |
| 수명·효과 | 정해진 scope 안의 검증, 취소 후 소유 process 정리, 외부 부수효과와 복구 한계 기록 |

실제 모델 연결이 없으면 Agent roundtrip은 미검증으로 남긴다. fixture 모델 검사를 실제 provider
검증으로 표시하지 않는다. MCP Inspector는 선택적 진단 도구이며 앱의 필수 런타임은 아니다.
[공식 Inspector 가이드](https://modelcontextprotocol.io/docs/tools/inspector)

검증된 artifact/config digest를 revision별로 등록한다. 새 revision 준비 중 기존 호출은 기존 revision에
고정하고, 신규 호출을 잠시 큐에 둔 뒤 기존 호출을 drain한다. 실패하면 전환을 보류하고 이전 정상
서버/설정을 유지한다. schema나 효과·범위가 바뀌면 현재 모드와 grant를 다시 평가한다.
rollback은 이전 설치·설정·schema를 복구하며 이미 발생한 원격 효과를 되돌렸다는 뜻은 아니다.
효과를 확인하지 못한 호출을 자동 재실행해 설치·업데이트를 완료하지 않는다.

## 6. Lathe 자체의 MCP server 모드

기존 서버를 연결하는 MCP client와 별도로 `lathe mcp serve` 상당의 stdio server를 제공한다(`LAT-MCP-010`).
외부 client가 선택된 파일·검색·편집·명령 도구를 사용할 때 같은 engine·ToolBroker·journal을 이용한다.
기본은 로컬 stdio이며 HTTP 공개 hosting은 별도 기능이다. 외부 client 요청은 인간 승인으로 취급하지 않는다.
launch profile에 workspace roots·tool subset·grant·budget·연결 수명을 고정하고 이 범위 안에서만 호출을 받는다.
engine은 승인된 launch profile을 검증해 ingress instance ID와 한 번만 결합할 수 있는 불투명한 bridge handle을
발급한다. handle은 로컬 IPC 연결에 묶으며 MCP payload/env나 모델 context로 내보내지 않는다.
MCP clientInfo·요청에 적힌 client 이름/grant ID는 표시용 외부 입력이며 인증 근거가 아니다.
재연결은 새 ingress를 발급하고 현재 launch profile/grant를 재검사한다. 다른 bridge의 grant를 가져올 수 없다.
호출 receipt는 ingress instance와 MCP request ID를 함께 기록한다. 동일 clientInfo를 보낸 두 client도 각자 범위만 사용한다.
GUI/승인 client가 없을 때 필요한 승인은 구조화된 tool error로 반환하고 무한 대기나 fullAccess로 바꾸지 않는다.
stdout은 MCP protocol 전용, 진단은 stderr다. 연결 종료 시 소유 작업의 취소/유지 정책을 명시하고 receipt를 조회할 수 있게 한다.
자기 server를 다시 client registry에 붙여 재귀 호출하는 경로는 instance identity·invocation stack·depth 제한으로 차단한다.
서버 수명은 앱 내부 runtime이 소유한다. 창을 닫을 때 사용자가 앱의 백그라운드 유지를 선택한 경우에만 계속되며, 앱 종료 뒤 독립 서버나 daemon을 남기지 않는다.
Claude Code도 MCP server 모드를 제공한다. Lathe가 공통 broker 권한을 유지하는 차이는 N으로 기록한다.
[공식 MCP server 모드](https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server)

## 7. 버전과 완료 게이트

확인 시점 공식 MCP 가이드는 2026-07-28 revision이고, Swift SDK README는 2025-11-25 구현을 명시한다.
따라서 SDK를 채택했다는 이유로 최신 protocol 전체 지원을 선언하지 않는다. 지원 revision·transport·capability matrix를 고정한다.
부족한 기능은 wrapper/구현을 추가해 fixture를 통과시키거나 U와 구체적 미지원 사유로 표시하며 완성 요구에서 삭제하지 않는다.
[MCP versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning), [공식 Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

| 작업 묶음 | 완료 증거 |
| --- | --- |
| T1 카탈로그·코드 검색 | 이름 충돌·schema 오류·hook 수정 후 재검증·외부 경로 차단 fixture |
| T2 모델 독립 웹 검색 | 외부 API와 self-hosted backend 각각 검색→조회→실제 출처 인용; 오류·한도·취소 |
| T3 MCP 사용·자동 구성 | LAT-MCP-001~004/007, E2E-20: stdio/HTTP 연결→scope/credential→목록→실제 호출→reload/diagnose/rollback |
| T4 문서 기반 설치·적용 | LAT-MCP-005~007, E2E-21: 사용자 링크 읽기→기존 package/revision·의존성 설치 또는 build→설정 diff→실제 MCP 검증→적용 |
| T5 모드·위임 회귀 | LAT-MCP-008, E2E-20/21: 네 모드의 승인 범위, 정확한 승인 재사용, grant 철회, 문서/config/설명으로 self-approve 불가 |
| T6 비텍스트 결과·server 모드 | LAT-MCP-009/010, E2E-27: screenshot→vision→재사용, 미지원 artifact 보존, 외부 client→공통 broker→무인 승인 오류·재귀 차단 |

T1과 T2의 독립 웹 검색·WebFetch 기본 기능은 M1 완료 게이트에 포함한다. T2의 시나리오는 E2E-19와 연결한다.
T3·T4·T5는 X9를 포함한 M4 확장 완료 게이트이며 E2E-20 자동 설정과 E2E-21 문서 기반 기존 서버 설치을 모두 통과해야 한다.
T6는 M3 provider content 계약 위에 M4에서 완성한다.
고급 browser 조작·UI와 원격 서비스는 M6/M7 범위로 유지하되 기본 검색·본문 조회의 선행 조건으로 만들지 않는다.
최종 시나리오는 로컬 모델이 사용자가 제공한 설치 문서를 읽고, 기존 fixture MCP 서버를 설치·설정·검증·적용해 도구를 호출한 뒤 출처와 결과를 보고하는 것이다.
build 실패·취소·재시작·schema 변경·없는 credential에서도 성공을 꾸미지 않고 다음 가능한 작업과 미완료 원인을 정확히 남겨야 한다.
