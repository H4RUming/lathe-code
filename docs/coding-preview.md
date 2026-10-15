# M1 첫 코딩 흐름

2026-10-15. 앱과 CLI가 같은 엔진에서 **실제 모델 요청 → 도구 승인 → 파일/명령 실행 → 결과 전달**을
수행하는 첫 구현이다. M1 전체나 Claude Code 기능 동등성의 완료를 뜻하지 않는다.
기본 선택은 여전히 mock이며 저장한 모델 연결을 선택한 실행만 외부 API와 실제 도구를 사용한다.

## 모델 연결

앱의 `⌘,` → **모델 연결**에서 이름, API 형식, Base URL, 모델 ID를 저장한다.
현재 형식은 OpenAI Responses와 OpenAI 호환 Chat Completions 두 가지다.
Base URL은 API 루트다. 예를 들어 `/v1`을 포함한 주소에는 `/responses` 또는 `/chat/completions`를
붙이며 사용자가 지정한 proxy prefix를 보존한다. localhost·LAN·외부 주소를 같은 방식으로 받는다.
이것은 해당 주소의 모든 서버·모델과 호환된다는 보장이 아니다.

API 키는 네이티브 SecureField로 입력하고 macOS Keychain에 저장한다. 키 식별자는 profile ID와
Base URL에 묶이며 SQLite profile, run snapshot, 이벤트에 키를 넣지 않는다. 주소 변경 시 기존 키를
그대로 다른 서버로 보내지 않는다. 키를 다시 입력하거나 삭제해야 한다. 인증 없는 개인 서버는 키 없이 쓴다.
기본 연결은 HTTPS이며 HTTP는 해당 profile에서 명시적으로 허용해야 한다. HTTP에서는 대화와 키가 암호화되지 않는다.
모델 서버를 원격 주소로 바꿔도 코드와 명령은 선택한 **이 Mac의 프로젝트**에서 실행한다.

`reasoning effort`는 입력한 값을 Responses의 `reasoning.effort`, Chat의 `reasoning_effort`로 전달한다.
모델별 capability 검사, 로컬 Off/On 변환, Ultra는 아직 없다. 지원 여부는 서버 응답으로 드러나며
미지원 옵션을 조용히 지우거나 추론을 켰다고 추정하지 않는다.

## 권한과 도구

앱 작성창에서 연결과 권한을 고른 뒤 전송한다. 실행의 profile과 권한은 시작 시 snapshot으로 고정한다.
승인 카드에는 실행할 정확한 canonical JSON 인자를 표시하며 **이번 한 번 허용** 또는 **거절**을 선택한다.
승인은 invocation ID와 요청 hash에 묶이고 종료·재시작 후에는 사용할 수 없다.

| 모드 | 파일 읽기·목록 | 파일 쓰기 | 명령 실행 |
| --- | --- | --- | --- |
| `manual` / 수동 승인 | 허용 | 매번 승인 | 매번 승인 |
| `acceptEdits` / 편집 허용 | 허용 | 허용 | 매번 승인 |
| `plan` / 계획 | 허용 | 거절 | 거절 |
| `dontAsk` / 질문 없이 제한 | 허용 | 거절 | 거절 |

현재 제공하는 도구는 네 개다.

| 도구 | 계약 |
| --- | --- |
| `list_directory` | workspace 상대 경로, 최대 2,000 entries. `.`은 root다. |
| `read_file` | 256 KiB 이하 UTF-8 파일. SHA-256과 bounded JSON 미리보기, 전체 원본 blob을 저장한다. |
| `write_file` | 이전 SHA-256 또는 생성용 `missing` 필수. 전체 인자 JSON 32 KiB 안에서 파일 전체를 atomic replace/create한다. 상위 폴더는 이미 있어야 한다. |
| `run_command` | 절대 실행 파일·문자열 argv·workspace 상대 cwd·0.1~120초 timeout. 입력을 닫는 비대화형 실행, stdout/stderr 합계 128 KiB 한도. |

파일 도구는 경로 traversal, symlink, hardlink, `.git`, 엔진 데이터 접근을 거절한다. 열린 directory FD를
기준으로 상대 경로를 걷고 쓰기 직전 SHA를 다시 검사한다. 기존 파일의 변경 전 내용과 결과 blob 참조를
별도로 보존한다. 동일하거나 겹치는 workspace의 파일 쓰기·명령은 엔진의 write lease로 보호한다.
충돌 시 대기열에 자동 재시도하지 않고 실패 결과를 모델에 돌려준다.
외부 편집기의 마지막 검사와 atomic rename 사이 변경까지 원자적 비교·교환으로 막는 것은 아니다.

**명령은 sandbox 없이 macOS 사용자 권한으로 실행한다.** 승인 화면에 정확한 argv·cwd·한도와 이 사실을
표시한다. 파일 도구의 경로 제한이 shell에 적용되는 것은 아니다. 환경은 고정 system `PATH`와 `LANG`만
명시하고 부모 API 키를 상속하지 않는다. 개발 도구별 환경 profile, 사용자 PATH 선택, 대화형 터미널은 후속이다.
낮은 수준의 runner는 PTY를 지원하지만 현재 모델 도구와 앱에는 PTY 화면·입력 세션이 연결되어 있지 않다.

## CLI

연결을 저장하면 반환된 UUID로 실행한다. 실제 서버에 맞는 모델 ID를 넣는다.

```sh
.build/macos/lathe provider-set --name '개인 서버' --api openAIChat \
  --base-url http://localhost:8000/v1 --model MODEL_ID --allow-http
.build/macos/lathe providers --json
.build/macos/lathe run --workspace "$PWD" --provider PROFILE_UUID \
  --permission manual --detach '프로젝트를 읽고 필요한 수정과 테스트를 진행해 줘'
.build/macos/lathe tools RUN_UUID --json
.build/macos/lathe tool INVOCATION_UUID --json
.build/macos/lathe approve INVOCATION_UUID --hash REQUEST_HASH
.build/macos/lathe deny INVOCATION_UUID --hash REQUEST_HASH
.build/macos/lathe events --session SESSION_UUID --follow
```

`provider-set --id PROFILE_UUID`는 기존 연결을 갱신한다. API 키는 앱에서 입력하거나
`--key-stdin`으로 pipe된 stdin에서 받는다. 키를 명령 인자에 넣는 옵션은 없다.
`--clear-key`는 해당 연결의 키를 삭제한다. Base URL에 사용자명·암호·query를 넣을 수 없다.

`run --provider`를 생략하면 mock이다. 실제 모델의 headless 기본 권한은 `dontAsk`이며 승인 입력을
기다리지 않는다. `manual`과 `acceptEdits`는 `--detach`가 필요하고 앱 또는 별도의 `approve/deny`
명령으로 결정한다. `tools`는 프레임 한도 때문에 최근 네 호출만 반환하며 `tool ID`로 개별 조회한다.

## 기록·취소·복구

SQLite는 승인·실행 상태를 기록한다. 파일 변경 전 blob을 저장하고 실행 상태를 기록한 뒤 효과를 시작한다.
명령은 엔진 데이터 아래 invocation별 디렉터리에 request와 runner의 durable intent/events/result를 남긴다.
blob은 SHA-256 주소로 저장하며 읽을 때 digest를 확인한다. 화면은 결과 일부를 표시하고 전체 raw 출력과
변경 전 blob을 내려받거나 복원하는 UI는 아직 없다. 저장 정책·자동 삭제·checkpoint 복원도 후속이다.

사용자 취소는 모델 HTTP와 실행 helper로 전달한다. 유효한 성공 receipt가 이미 있으면 늦은 취소 때문에
그 효과를 미실행으로 바꾸지 않는다. 엔진 재시작 시 대기/승인된 호출은 `cancelled`, 실행 중 호출은
`unknown`, 진행 중 run은 `interrupted`로 복구한다. 모델 요청과 도구를 자동 재실행하지 않는다.
결과 receipt가 없거나 불일치하면 성공으로 처리하지 않는다. 원래 process group 정리의 한계와
helper SIGKILL 뒤 불명확한 효과는 [runner 계약](runner.md)을 따른다.

대화 context는 같은 profile snapshot에서 바로 앞 run이 완전히 완료된 경우에만 이어간다.
실패·취소·중단 또는 연결 변경 후에는 새 context로 시작한다. 자동 compaction이나 실패한 tool transcript
재개는 없다. 실행은 기본 12 model steps(설정 범위 1~24), 최대 64 tool calls, 기본 300초 승인 대기,
텍스트 응답 64 KiB, 저장된 context 2 MiB 한도를 사용한다. token·비용의 root budget은 미구현이다.

## 검증 범위와 다음 순서

계약 테스트는 SSE frame 분할·완료/중단 판별·tool 왕복·서명/continuation 보존·redirect 거절,
권한 결정·경로 우회·SHA 충돌·취소·journal 재사용 금지·복구를 검사한다. 실제 native helper를 이용한
테스트는 환경 격리·입력 EOF·원시 byte·timeout·취소와 자식 정리를 확인한다.
실제 URLSession HTTP·engine·CLI·runner를 사용하는 localhost fixture의 9개 검사가 통과했다.
승인된 read/write/shell 왕복, 취소·거절·truncated EOF, Responses continuation replay와 redirect 거절을 포함한다.
네이티브 앱에서도 연결 저장, 프로젝트 열기, fixture의 파일 수정·명령 실행 일회성 승인과 최종 응답을 확인했다.
이 화면 검증은 격리된 테스트 데이터와 인증 없는 localhost 서버를 사용했다.
명령과 실행 범위는 [개발 가이드](development.md#검증과-한계)를 따른다.
**실제 OpenAI 계정이나 vLLM/Ollama 서버 검증은 아직 하지 않았다.** fixture 통과를 live 호환성으로 표시하지 않는다.

다음 M1 작업은 코드 검색·웹 검색/본문 읽기, patch/move/delete와 변경 미리보기, 실행 profile·테스트 증거,
실행 예산과 모델 capability·Off/On 제어다. Google AI Studio·Vertex·Claude 전용 API와 Ollama native API,
MCP·Skills·Hooks·Ultra, 편집기와 디버거는 별도 후속 단계다. sandbox probe는 production 격리가 아니며
LLDB 실제 launch/attach timeout 게이트는 여전히 미완료다.

API 구현 근거는 OpenAI 공식 [function calling](https://developers.openai.com/api/docs/guides/function-calling),
[Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses),
[reasoning](https://developers.openai.com/api/docs/guides/reasoning),
[Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) 문서다.
이 문서에 맞춘 구현과 실제 서비스별 검증 결과는 구분한다.
