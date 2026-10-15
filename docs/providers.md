# 프로바이더와 원격 모델 연결 계약

2026-10-15 설계 기준. 아직 구현되지 않은 목표 계약이다.
전체 구조는 [아키텍처](architecture.md), 기능 완료 기준은 [기능 정의](features.md)를 따른다.

## 1. 서비스와 API 어댑터


서비스 이름, API 형식, 서버 위치, 모델 능력을 별도 개념으로 둔다.

| 사용자에게 보이는 연결 | 초기 API 어댑터 | 인증/설정 |
| --- | --- | --- |
| OpenAI | `OpenAIResponsesProvider` | API key, model ID |
| Google AI Studio | `GeminiGenerateContentProvider` | Gemini Developer API key, model ID |
| Vertex AI | 같은 Gemini codec + Vertex 연결 계층 | project, location, model ID, gcloud ADC token helper |
| Anthropic Claude | `AnthropicMessagesProvider` | API key, model ID, API version |
| vLLM | `OpenAICompatibleChatProvider` | 사용자 URL, 필요시 Bearer/custom header |
| Ollama | `OllamaChatProvider` | 사용자 URL, 필요시 proxy 인증 |
| 기타 서버 | 지원하는 API 형식으로 연결 | 사용자 URL, 인증, 모델·호환성 옵션 |

초기 구현은 다섯 가지 API 어댑터다. Vertex와 AI Studio의 endpoint/auth는 분리하되 Gemini 콘텐츠 변환을 공유한다.
vLLM은 Chat Completions 프리셋부터 검증하고 Responses 사용은 후속 호환성 검증을 거친다.
Ollama는 native `/api/chat`을 기본으로 하며, 일반 OpenAI-compatible 연결도 별도 선택할 수 있다.
기타 서버는 실제 제공하는 API가 호환될 때 기존 어댑터를 사용한다. 임의의 모델 런타임을 자동으로 지원한다고 표시하지 않는다.

Google의 Interactions와 GenerateContent는 다른 wire format이다. 초기에는 Vertex와 공유하기 쉬운 GenerateContent를 명시적으로 선택한다.
Interactions를 추가할 때 별도 API flavor와 codec을 둔다. Vertex Express 인증/경로 역시 standard Vertex와 구분한다.

개인용 Vertex 인증은 설치된 `gcloud`를 통해 ADC access token을 얻는 방식으로 시작한다.
사용자가 외부에서 ADC login을 완료하고, 앱은 인자 배열로 `gcloud auth application-default print-access-token`을 실행한다.
Swift에서 ADC 전체를 재구현하는 것은 아니다. 토큰은 메모리에만 두고 요청 시 획득하며 동시 획득을 합친다.
이전 캐시 토큰의 남은 수명을 임의로 1시간이라고 가정하지 않는다. gcloud는 Vertex 연결에만 필요한 선택 의존성이다.

### 연결과 모델 프로필

`ProviderConnection`:

- id, 표시 이름, 서비스 프리셋, API flavor.
- base URL과 경로 prefix. endpoint builder가 `/v1` 중복이나 프록시 prefix 소실을 방지.
- 인증 전략: none / Bearer / provider API-key header / custom headers / Vertex gcloud helper.
- 비밀 값은 Keychain 참조, 비밀이 아닌 설정은 로컬 저장.
- 연결·첫 응답·스트림 무응답 제한, 취소 정책.
- 사용자 지정 네트워크 전송 설정과 연결 설정 revision.
- serving resource group과 동시 요청/대기 상한. 여러 URL/model이 같은 서버를 공유할 수 있음.

`ModelProfile`:

- connection ID, model ID, 표시 이름, context budget, 출력 한도.
- 도구 호출, 스트리밍, 병렬 호출, reasoning, structured output 등 capability.
- capability별 `unknown / verified / unsupported`, 근거, 확인 시점, 사용자 override.
- 해당 API가 지원하는 sampling/reasoning 옵션만 저장·전송.
- 실제 추론 위치에 대한 사용자 설명/확인 상태. URL만 보고 로컬 추론이라고 단정하지 않음.

`ReasoningCapability`는 추론 가능 여부만 저장하는 bool이 아니다. 제어 종류(boolean/enum/budget/always-on),
Off/On 지원, native 값과 기본값, 요청 필드/금지 조합, 서버/template 의존성, 근거·revision을 보관한다.
AI Studio와 Vertex가 Gemini codec을 공유해도 옵션 허용표는 서비스/API flavor별로 분리한다.
Ollama native와 OpenAI-compatible 경로도 같은 옵션 이름을 가정하지 않는다.

로컬·개인 서버에는 `Off / On / Ultra` preset을 제공한다. Off/On은 검증된 생성 제어로 해석하고,
Ultra는 reasoning 활성 모델들을 사용하는 Runtime 전략으로 처리한다. 모델에 `ultra`를 무조건 전송하지 않는다.
OpenAI·Google·Claude의 고유 effort/level/budget/mode는 실제 지원 값 그대로 보존하고 Ultra와 독립적으로 선택할 수 있다.
추론 출력 표시 여부는 생성 제어와 별개다. 상세 매핑·미지원 처리·기본값은 [추론·Ultra 계약](reasoning-and-ultra.md)을 따른다.

모델 목록 조회 성공은 도구 호출 지원의 증거가 아니다. 연결 진단은 일반 응답, 스트리밍, 무해한 도구 호출과 결과 반환까지 단계별로 확인한다.
검증 결과는 URL·모델·설정 revision에 연결한다. 모든 모델의 코딩 능력이나 향후 서버 설정까지 보장하지 않는다.

### 외부 모델 서버

동일한 연결 타입으로 아래 형태를 처리한다. 주소는 예시다.

| 서버 | 예시 |
| --- | --- |
| Mac의 vLLM | `http://localhost:8000/v1` |
| LAN의 vLLM | `http://192.168.1.20:8000/v1` |
| 외부 vLLM 프록시 | `https://models.example.com/team-a/v1` |
| Mac의 Ollama | `http://localhost:11434` |
| 외부 Ollama 프록시 | `https://models.example.com/ollama` |

- 외부 연결은 HTTPS를 기본으로 한다. HTTP 개발/LAN 서버는 해당 연결에 명시적으로 설정할 수 있게 한다.
- 인증서는 시스템 신뢰 검증을 사용한다. 사설 CA는 OS 신뢰 설정으로 처리하며 전역 인증서 검증 해제는 제공하지 않는다.
- Bearer/custom header는 연결별로 저장한다. 다른 origin으로 redirect할 때 자격 증명을 전달하지 않는다.
- 역방향 프록시의 경로 prefix, 타임아웃, 스트리밍 buffering 영향을 연결 진단에서 드러낸다.
- 연결 실패, 인증 실패, 모델 없음, capability 오류, 첫 토큰 대기, 중간 스트림 단절을 구분한다.
- 연결이 끊기면 미완성 tool call은 실행하지 않는다. 도구 실행 이후 무작정 전체 turn을 재시도하지 않는다.
- provider 장애 때 다른 클라우드로 자동 전환하지 않는다. 사용자가 대상 연결을 선택한다.

모델 endpoint와 workspace executor를 서로 독립적으로 둔다. 외부 모델 서버 연결은 원격 파일 접근이나 원격 shell 실행을 의미하지 않는다.
Ollama localhost도 cloud 모델을 중계할 수 있으므로 `localhost == 모든 추론이 내 Mac`이라는 표시를 하지 않는다.

## 2. API 경계와 스트리밍

개념 인터페이스:

```swift
protocol ModelProvider: Sendable {
    func stream(_ request: ModelRequest) async throws
        -> AsyncThrowingStream<ModelEvent, Error>
}
```

`ModelEvent`는 text delta, tool-call assembly, usage, 정상 완료를 표현한다. 네트워크·프로토콜 실패는 typed error로 반환한다.
정상 완료에는 finish reason과 재전송에 필요한 provider continuation state가 포함된다.
스트림 종료와 정상 응답 완료를 구분하며, task 취소는 HTTP 요청 취소까지 전달한다.

- SSE와 NDJSON은 프레이밍 계층을 분리한다. UTF-8·JSON이 임의 byte 경계로 잘릴 수 있다.
- 도구 호출은 provider의 ID/index/block 기준으로 조립한다. 공통 ID가 없으면 어댑터가 매핑한다.
- 어댑터가 정상 완료를 확인한 호출만 JSON/schema 검증 후 실행 대상으로 넘긴다.
- 불완전한 JSON, 토큰 한도 종료, 연결 단절, 알 수 없는 tool은 파일 변경 전에 처리한다.
- UI용 텍스트와 다음 요청에 필요한 provider 원본 블록을 분리 저장한다.
- OpenAI reasoning items, Gemini thought signatures, Anthropic thinking/signature는 provider별 규칙에 맞게 원형 보존한다.
- provider 고유 상태는 다른 provider에 전달하지 않는다. UI에 노출할 요약과 opaque continuation 데이터를 구분한다.

provider/model/추론 옵션 변경은 안전한 실행 경계에서 새 snapshot으로 적용한다. 기본은 현재 turn 종료이며,
진행 중 변경은 요청 취소·진행한 효과 정리 후 새 run으로 전환한다. Ultra의 진행 중 child에는 기존 snapshot이 유지된다.
다른 연결로 전환할 때 사용자·assistant 텍스트와 도구 결과·명시적 요약으로 새 실행 분기를 만들고,
출처와 전환 지점을 기록한다. 숨겨진 provider 상태를 단순 문자열로 변환해 전달하지 않는다.

## 3. 참고 문서


아래는 2026-10-15에 확인한 공식 문서다. API 버전·모델 기능은 실제 어댑터 구현 시 다시 검증한다.

- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses): SSE와 의미별 이벤트.
- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling), [reasoning](https://developers.openai.com/api/docs/guides/reasoning): 도구 결과 왕복과 재전송 상태.
- [Gemini GenerateContent](https://ai.google.dev/api/generate-content), [Interactions streaming](https://ai.google.dev/gemini-api/docs/streaming): 서로 다른 API 형식.
- [Gemini thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures): opaque part 상태 보존.
- [Google REST 인증](https://docs.cloud.google.com/docs/authentication/rest), [gcloud ADC token](https://docs.cloud.google.com/sdk/gcloud/reference/auth/application-default/print-access-token): Vertex 인증 helper의 근거.
- [Vertex function calling](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/tools/function-calling): Gemini tool 형식.
- [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [tool results](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls), [thinking](https://platform.claude.com/docs/en/build-with-claude/thinking): block stream·tool 결과·서명 보존.
- [vLLM API](https://docs.vllm.ai/en/stable/serving/online_serving/openai_compatible_server/), [tool calling](https://docs.vllm.ai/en/stable/features/tool_calling/): 호환 범위와 서버/parser 설정.
- [vllm-metal](https://github.com/vllm-project/vllm-metal): Mac 추론 런타임도 가능하며 설치/운영은 앱 연결과 별도 범위.
- [Ollama chat](https://docs.ollama.com/api/chat), [streaming](https://docs.ollama.com/api/streaming), [authentication](https://docs.ollama.com/api/authentication): NDJSON, native API, localhost와 실제 추론 위치의 차이.
- [Apple AppKit bridge](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [Keychain](https://developer.apple.com/documentation/security/keychain-services): 네이티브 UI와 자격 증명 저장.
