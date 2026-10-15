# 추론 제어와 Ultra 실행 설계

작성·공식 문서 확인: **2026-10-15**. 구현 전 설계이며 아래 기본값은 검증 후 조정할 제안이다.
관련 문서: [기능](features.md), [구조](architecture.md), [프로바이더 계약](providers.md), [확장](extensions.md), [구현 순서](roadmap.md).
`LAT-REASON-001~008`의 세부 계약이며 단일 agent 제어는 M3/E2E-17, Ultra 전체는 M5/E2E-18에서 검증한다.

## 1. 제품 동작과 독립된 두 제어

개인 서빙 연결(vLLM·Ollama·기타 호환 서버)은 **Off / On / Ultra**를 제공한다. localhost뿐 아니라 LAN·원격 서버에도 같은 의미를 적용한다.
OpenAI·Google AI Studio·Vertex·Claude 연결은 해당 모델의 **공급자 고유 추론 옵션**을 노출한다. 모든 공급자의 수준을 같은 숫자로 환산하지 않는다.
서비스 preset과 API flavor로 UI 정책을 정하며, URL이 localhost인지 여부로 추론 방식이나 데이터 처리 위치를 추정하지 않는다.

| 선택 | 모델 추론 설정 | 에이전트 실행 방식 |
| --- | --- | --- |
| Off | 지원하는 모델의 확장 추론 모드를 실제 요청 옵션으로 끔 | 일반 실행. 검색·편집·shell·검증·확장 도구 사용 가능 |
| On | 지원하는 모델의 확장 추론 모드를 켬 | 일반 실행. 모델이 도구를 반복 사용하며 요청을 끝까지 수행 |
| Ultra | 참여하는 모든 모델 agent에서 추론 활성 상태를 요구 | 독립 context를 가진 여러 agent가 조사·구현·검토·검증을 역할별로 수행 |
| 공급자 고유 옵션 | 모델이 허용하는 mode·effort·budget을 원래 의미로 전달 | 기존 agent/workflow 실행과 독립적으로 설정 |

내부적으로 `ReasoningSelection`과 `OrchestrationProfile`을 분리한다. Ultra는 새로운 모델 파라미터나 `reasoning_effort: ultra`가 아니다.
Off는 모델의 모든 계산·판단 능력을 제거한다는 뜻이 아니다. 지원 API가 제공하는 확장 추론 모드의 비활성화를 뜻한다.
Off/On도 일반적인 명시적 subagent 요청을 지원한다. Ultra는 여러 추론 agent의 역할 분담과 독립 검증을 자동 실행하는 제품 preset이다.
Ultra에서도 [전체 기능 요구사항](features.md)의 파일·터미널·Git·MCP·skills·hooks·계획·승인·세션 기능을 사용한다. 토론만 하는 별도 채팅 기능으로 축소하지 않는다.

## 2. 모델별 지원 판정과 잘못된 Off 방지

`ReasoningCapability`는 connection revision·API flavor·server version·model ID/digest·template revision에 묶는다. 알 수 없는 값은 추정 확정하지 않는다.
필드는 `controlKind`, 허용 mode/value, 기본값, `canEnable`, `canDisable`, budget 범위/의미, tool 동시 지원, 출력 형태, 근거·검증 시각을 가진다.
`controlKind`는 toggle / named levels / token budget / fixed-on / fixed-off / unknown을 구분하며 실제 조합은 공급자 schema가 검증한다.

| 모델 상태 | Off | On | Ultra |
| --- | --- | --- | --- |
| 켜기·끄기 모두 검증됨 | 선택 가능 | 선택 가능 | 추론+tools 왕복 검증 후 가능 |
| 항상 추론 | 비활성: 모델이 끄기를 지원하지 않음 | 선택 가능, 고정 상태 표시 | tools 조건을 충족하면 가능 |
| 비추론 모델 | 선택 가능, 고정 상태 표시 | 비활성 | 비활성; 추론 지원 모델 선택 안내 |
| 미확인/metadata 없음 | 미확인 표시 | 미확인 표시 | 진단 전 비활성 |

미확인 모델은 별도의 “서버 기본값으로 실행”을 허용할 수 있지만 이를 Off/On/Ultra 성공으로 기록하지 않는다.
raw JSON override는 전문가 설정으로 제공하되 중복·충돌하는 추론 키를 요청 전에 거절한다. override에는 사용자 지정·미검증 상태가 남는다.
진단은 metadata/공식 model template 확인, 유효 파라미터 검사, 스트림, 무해한 tool 왕복을 묶는다. 짧은 답에서 추론 텍스트가 없다는 사실만으로 Off를 검증하지 않는다.
parser 비활성화, 출력 panel 접기, 응답에서 thinking 필드 제거, “생각하지 마” prompt만으로 Off를 구현하지 않는다.
프로바이더가 반환하지 않는 추론을 만들어 표시하지 않는다. UI에는 공개된 요약·실제 reasoning field·진행 알림·opaque 상태를 서로 구분한다.

## 3. 공식 API 확인 내용과 adapter 계약

아래는 확인일의 사실 요약이다. 모든 모델에 동일하게 적용하는 목록이 아니며 실제 연결에서 허용값을 다시 검증한다.

| 연결 | 확인한 API 동작 | Lathe 매핑 결정 |
| --- | --- | --- |
| vLLM | model template별 `chat_template_kwargs`가 다르다. Qwen3 예시는 `enable_thinking`; 일부 모델은 `thinking`을 사용한다. 최신 서버는 `reasoning_effort`로 `enable_thinking`을 주입하지만 template이 지원하지 않으면 효과가 없다. | 서버·template profile에 검증된 키 하나를 선택. “OpenAI 호환”만으로 Off 지원을 가정하지 않음 |
| Ollama native | `/api/show`의 `thinking.values`·`default`를 조회한다. `/api/chat`의 `think`는 boolean/null/모델별 문자열이며 미지원 문자열이 기본값으로 처리될 수 있다. | 허용값을 먼저 검사. boolean 지원 시 false/true, 수준형은 검증된 native value로 On 설정. 목록에 false가 없으면 Off를 만들지 않음 |
| Google GenerateContent | `generationConfig.thinkingConfig`의 `thinkingLevel`과 `thinkingBudget`은 모델 세대별 제어다. `minimal`은 추론 완전 비활성화를 보장하지 않으며 2.5 Pro는 Off를 지원하지 않는다. | level·budget 중 지원 항목만 UI에 노출. budget 0은 해당 모델이 허용할 때만 Off 의미. AI Studio와 Vertex의 허용표를 별도로 검증 |
| Anthropic Messages | `thinking.type`과 `output_config.effort`는 별개다. adaptive·enabled+budget·disabled·between_tools의 지원과 조합 제한이 모델마다 다르다. | Models API capability와 모델별 규칙으로 mode/effort/budget UI 구성. `between_tools`를 완전 Off로 번역하지 않음 |
| OpenAI Responses | `reasoning.effort`와 지원 모델의 `reasoning.mode`가 별개로 존재한다. 허용 effort·mode·sampling 조합은 모델별이다. | native effort/mode와 orchestration을 분리. `none`을 모든 모델의 Off로 가정하지 않고, 미지원 sampling 옵션은 보내지 않음 |

vLLM의 `include_reasoning=false`는 생성을 끄지 않고 응답 노출만 줄인다. `thinking_token_budget`은 지원 설정에서 reasoning 종료 경계를 강제하는 별도 기능이다. 최신 `reasoning`과 구버전 `reasoning_content`의 응답 차이도 versioned codec에서 처리한다. [vLLM 공식 추론 문서](https://docs.vllm.ai/en/stable/features/reasoning_outputs/)
Ollama metadata의 부재는 추론 부재의 증거가 아니다. `think: null`도 Off가 아니라 모델 기본값이다. [Ollama thinking](https://docs.ollama.com/capabilities/thinking), [chat API](https://docs.ollama.com/api/chat)
Google은 level과 budget을 함께 보내지 않는다. 특히 최신 모델의 budget 처리 규칙이 Developer API와 Vertex 문서에서 다르므로 공유 codec에도 서비스별 검증 계층이 필요하다. [Developer API](https://ai.google.dev/gemini-api/docs/generate-content/thinking), [Vertex](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/thinking)
Claude의 effort는 엄격한 token 상한이 아니다. `display: omitted`는 생각을 끄는 옵션이 아니며, manual budget은 지원 모델에서만 사용한다. [thinking](https://platform.claude.com/docs/en/build-with-claude/thinking), [effort](https://platform.claude.com/docs/en/build-with-claude/effort), [extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)
OpenAI의 native mode/effort는 API 계약의 의미를 유지한다. `pro` 같은 native mode와 Lathe의 Ultra는 같은 설정이 아니다. [reasoning](https://developers.openai.com/api/docs/guides/reasoning), [배포 설정 검증](https://developers.openai.com/api/docs/guides/deployment-checklist)

## 4. 설정 저장과 실제 요청 snapshot

선택 우선순위는 사용자 전역 기본 → 프로젝트 기본 → 세션 선택 → 명시적 역할 override다. 가장 구체적인 설정이 이기되 모델 capability 검증은 항상 수행한다.
Ultra의 “모든 agent 추론 활성” 조건과 충돌하는 역할 override는 시작 전에 거절한다. 다른 cloud로 자동 fallback하지 않는다.
cloud의 native 설정, 로컬 On 설정, Ultra 역할 설정은 별도 보관하며 연결을 바꿔도 이전 설정을 손실하지 않는다.

```swift
struct EffectiveModelRequestSnapshot: Codable, Sendable {
    let requestID: UUID
    let runID: UUID
    let agentID: UUID
    let phaseID: String
    let connectionRevision: String
    let modelProfileRevision: String
    let capabilityRevision: String
    let requestedPreset: String?       // off / on / ultra; cloud는 nil
    let reasoningState: String        // enabled / disabled / defaultUnverified
    let nativeReasoning: JSONValue    // 비밀을 제외한 실제 전송 옵션
    let outputLimit: Int
    let budgetReservationID: UUID
    let contextManifestID: UUID
    let toolPolicyRevision: String
    let orchestrationRevision: String
}
```

이는 개념 계약이다. 구현 시 문자열 상태를 enum으로 고정하고 JSON schema와 event version을 정의한다.
선택한 값, 실제 전송값, 서버가 수락한 사실, 측정된 usage를 구분한다. 200 응답만으로 모델 내부 동작까지 증명했다고 표시하지 않는다.
snapshot은 요청 전 journal에 저장하고 secret은 Keychain 참조만 사용한다. 원본 prompt 전체를 일반 진단 로그에 복제하지 않는다.
요청마다 유지해야 하는 reasoning blocks·thought signatures·opaque continuation은 해당 agent/provider 안에서 보존한다.
다른 agent에게는 산출물·근거·요약을 전달하며 숨겨진 내부 상태를 prompt 문자열로 변환하지 않는다.

## 5. Ultra의 실행 단계와 역할

Ultra는 `UltraCoordinator`가 versioned workflow graph를 실행하는 orchestration profile이다. 모델의 “더 깊게 생각해” 지시만으로 구현하지 않는다.
초기 제안은 **논리 역할 5개**, 동일 endpoint/model 재사용이며 역할별로 context·tool scope·예산·완료 조건을 가진다.

| 단계 | 역할과 작업 | 다음 단계로 전달하는 결과 |
| --- | --- | --- |
| 0. 준비 | coordinator가 목표·workspace·현재 변경·권한·추론 지원·예산을 확인 | run manifest, baseline revision, 검증 조건, phase graph |
| 1. 조사 | explorer가 코드·실패 근거 수집; reviewer가 독립 접근·누락 위험 조사 | 경로·line·revision·명령 결과를 포함한 조사 결과와 대안 |
| 2. 계획 | coordinator가 결과 충돌을 정리하고 구현 범위·task dependency 확정 | 검증 가능한 plan; plan 모드에서는 여기서 검토 대기 |
| 3. 구현 | implementer가 할당한 source 범위에서 수정·필요한 중간 검증 | patch/commit 참조, 변경 이유, 수행한 검사, 미해결 항목 |
| 4. 독립 검증 | reviewer가 실제 diff 검토; verifier가 테스트·build·재현 수행 | revision에 연결된 findings와 검증 증거; 성공/실패/미실행 구분 |
| 5. 보완 | coordinator가 채택한 finding을 implementer에게 반환; 영향 검사 재실행 | 수정 revision 및 재검증 결과; 정한 횟수까지만 반복 |
| 6. 통합·보고 | coordinator가 승인된 결과만 통합하고 완료 조건 평가 | 최종 diff·검증·한계·남은 작업·agent별 사용량 |

단순 설명 요청은 구현 대신 독립 조사·검토·종합으로 graph를 조정한다. 적어도 두 개의 별도 추론 agent가 실제 기여해야 Ultra 완료다.
코딩 요청은 구현과 실제 검증 단계를 생략한 채 여러 답변의 다수결만으로 끝내지 않는다. 미완료 검증은 결과에 남는다.
reviewer는 implementer의 주장과 별도로 baseline·현재 diff·수용 기준에 접근한다. 같은 모델의 동의는 정확성 증거로 취급하지 않는다.
모든 역할은 공통 ToolBroker를 사용한다. 역할별 tool subset은 task에 맞추되 부모 권한을 초과하지 않는다.
hooks·MCP·skills·LSP·Git·web·PTY의 실행 사건에도 run/agent/phase provenance가 붙는다. worker가 직접 별도 shell 경로를 우회 생성하지 않는다.
도구 호출을 지원하지 않는 reasoning 모델은 완전 Ultra coding profile의 구성원으로 검증하지 않는다. 별도 읽기 전용 자문 역할은 capability와 한계를 명시한다.

## 6. 같은 endpoint의 큐와 workspace 쓰기 조정

**agent 개수와 동시 HTTP 요청 수는 다르다.** 하나의 로컬 모델을 순차 사용해도 context가 독립된 다중 agent 실행이 가능하다.
endpoint resource group별 scheduler가 slot을 배분한다. URL alias·동일 backend를 공유하는 모델은 사용자가 하나의 resource group으로 묶을 수 있다.
coordinator·worker·reviewer·goal/승인 evaluator의 모든 모델 요청을 같은 slot·예산 계산에 포함한다. “관리용” 요청이 병렬 상한을 우회하지 않는다.
slot을 기다리는 요청은 `queued`이며 아직 inference 중으로 표시하지 않는다. queue timeout·첫 응답 timeout·stream idle timeout을 별도 측정한다.
공정 큐와 우선순위를 두어 Ultra가 다른 세션을 굶기지 않게 한다. 대기 중 취소한 요청은 서버에 보내지 않는다.
Ollama는 메모리 여유에 따라 병렬 처리·model loading·queue가 달라지고 병렬 context는 메모리를 더 요구한다. 서버 overload는 503일 수 있다. [Ollama 동시 처리](https://docs.ollama.com/faq#how-does-ollama-handle-concurrent-requests)
Lathe는 로컬 RAM 상태와 측정 latency, endpoint 오류, 사용자가 설정한 한도를 참고한다. 원격 GPU 메모리는 telemetry가 없으면 알 수 없다고 표시한다.
앱이 서버의 GPU/VRAM 사용량을 정확히 예약한다고 주장하지 않는다. OOM·과부하가 나면 신규 요청을 줄이고 사용자에게 원인·재시도 상태를 보여준다.
서버 환경변수, 모델 unload, context 크기를 다른 사용자의 실행에 영향을 주도록 자동 변경하지 않는다.

하나의 checkout에는 한 writer lease만 부여한다. 병렬 구현은 각기 isolated worktree를 사용하며 변경을 통합한 뒤 최종 revision을 다시 검증한다.
동일 checkout에서 explorer/reviewer가 읽을 때도 baseline revision을 기록한다. 읽는 동안 코드가 바뀌면 결과를 stale로 표시한다.
verifier의 build/test는 source 읽기만 하더라도 build cache·산출물을 쓸 수 있으므로 scratch directory·port·process ownership을 따로 할당한다.
lease를 가진 agent가 명령까지 포함한 쓰기 경로를 독점하며 외부 사용자 편집은 hash 검사로 충돌 처리한다. 파일 단위 약속만으로 임의 shell 쓰기를 격리했다고 주장하지 않는다.

## 7. 예산과 초기 제안값

아래는 제품의 영구 고정값이나 모델 성능 보장이 아니다. 대표 Mac·원격 GPU·모델별 coding fixture를 측정한 뒤 profile별로 조정한다.

| 설정 | 초기 제안 | 집행 방식 |
| --- | --- | --- |
| 로컬 기본 선택 | On 지원·tools 검증 모델은 On; 그 외 확인된 기본 상태 | Ultra 자동 승격 없음; 사용자가 세션에서 선택 |
| Ultra 논리 역할 | coordinator·explorer·implementer·reviewer·verifier 5개 | graph에서 역할 task 생성·완료 상태 추적 |
| endpoint 요청 동시성 | 미측정 1; 충분한 자원 검증 후 사용자 설정으로 2 이상 | endpoint resource group slot; 상한을 자동 초과하지 않음 |
| source writer | checkout마다 1 | workspace lease; 병렬 writer는 별도 worktree |
| run 시간/출력/도구 상한 | 30분 / 생성 token 64k / tool 호출 100회 | 실행 전 예약·누적 집계; 한도에 도달하면 partial로 중지 |
| 요청 출력 한도 | 모델 profile의 검증값; 로컬 초기 후보 8k | reasoning+답변+tool JSON이 들어갈 한도 확인; context보다 작게 제한 |
| reasoning 세기 | 로컬 On의 검증된 기본 수준 | Ultra가 모든 agent를 무조건 최고 수준으로 올리지 않음 |
| 수정 반복/일시 장애 retry | 최대 2회 / 최대 2회 | 실패 원인 기록; 비멱등 tool 효과를 자동 반복하지 않음 |

위 token 상한은 출력 예산이다. 입력·cache·reasoning·총 token·비용은 별도로 집계하고 provider가 제공하지 않는 수치는 unknown/estimate로 표시한다.
여러 요청을 동시에 시작하기 전에 각 요청 출력 상한을 run 잔여 예산에서 예약해 oversubscription을 막는다. 결과 후 사용분으로 정산한다.
usage가 누락되어 정확히 정산할 수 없으면 예약량을 소비한 것으로 보수적으로 유지한다. 숨겨진 reasoning usage를 0으로 보지 않는다.
엄격한 run 비용 상한은 현재 단가·usage 계산이 검증된 profile에서만 제공한다. network 취소 후 서버가 생성한 토큰의 과금 종료까지 보장하지 않는다.
출력 한도 도달로 tool JSON이 잘렸으면 해당 tool은 실행하지 않는다. reasoning budget과 전체 출력 한도는 별도이며 응답/도구 인수를 위한 여유를 남긴다.

## 8. 중단·전환·실패·복구

| 상황 | 처리 계약 |
| --- | --- |
| 전체 중지 | 새 phase/agent/요청을 막고 queue 제거, HTTP 취소, 해당 run의 process group 중지. 이미 적용된 변경은 journal에 남김 |
| agent 하나 실패 | 의존 phase를 대기시키고 원인·partial 산출물 표시. 무관한 읽기 작업은 예산 안에서 진행 가능 |
| model/추론 옵션 거부 | capability를 재확인하고 configuration 오류로 중지. On을 Off로 낮추거나 다른 provider로 조용히 바꾸지 않음 |
| 일시 overload | backoff와 횟수 제한으로 모델 요청 재시도. 이전 tool 효과는 재실행하지 않음 |
| Off↔On 변경 | 현재 run에는 고정된 설정 유지, 다음 run에 적용. 즉시 변경은 중지·안전 지점 저장 후 새 run 시작 |
| On↔Ultra 변경 | 기존 run을 graph 중간에서 변환하지 않음. 중지/완료 뒤 새 orchestration revision으로 이어가며 전환 기록 |
| 모델/연결 변경 | 새 run에서 capability·tool·예산 재검증; provider opaque 상태는 넘기지 않고 전달 가능한 요약·근거 사용 |
| 앱/engine crash | event journal에서 phase·agent·예산 예약·lease·tool 실행 상태 복구. 효과 불명확한 명령은 확인 전 replay하지 않음 |
| endpoint가 실제 실행을 계속함 | client 취소와 server 완료 상태를 구분. 완료 확인이 안 되면 취소 요청됨/결과 미확인 표시 |
| 재개 시 profile 변경 | 원래 snapshot을 지원하는지 검사. 지원이 사라졌으면 명시적 새 profile 선택까지 실행 대기 |

완료한 phase는 산출물 hash·workspace revision·입력 manifest가 유효할 때만 재사용한다. 변경된 dependency 아래의 단계는 stale로 표시하고 다시 계획한다.
재개가 새 사용자의 승인이나 더 넓은 tool 권한을 암묵적으로 만들지 않는다. 승인 대기 상태도 원래 agent·대상·인수를 유지한다.

## 9. UI·CLI와 검증 기준

입력창에 로컬 `Off / On / Ultra` 또는 cloud native selector를 둔다. cloud에서도 실행 전략은 일반/Ultra로 별도 선택하며
native 추론 옵션을 유지한다. 혼합 역할 profile도 각 역할의 추론 활성 조건을 검사한다. disabled 선택지는 원인을 짧게 보여준다.
Ultra 실행 화면에는 phase, agent 역할·모델·실제 추론 설정, queued/running, 요청 slot, writer owner, 누적 예산을 표시한다.
추론 표시 접기/펴기는 별도 UI 설정이며 실행 모드를 바꾸지 않는다. 원본 signature 보존은 표시 설정과 독립이다.
선택적으로 빌드한 개발 CLI도 실행 중인 앱에 연결해 같은 typed configuration을 사용한다. 최종 flag 이름을 정할 때 local preset과 native reasoning JSON/typed flags를 분리하고 상충 옵션을 거절한다.

| 검증 ID | 통과 조건 |
| --- | --- |
| RU-01 토글 계약 | 알려진 toggle 모델에서 Off/On의 실제 요청 필드와 tool 왕복 검증; 출력 숨김을 Off로 오인하지 않음 |
| RU-02 미지원·오류 | fixed-on/fixed-off/unknown·Ollama 미지원 문자열·서버 옵션 거부에서 정확한 비활성/오류 표시 |
| RU-03 native 제어 | OpenAI·AI Studio·Vertex·Claude의 지원 모델 옵션만 전송, 금지 조합 사전 거절, native 기본값 보존 |
| RU-04 Ultra coding | 최소 두 독립 추론 agent 기여, 조사→실제 수정→독립 검증→근거 있는 최종 보고; 각 snapshot 확인 |
| RU-05 slot·writer | 동시성 1에서도 Ultra 완료, 동시성 N 상한 준수, 같은 checkout의 중복 writer 차단 |
| RU-06 예산 | parallel 예약 포함 상한 집행, usage 부재 처리, OOM/503/잘린 tool JSON의 실패 처리 |
| RU-07 수명 | queue·stream·shell·승인 대기 중 취소, crash·재개·모드 변경 후 중복 파일/API 효과 없음 |
| RU-08 전체 도구 | Ultra에서 파일·PTY·Git·hooks·MCP·skill·worktree·승인 정책과 기존 E2E가 유지됨 |

검증 기록에는 server/model/template·API flavor·옵션·하드웨어/원격 여부·날짜·통과한 fixture를 남긴다.
Ultra가 항상 더 빠르거나 더 정확하다고 보장하지 않는다. 같은 과제를 On과 Ultra로 평가하여 성공률·변경 품질·총시간·token·자원 사용을 비교한다.
