# 기능 누락 점검과 보완 우선순위

점검일: **2026-10-15**. 비교 시작점: `c004829`의 104개 요구사항·21개 E2E.
이번 점검은 설계의 범위와 완료 조건을 검토했다. 앱·엔진·도구의 실제 구현 검증은 아직 하지 않았다.
공식 문서의 공개 동작과 저장소 설계를 비교했으며 Claude Code 바이너리의 전체 동작을 인증한 감사는 아니다.

결론: 코딩 agent loop·파일/터미널·검색·세션·권한·Git·Ultra·MCP 기본 범위는 이미 정의되어 있다.
하지만 실제 개발 작업을 끝내는 데 필요한 **13개 보완 영역**이 확인되었다. 아래 요구와 수용 기준을
[기능 명세](features.md), [아키텍처](architecture.md), [구현 계획](roadmap.md)에 연결했다.
보완 후 설계는 **119개 요구사항·29개 E2E**이며 숫자 증가는 구현 완료를 뜻하지 않는다.

## 1. 판정 기준

- **누락**: 해당 사용자 흐름이나 상태 전환이 정의되지 않음.
- **불충분**: 기능 이름은 있지만 실제 성공/실패·재개를 판정할 수용 조건이 부족함.
- **parity**: Claude Code의 공개 사용자 흐름 또는 설정 형식과 대응함.
- **다중 provider 필수**: 모델/API를 바꿔도 agent loop가 의미를 유지하기 위해 필요함.
- **네이티브 강화**: Lathe의 macOS 개발 경험을 구체화하는 목표. Claude 내장 기능이라고 주장하지 않음.

P1은 핵심 작업 성공에 직접 영향을 주는 항목, P2는 통합·반복 사용에 필요한 항목,
P3는 핵심 루프 이후 완성할 입력 편의 기능이다. 모두 미구현이며 구현 단계는 의존성에 따라 나눈다.

## 2. 확인한 보완 항목

| ID / 우선순위 | 기존 설계에서 부족했던 점 | 보완 계약·완료 근거 | 분류·구현 단계 |
| --- | --- | --- | --- |
| G01 / P1 실행 profile | TOOL-006/010에 명령·server 수명은 있으나 재사용 build/run/test 설정과 공개 launch 파일 호환이 없음 | EXEC-001: cwd/env/toolchain/대상·인자·준비 조건·revision을 고정, 같은 profile의 GUI/CLI 실행 재현 | parity+네이티브; M1 기반, M2 완성, M4 import |
| G02 / P1 환경·worktree 준비 | PATH 표시·worktree 생성은 있으나 새 checkout의 dependencies·ignored config·setup 실패 처리가 없음 | EXEC-002: doctor→허용 setup/include→ready, 중간 실패/취소/재시도, 실제 fresh worktree 테스트 | parity; M1 진단, M2 준비, M5 Ultra 통합 |
| G03 / P1 테스트 증거 | 테스트 log를 연결하지만 test case 상태·0 tests·partial artifact·source revision 판정이 약함 | EXEC-003: case별 결과·원본 artifact·attempt, build-only/zero/skipped/cancelled와 현재 revision 성공 구분 | 네이티브 강화; M1 기반, M2 adapter, M6 UI |
| G04 / P1 실제 디버거 | shell에서 lldb를 호출할 수 있는 구조만 있고 디버거 세션/제어 계약이 없음 | DEBUG-001~003: LLDB-DAP launch/attach→breakpoint→stack/variables→step→수정/재실행, stale handle·crash·detach | 네이티브 강화; M0 spike, M2 코어, M6 UI |
| G05 / P1 여러 작업 root | 단일 root와 파일/폴더 첨부는 있으나 한 세션에서 frontend/backend 저장소를 함께 수정하는 범위가 없음 | WORKSPACE-001: root별 cwd/Git/지침/권한, 추가·제거·resume, 별도 diff/checkpoint | parity; M2, M6 UI |
| G06 / P1 MCP 비텍스트 결과 | 사용자 이미지 첨부는 있으나 MCP screenshot을 모델에 실제 이미지로 전달하는 경로가 없음 | MCP-009: typed blob→vision→후속 재사용, 모델에 전달한 내용과 UI 표시 구분, 미지원 content 보존 | parity+다중 provider; M3 codec, M4 왕복 |
| G07 / P1 응답 종료 의미 | finish reason 저장은 있으나 정상 HTTP의 pause/blocked/빈 candidate가 완료 loop와 어떻게 연결되는지 없음 | PROVIDER-006: final/client tool/server continuation/blocked/truncated/empty를 구분, 제한된 continuation·취소 | 다중 provider 필수; M1, M3 모든 adapter |
| G08 / P1 실제 context 한도 | 앱 context 예산만 있고 모델 최대·실제 서버·요청 설정 불일치 처리 계약이 없음 | PROVIDER-007: 세 한도와 근거 분리, 앱 32k/서버 4k 진단, 축약·검증된 요청 설정 | 다중 provider 필수; M3 |
| G09 / P2 프로필 갱신 | revision은 있으나 alias의 모델 교체·연결 삭제 시 예약/Ultra 역할 참조의 이관 흐름이 없음 | PROVIDER-008: metadata 변화의 stale 처리, 재진단, 영향 참조 표시·명시적 이관, 과거 snapshot 보존 | 다중 provider 필수; M3, M5/M6 소비자 통합 |
| G10 / P2 미저장 편집 복구 | UI-005가 dirty buffer 충돌을 언급하지만 3-way 선택 적용·undo·crash 후 복구 절차가 없음 | UI-006: base/buffer/disk 비교, stale hunk 거절, 사용자/agent undo 출처, 복구 buffer로 최신 disk를 덮어쓰지 않음 | 네이티브 강화; M2 기반, M6 UI |
| G11 / P2 plugin 의존성 | bundle 설치/lock은 있으나 plugin 간 전이 dependency·버전 충돌·dependent disable/remove가 없음 | EXT-001: graph resolve/lock, staging 업데이트, 충돌·cycle·공유 의존성·이전 정상 graph 보존 | parity; M4/X6 |
| G12 / P2 MCP server 모드 | MCP client와 기존 서버 설치·설정은 있으나 Lathe의 기존 도구를 다른 client에 제공하는 모드가 없음 | MCP-010: 로컬 stdio→같은 broker/journal, tool subset·무인 승인 오류·재귀/취소 검사 | parity, 정책 차이는 N; M4/X4 |
| G13 / P3 음성 입력 | VoiceOver는 있으나 녹음→전사→draft 편집 흐름이 없음 | UI-007: 전사 backend 분리, 마이크 거부/취소/실패·기존 draft 보존·명시적 전송 | parity, 전사 서비스는 별도; M6 |

각 표의 짧은 ID는 `LAT-` 접두사를 사용한다. 새 E2E-22~29는 실행 환경, 디버거,
여러 root, editor 충돌, provider 경계, MCP 양방향·이미지, plugin graph, 음성 입력을 검증한다.

## 3. 상세 설계에 반영한 경계

- [실행·디버깅](execution-and-debugging.md): 실행 시점 환경 snapshot, fresh worktree 초기화,
  test/build artifact, debug control owner, stop generation, expression 효과, 외부 attach의 detach 기본값.
- [프로바이더](providers.md): 정상 응답과 작업 완료의 분리, hosted continuation, 실제 context,
  metadata 변경·검증 무효화·참조 이관, 도구 이미지의 provider별 전달.
- [도구·MCP](tools-and-mcp-setup.md): 비텍스트 결과 보존·이미지 왕복과 외부 client용 server 모드.
- [확장](extensions.md): launch/include 입력 호환과 plugin 간 dependency graph의 전체 수명.
- [아키텍처](architecture.md): root별 identity/lease, 실행/디버깅 상태 owner, buffer revision/복구,
  composite orchestration이 child를 기다리며 전체 write lease를 점유하지 않는 규칙.

교차 검토에서 DAP 시작 중 역방향 요청의 lease 교착, fork 세션 간 root membership 공유,
MCP server 연결의 grant 결합 주체도 확인했다. 각각 lease 없는 시작 handshake, 독립 SessionWorkspaceBinding,
engine 발급 ingress identity로 보완하고 수용 시나리오에 넣었다. 구현에서 해결되었다는 의미는 아니다.

## 4. 이미 정의된 항목과 이번에 확대하지 않은 범위

터미널·파일 편집·실행·로그 분석 자체는 빠진 기능이 아니다. PTY, 중단/취소, background process,
checkpoint/rewind, Git/worktree, LSP, 사용자 질문, plan, 권한, skills/hooks/plugins,
검색·기존 MCP 설치·설정, Ultra·예약·원격 실행은 기존 요구사항에 이미 있다. 실제로 동작하는지는 구현 뒤 검증해야 한다.

추가로 앱이 vLLM/Ollama를 직접 설치하거나 모델 파일을 내려받는 기능은 이번 필수 누락으로 판정하지 않았다.
사용자가 운영하는 localhost/LAN/외부 서버에 연결하는 원래 범위는 유지하며 모델 관리자 제품까지 자동 확대하지 않는다.
container/devcontainer executor는 일반 shell 명령 지원과 별개인 선택적 후속 backend다.
voice dictation은 별도 전사 backend가 필요하지만 특정 상용 전사 서비스나 로컬 전사 엔진은 아직 선정하지 않았다.
MCP audio/video의 모델 이해, 모든 언어의 DAP, SSH/simulator 디버깅은 capability별 후속 검증이며
이미지 왕복·local LLDB 성공만으로 전체 지원을 선언하지 않는다.

## 5. 공식 대조 근거

확인일의 공개 문서를 사용했다. 기능 가용성은 모델·계정·실행 표면에 따라 다르므로 특정 서비스 entitlement를
일반 모델 key로 사용할 수 있다고 가정하지 않는다. [Claude 기능 가용성](https://code.claude.com/docs/en/feature-availability)

- G01/G02: [Desktop preview 설정](https://code.claude.com/docs/en/desktop#configure-preview-servers),
  [worktree 환경 준비](https://code.claude.com/docs/en/worktrees#set-up-the-worktree-environment).
- G03/G04: [Apple scheme](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project),
  [result bundle](https://developer.apple.com/videos/play/wwdc2019/413/),
  [LLDB-DAP](https://lldb.llvm.org/use/lldbdap.html), [DAP](https://microsoft.github.io/debug-adapter-protocol/overview).
- G05: [추가 작업 디렉터리](https://code.claude.com/docs/en/permissions#working-directories).
- G06/G12: [MCP 이미지 결과](https://code.claude.com/docs/en/mcp#images-in-tool-results),
  [Claude Code MCP server](https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server).
- G07/G08/G09: [Claude 종료 이유](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons),
  [Gemini 응답·modelVersion](https://ai.google.dev/api/generate-content#GenerateContentResponse),
  [Ollama context](https://docs.ollama.com/faq#how-can-i-specify-the-context-window-size).
- G11/G13: [plugin 의존성](https://code.claude.com/docs/en/plugins/dependencies),
  [음성 dictation](https://code.claude.com/docs/en/voice-dictation).

G10의 buffer 충돌·복구 방식은 Lathe의 설계 판단이다. 공식 Claude 기능과 동일하다는 근거로 사용하지 않는다.
