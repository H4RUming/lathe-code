# 도구·검색·MCP 자동 구성과 서버 제작

설계·공식 문서 확인: 2026-10-15. **아래 기능은 구현 전 요구사항이다.**
[아키텍처](architecture.md)의 Swift engine·ToolBroker·PolicyEngine과 [확장 계약](extensions.md)의 E/N/U 등급을 따른다.
[기능 명세](features.md)의 LAT-MCP-001~008과 [확장 계약](extensions.md)의 X9를 구체화한다.
목표는 사용자가 작업을 말하면 agent가 필요한 도구를 찾고, 연결하고, 부족한 MCP 서버를 만들어 실제 작업까지 완료하는 것이다.
MCP 사용뿐 아니라 자동 구성·제작·검증·활성화도 필수 범위이며, shell 명령 안내만 반환하는 것으로 완료하지 않는다.
Claude Code도 공식 MCP 문서에서 서버 제작 skill과 HTTP/stdio scaffold를 제공한다. [공식 MCP 가이드](https://code.claude.com/docs/en/mcp)

## 1. 하나의 도구 카탈로그와 실행 계약

Tools 모듈의 `ToolRegistry`는 built-in, MCP, integration 도구를 동일한 descriptor로 관리한다.
GUI·CLI·main agent·subagent는 같은 registry snapshot을 사용하고, 실행은 모두 `ToolBroker`를 통과한다.

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
| `MCPManage`, `MCPAuthor` | 연결 구성과 서버 제작의 typed operation | 현재 ExtensionChangeAuthorization과 결과의 실제 권한 |

호출 순서: `JSON decode → schema 검증 → scope/effect 계산 → hard deny → pre-hook → 변경 인자 재검증 → policy → journal → 실행 → 결과 검증`.
write lease·post-hook·실행 receipt의 정확한 순서는 아키텍처의 공통 ToolBroker 계약을 따른다.
실패 결과는 `invalid_arguments`, `permission_required`, `configuration_required`, `unavailable`, `timeout`, `cancelled`, `execution_failed`로 구분한다.
`ToolResult`는 text/structured content, artifact·citation 참조, truncation, 실행 receipt, 재시도 안전성을 보존한다.
원격 오류·인증 실패·tool의 `isError`를 성공적인 검색 내용이나 빈 결과로 바꾸지 않는다.

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

MCP는 별도 provider가 아니라 IntegrationService다. Swift engine의 Extensions 모듈이 연결·registry 수명을 소유한다.
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

사용자의 “이 서비스 MCP를 연결해서 사용해” 요청은 아래 상태 머신으로 처리한다.

1. `discover`: 공식 문서·registry·저장소에서 후보를 찾고 source·maintainer·license·revision을 기록한다.
2. `select`: 작업에 맞는 tool·transport·런타임·권한 범위를 비교하고 기존 정책 안에서 후보를 선택한다.
3. `draft`: user/project/project-local scope, endpoint 또는 command/args, 환경 변수 참조, 허용 도구를 만든다.
4. `credentials`: 기존 Keychain 참조를 범위 내에서 연결한다. 새 OAuth 로그인·없는 secret은 해당 입력만 요청한다.
5. `test`: 격리된 staging 연결로 handshake·capability·목록·schema·허용된 health/read probe를 확인한다.
6. `register`: 검증 receipt와 config revision을 저장하고 충돌·scope 우선순위를 검사한다.
7. `activate`: 연결을 reload하고 schema snapshot을 반영한 뒤 요청한 실제 작업을 수행한다.
8. `diagnose`: 실패 단계·로그·권한·버전 차이를 보여 주고 범위 내 수정·재검증 또는 이전 revision 복구를 수행한다.

`test`는 기존 ExtensionChangeAuthorization을 재검사해 시험 run에 한정된 staging 실행 허가를 받는다.
프로세스 시작/health probe/시험 agent 왕복만 제한적으로 허용하며 일반 세션 registry에는 노출하지 않는다.
이는 사용자 재승인이나 영속 활성화가 아니다. 시험 완료·실패·취소 시 임시 process/연결/registry를 회수하고,
검증된 revision만 `register/activate`에서 영속 사용 대상으로 승격한다.

`MCPManage`의 operation은 discover/inspect/draft/validate/test/register/reload/status/diagnose/disable/rollback이다.
각 operation은 typed input과 receipt를 가지며 관리 도구라는 이유로 임의 shell 실행 권한을 얻지 않는다.
복합 operation은 전체 workspace write lease를 점유하지 않는 orchestration 호출이다. parent intent/grant를
기록한 뒤 실제 source·build·설치·등록 leaf를 같은 broker로 보내고 leaf별 필요한 lease를 얻는다.
parent가 lease를 잡고 child 완료를 기다리는 재진입 교착을 금지한다. child에서도 현재 policy/grant를 재검사한다.
프로젝트 파일은 `.lathe/mcp.json`, 개인 override는 `.lathe/settings.local.json`, secret은 Keychain에 둔다.
`.mcp.json` 읽기와 scope 우선순위는 [확장 계약](extensions.md)을 재사용하며, imported 원본을 자동 덮어쓰지 않는다.
실행 경로에는 절대 경로와 고정된 패키지 revision을 기록한다. 검증된 서버를 다음 실행에서 `latest`로 바꾸지 않는다.

## 4. “스스로”의 권한 계약

사용자의 제작·연결 요청이나 기존 정책이 허용한 범위에서는 create → build → test → register → activate를 자동 진행한다.
파일 생성·각 테스트·각 reload마다 같은 승인을 반복하지 않는다. 준비만 끝내고 사용자가 명령을 복사하게 하는 것을 기본 흐름으로 삼지 않는다.
PolicyEngine은 사용자 출처의 요청과 기존 정책에서 `ApprovalGrant`의 scoped subtype인
`ExtensionChangeAuthorization`을 발급하고 모델에는 불투명한 참조만 준다.
grant에는 목적, workspace, 허용 operation, source/dependency 범위, 파일/네트워크/계정 효과, credential 참조, 예산·만료를 묶는다.
agent가 만든 source revision과 build artifact digest는 해당 grant의 허용된 제작 과정에 연결해 검증한다.
새 digest라는 이유만으로 매 build마다 다시 묻지 않으며, 허용 범위를 벗어난 효과나 출처 변경은 delta로 판정한다.

새 secret·추가 계정·작업 범위 밖 경로·새로운 외부 쓰기·설치/실행 권한 확대에만 필요한 입력 또는 범위 확대를 요청한다.
명시적 deny, provider 제한, sandbox 제한을 모델 판단으로 해제할 수 없다. grant는 모델·hook·MCP 출력이 발급하거나 수정할 수 없다.
서버가 요구하는 명시적 인간 동의 절차도 자동 성공으로 위조하지 않는다.
낯선 repository의 실행 설정을 발견했다는 사실은 제작·활성화 위임이 아니며, 기존 passive parse/trust 단계가 그대로 적용된다.
승인 근거·적용 scope·활성 revision을 GUI와 CLI에서 조회·철회할 수 있고 철회 후 새 호출은 차단한다.
grant 만료·철회는 진행 중 제작에도 적용한다. Plan 전환 시 설정 쓰기·build/설치·활성화와 mutation MCP를
중지·대기시키고 공통 실행 barrier가 완료된 뒤 읽기 전용 계획만 계속한다. 기존 grant가 Plan을 우회하지 않는다.

## 5. MCP 서버 제작 파이프라인

`MCPAuthor`는 spec/scaffold/build/test/package/register/repair operation을 제공한다.
사용자가 “이 API를 쓰는 MCP 서버를 만들어 붙여줘”라고 하면 입출력·인증·대상 데이터·읽기/쓰기 효과를 먼저 구체화한다.
기본 SDK는 Swift이며, 연동 대상 생태계와 설치된 런타임에 따라 Python/TypeScript 등 검증된 SDK template도 선택할 수 있다.
생성 서버의 언어는 Swift 앱·engine의 구현 언어와 독립적이고 Node/Python을 engine의 필수 wrapper로 만들지 않는다.
공식 서버 가이드의 tools/resources/prompts 구조를 사용하되 예제의 외부 서비스·secret을 그대로 실행 환경에 복사하지 않는다.
stdio 서버 stdout은 protocol 전용이며 로그는 stderr 또는 파일에 쓴다. [공식 서버 제작 가이드](https://modelcontextprotocol.io/docs/develop/build-server)

산출물은 지정한 프로젝트의 `integrations/mcp/<server>/` 아래에 생성한다.

- tool/resource/prompt 계약, 입력 검증, 실제 adapter와 mock adapter를 분리한 source.
- compiler/runtime 요구사항, 고정 SDK/dependency와 lockfile, build/test 명령, license/source 정보.
- unit/protocol/integration fixture, secret 없는 example config, 사용법·권한·한계 README.
- package manifest, artifact digest, config candidate, 테스트 receipt와 실패 시 진단 자료.

package install·dependency fetch·build script 실행도 ToolBroker와 grant의 source/network/process 범위에 포함한다.
생성 source를 임의로 신뢰하지 않으며 검증된 ExecutionEnvironment에서 build·test한다.
OS 격리가 검증되지 않은 환경은 “sandbox 완료”로 표시하지 않는다. 요구된 격리를 제공하지 못하면 활성화 게이트를 통과하지 못한다.
초기 테스트에는 mock API·임시 workspace·테스트 credential만 사용하며 운영 시스템 쓰기·결제·메시지 전송을 검증 수단으로 삼지 않는다.

| 검증 단계 | 통과 조건 |
| --- | --- |
| Unit | 입력/출력 schema, pagination, 오류 변환, 인증 누락, timeout, 민감 정보 redaction |
| Protocol | initialize/version/capability, tools/resources/prompts 목록·호출, malformed frame·stdio 오염·종료 |
| Client integration | Lathe client와 실제 transport 왕복, schema 갱신·scope·credential·progress·cancel |
| Agent roundtrip | 실제 선택 모델이 schema를 보고 호출 → 생성한 실제 서버가 mock downstream API를 호출 → 모델의 결과 활용까지 완료 |
| Effect isolation | mock 외 endpoint 차단, workspace 밖 쓰기 차단, 취소 후 child/process 정리 확인 |

실제 모델 연결이 없으면 Agent roundtrip은 미검증으로 남긴다. fake model 테스트를 실제 provider 검증으로 표시하지 않는다.
MCP Inspector는 추가 진단·CI 검증 도구로 사용할 수 있으나 앱의 필수 런타임은 아니다.
[공식 Inspector 가이드](https://modelcontextprotocol.io/docs/tools/inspector)

통과한 artifact를 app 관리 installation에 revision별로 설치하고, 검증된 digest와 launch config를 원자적으로 등록한다.
새 revision을 준비하는 동안 기존 호출은 기존 revision에 고정한다. 전환 시 신규 호출을 잠시 큐에 두고
기존 호출을 정해진 시간 안에 drain한 후 새 revision을 활성화한다. drain 실패 시 전환을 보류하고 기존 연결을 유지한다.
효과를 확인하지 못한 호출을 강제 재실행해 전환을 완료하지 않는다.
schema·권한이 확대되면 해당 차이를 policy가 재평가하며, 승인된 제작 범위의 일반 수정은 자동 활성화한다.
build/test/health 실패 시 기존 설치를 유지한다. rollback은 이전 artifact·config·schema snapshot을 복구한다.
rollback은 이미 발생한 외부 부수효과를 되돌린다는 의미가 아니며, write 호출 재시도는 idempotency 계약이 있을 때만 허용한다.

## 6. 버전과 완료 게이트

확인 시점 공식 MCP 가이드는 2026-07-28 revision이고, Swift SDK README는 2025-11-25 구현을 명시한다.
따라서 SDK를 채택했다는 이유로 최신 protocol 전체 지원을 선언하지 않는다. 지원 revision·transport·capability matrix를 고정한다.
부족한 기능은 wrapper/구현을 추가해 fixture를 통과시키거나 U와 구체적 미지원 사유로 표시하며 완성 요구에서 삭제하지 않는다.
[MCP versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning), [공식 Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

| 작업 묶음 | 완료 증거 |
| --- | --- |
| T1 카탈로그·코드 검색 | 이름 충돌·schema 오류·hook 수정 후 재검증·외부 경로 차단 fixture |
| T2 모델 독립 웹 검색 | 외부 API와 self-hosted backend 각각 검색→조회→실제 출처 인용; 오류·한도·취소 |
| T3 MCP 사용·자동 구성 | LAT-MCP-001~004/007, E2E-20: stdio/HTTP 연결→scope/credential→목록→실제 호출→reload/diagnose/rollback |
| T4 MCP 제작·활성화 | LAT-MCP-005~007, E2E-21: 자연어 요청→source/lock→mock 검증→package→등록→실제 agent 왕복 |
| T5 자율성·권한 회귀 | LAT-MCP-008, E2E-20/21: 위임 범위 내 반복 승인 없음, 권한 확대만 질문, 주입된 config/설명으로 self-approve 불가 |

T1과 T2의 독립 웹 검색·WebFetch 기본 기능은 M1 완료 게이트에 포함한다. T2의 시나리오는 E2E-19와 연결한다.
T3·T4·T5는 X9를 포함한 M4 확장 완료 게이트이며 E2E-20 자동 설정과 E2E-21 자체 제작을 모두 통과해야 한다.
고급 browser 조작·UI와 원격 서비스는 M6/M7 범위로 유지하되 기본 검색·본문 조회의 선행 조건으로 만들지 않는다.
최종 시나리오는 로컬 모델로 자료를 검색하고, 필요한 mock MCP 서버를 제작·활성화해 도구를 호출한 뒤 검증된 출처와 결과를 보고하는 것이다.
build 실패·취소·재시작·schema 변경·없는 credential에서도 성공을 꾸미지 않고 다음 가능한 작업과 미완료 원인을 정확히 남겨야 한다.
