# 구현 순서와 커밋 계획

2026-10-15 기준 설계 초안. 앱 구현은 아직 시작하지 않았다.
설계 근거와 범위는 [아키텍처](architecture.md)를 따른다.

## 개발 단위

기능 하나를 사용 가능한 상태로 구현 → 해당 동작 검증 → diff 검토 → 기능별 commit → GitHub push 순서로 진행한다.
큰 기능은 독립적으로 검증 가능한 단위로 나눈다. 각 단계는 대략 한 기능 커밋이며 필요하면 여러 커밋으로 분리한다.
브랜치가 필요하면 `codex/<feature>`를 기본으로 사용한다. 사용자 변경과 무관한 파일은 커밋에 포함하지 않는다.
키·로컬 토큰·실제 대화·개인 프로젝트 내용은 fixture나 Git 이력에 넣지 않는다.

## 1차: 실제 코딩 작업을 끝내는 수직 구현

먼저 OpenAI와 vLLM/호환 서버 두 경로로 공통 코어를 검증한다.
이 순서는 다른 요청 프로바이더를 지원 범위에서 빼는 것이 아니라 API 차이를 일찍 검증하려는 구현 순서다.

| 순서 | 기능 / 커밋 예시 | 완료 기준 |
| --- | --- | --- |
| 01 | `feat(app): add native workspace and session shell` | Xcode 앱·로컬 Package, 창·사이드바·입력창, mock stream과 취소 |
| 02 | `feat(providers): add connections and keychain credentials` | 여러 연결, URL prefix·인증·모델 설정 저장, 키 재노출 없는 편집 |
| 03 | `feat(openai): stream responses through provider interface` | OpenAI 요청·스트림·usage·오류·취소, provider continuation 보존 |
| 04 | `feat(compatible): support vllm and custom endpoints` | Chat Completions, localhost/LAN/HTTPS, prefix·인증·도구 왕복 진단 |
| 05 | `feat(history): persist sessions and execution records` | 재시작 후 이력 복원, DB migration, 실행 intent/result 저장 기반 |
| 06 | `feat(agent): add read-only workspace tool loop` | 파일 탐색·읽기·검색·도구 결과 반환·반복 제한 |
| 07 | `feat(edits): review and apply tracked patches` | diff 승인, 경로 검증, 충돌 감지, 변경 journal과 복구 |
| 08 | `feat(commands): run and cancel workspace commands` | stdout/stderr·exit code·timeout·프로세스 그룹 종료 |
| 09 | `feat(review): show git changes and run outcomes` | 기존 변경 구분, Git diff, 변경→테스트→최종 설명 전체 흐름 |

1차 완료 시: 작은 실제 저장소의 수정 요청을 OpenAI와 vLLM 각각에서 완료하고, 중단·실패·기존 변경을 보존할 수 있다.

## 2차: 요청한 프로바이더 범위 완성

각 어댑터는 동일한 읽기→도구 결과→패치→명령 실행 흐름을 통과해야 한다. 채팅 연결만 성공하면 에이전트 지원 완료로 표시하지 않는다.

| 순서 | 기능 / 커밋 예시 | 완료 기준 |
| --- | --- | --- |
| 10 | `feat(anthropic): support messages and tool results` | SSE block 조립, tool_result 변환, thinking/signature 보존 |
| 11 | `feat(gemini): support ai studio generate content` | API key, 스트리밍, functionCall/Response, thought signature 보존 |
| 12 | `feat(vertex): add project endpoints and gcloud auth` | project/location, ADC helper, 인증 실패·토큰 갱신·quota 설정 |
| 13 | `feat(ollama): support native local and remote chat` | NDJSON, 모델 설정, thinking/tool_calls, 외부 URL·proxy 인증 |
| 14 | `feat(providers): add capability diagnostics and local presets` | 검증 상태 표시, 사용자 override, 추가 호환 서버 실제 왕복 확인 |
| 15 | `feat(sessions): switch providers with explicit context transfer` | 완료된 turn에서 전환, 출처 기록, opaque 상태 교차 전송 방지 |

Google Interactions, Vertex Express, vLLM Responses는 각각 후속 API flavor로 추가할 수 있다.
기타 서빙 방식은 API가 호환되면 프리셋/옵션을 추가하고, 다르면 전용 어댑터를 구현한다.

## 검증 전략

UI 미세 수정마다 테스트를 늘리기보다 실패 시 파일이나 실행 상태가 달라지는 경계에 집중한다.

- **스트림 계약:** 잘린 UTF-8/JSON, 여러 tool-call delta, 빈 텍스트의 서명 part, 잘못된 완료 신호, 중도 단절.
- **에이전트:** 정상 tool 왕복, 승인 거절, schema 위반, 무한 반복 제한, 도구 실행 중 취소.
- **파일:** 경로 이탈·symlink, 읽은 뒤 수정된 파일, 일부 patch 실패, 기존 사용자 변경 보존.
- **명령:** stdout/stderr 동시 대량 출력, timeout, 자식·손자 프로세스 취소, 종료 상태.
- **복구:** 쓰기 직전·직후 앱 종료, 불명확한 명령 재실행 방지, 세션 복원.
- **외부 서버:** 인증된 HTTPS, LAN HTTP 설정, reverse proxy prefix, 인증서 실패, 지연·타임아웃·중도 단절.
- **호환성:** provider·server version·model·parser 설정을 기록한 무해한 tool 왕복 smoke test.

CI는 macOS에서 Swift package test와 앱 build를 수행한다. 외부 키 없이 fixture/mock server로 동작시킨다.
실제 provider smoke test는 자격 증명이 준비된 환경에서 별도로 실행하며, 실행하지 못한 항목은 검증되지 않았다고 표시한다.
최소 OS에서의 앱 실행 확인은 최신 SDK 빌드와 별도다. 해당 환경이 없으면 지원을 검증했다고 주장하지 않는다.

## 후속 확장

- 대화형 PTY 터미널, 더 풍부한 코드·diff 탐색.
- MCP, 프로젝트별 도구 확장, 코드 인덱싱.
- Git worktree별 병렬 작업과 멀티 에이전트.
- 원격 workspace executor와 SSH 실행.
- 모델 다운로드와 로컬 서버 lifecycle 관리.
- 바이너리 GitHub Release, 서명·공증·자동 업데이트.

첫 구현 대상으로는 01의 네이티브 앱 골격과 mock 실행을 권장한다.
