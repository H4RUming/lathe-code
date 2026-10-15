# 기능 요구사항과 Claude Code 대응 범위

작성·공식 문서 확인: **2026-10-15**. 상태: 설계이며 구현 완료를 뜻하지 않는다.

이 문서는 Lathe가 제공해야 하는 사용자 동작과 검증 가능한 완료 조건을 정의한다. 구현 구조는 [architecture.md](architecture.md), 확장 체계는 [extensions.md](extensions.md), 구현 순서는 [roadmap.md](roadmap.md)를 따른다. 요구사항 ID는 테스트·이슈·커밋에서 추적할 수 있도록 유지한다.

## 1. 최종 목표와 대응 수준

최종 목표는 Claude Code를 사용하는 주요 코딩 작업을 **하나의 Swift 기반 macOS 네이티브 앱에서 여러 모델 프로바이더로 수행하는 것**이다. 별도 상주 engine·시스템 CLI·로그인 agent를 설치하지 않는다. CLI와 독립 engine은 명시적인 개발·검증 빌드에서만 쓰며 일반 배포는 앱 하나다. 초기 수직 구현은 첫 검증 지점이며 최종 기능 범위를 축소하는 기준이 아니다. 파일 도구 몇 개와 채팅을 연결한 상태를 동등 기능 완성으로 부르지 않는다.

비교 기준은 위 확인일에 접근 가능한 Claude Code 공식 문서의 사용자 동작이다. 이후 추가된 기능은 기준일·출처·추가 요구사항을 기록하고 비교표를 갱신한다. Claude Code 내부 구현·계정 entitlement·전용 클라우드 서비스를 복제한다는 뜻은 아니다. 모델의 추론 품질, 특정 문제의 정답, 응답 문구, latency까지 같다고 보장하지 않는다.

| 분류 | 의미 | 완료 판정 |
| --- | --- | --- |
| **L: 로컬 필수** | Lathe가 자체 제공하는 작업 흐름. 탐색·수정·명령·계획·권한·세션·기억·작업 등 | 지원 모델을 붙였을 때 동일 목적의 작업을 끝낼 수 있고, 실패·취소·복구까지 시험함 |
| **P: 프로바이더 조건부** | 이미지 이해, reasoning 표시, structured output, context 한도, hosted search 등 모델/API에 종속 | 지원 여부를 확인하고 지원 조합에서 검증. 미지원 조합은 이유와 대안을 표시 |
| **I: 외부 연동** | GitHub, 검색 서비스, 브라우저, IDE, 원격 제어, hosted 실행 등 별도 계정·실행 환경 필요 | 연동 계약·권한·연결 상태·오류를 정의하고 실제 연결 환경에서 검증 |

L은 특정 회사 모델에만 붙는 기능으로 구현하지 않는다. P/I는 요청 범위에서 삭제하는 표시가 아니라, 동작에 필요한 조건을 구분하는 표시다. L과 P가 함께 적힌 항목은 로컬 기능을 구현하되 모델의 입력·출력 능력에 조건이 있다는 뜻이다.

각 항목의 **참고 동작**은 Claude Code 문서 확인 내용이고, **Lathe 요구사항**과 **수용 기준**은 이 앱의 설계 결정이다. UI나 저장 형식이 다른 경우에도 사용자가 달성하는 작업과 권한 경계를 기준으로 비교한다.

## 2. 공통 에이전트 실행

참고 동작: Claude Code는 컨텍스트 수집·실행·검증을 반복하고, 중간 중단과 방향 수정을 허용한다. 도구 결과가 다음 모델 요청의 근거가 된다. [공식 실행 구조](https://code.claude.com/docs/en/how-claude-code-works)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-CORE-001 / L** 목표 실행 루프 | 질문·버그 수정·리팩터링·테스트 추가·문서화 요청을 동일한 세션 엔진으로 처리한다. 응답의 tool call을 검증하고 실행 결과를 반환하며 후속 판단을 계속한다. | 실패 테스트를 조사·수정·재실행하는 fixture에서 실제 명령 결과와 최종 보고가 일치한다. 결과가 없는데 검증 성공으로 기록하지 않는다. |
| **LAT-CORE-002 / L** 중단·취소 | 생성 중지, 도구 중지, 전체 실행 취소를 구분한다. 중지 이후 새로운 모델 요청·도구 실행을 시작하지 않고 진행 중 효과를 기록한다. | 스트림·명령·승인 대기 각각에서 중지할 수 있고, 미완성 tool call이 실행되지 않는다. 중지 전 적용한 파일은 변경 목록에 남는다. |
| **LAT-CORE-003 / L** 실행 중 지시 | 입력을 큐에 넣고 수정·삭제할 수 있다. 도구 경계에서 새 지시를 현재 작업의 수정으로 반영하며, 중단 후 보내기도 제공한다. | 장기 테스트 중 추가한 조건이 다음 편집 전에 전달된다. 입력의 접수·전달·취소 상태가 구분된다. |
| **LAT-CORE-004 / L** 질문 | 단일/복수 선택과 자유 입력을 지원한다. 질문의 목적·기본 가정·선택 영향을 보여주며 사용자가 답할 때까지 필요한 작업만 기다린다. | 질문과 실행 승인이 서로 다른 이벤트다. 질문 취소나 무응답을 파일 수정·외부 전송 승인으로 해석하지 않는다. |
| **LAT-CORE-005 / L** 실행 한도 | turn·세션·subagent별 도구 반복 수, 시간, 출력 크기, context, 병렬 실행 한도를 적용한다. 요금 추정이 가능한 연결은 비용 예산도 적용한다. | 무한 tool loop가 상한에서 멈추고, 이미 수행한 변경·남은 작업·중단 이유를 복원할 수 있다. 알려지지 않은 요금은 0원으로 표시하지 않는다. |
| **LAT-CORE-006 / L** 오류 복구 | 인증·rate limit·서버 장애·context 초과·protocol 오류·tool 실패를 구분한다. 안전한 모델 요청 retry와 쓰기/명령의 재실행 결정을 분리한다. | 스트림 단절 후 동일 패치·명령이 자동으로 두 번 실행되지 않는다. retry 횟수·대기·실패 원인이 UI와 CLI에 나타난다. |
| **LAT-CORE-007 / L** 검증과 인계 | 마지막 답변에 변경 요약, 실행한 검증, 실패·미실행 검증, 관련 파일, 남은 작업을 연결한다. 모델의 주장과 실행 증거를 별도 저장한다. | 사용자가 최종 답변에서 해당 diff와 검증 로그를 열 수 있다. 시작하지 않은 검증과 실패한 검증이 완료 표시되지 않는다. |
| **LAT-CORE-008 / L** side chat | 진행 중인 작업의 context snapshot으로 별도 질문을 한다. 기본은 읽기 전용이며 main run의 지시·대화·파일을 자동 변경하지 않는다. 답을 본 작업으로 전달하는 명시적 동작을 제공한다. | 긴 구현 중 설계 설명을 물어도 main run은 계속된다. side chat과 실행 중 지시의 대상이 UI에 구분되고, 명시적으로 전달한 내용만 main run에 새 입력으로 들어간다. |

참고 동작: Desktop의 side chat은 본 작업을 중단하지 않고 별도 질문을 처리하는 기능이다. Lathe에서는 side chat의 출처 snapshot과 보존 여부를 자체 세션 계약으로 정한다. [Desktop side chat](https://code.claude.com/docs/en/desktop)

## 3. 파일·검색·편집·실행 도구

참고 동작: Claude Code에는 파일 읽기·편집·쓰기, shell, 검색, notebook cell 편집, web fetch/search와 작업 도구가 있다. 실제 노출 도구는 플랫폼·모델·설정에 따라 달라질 수 있다. NotebookEdit는 cell 단위 동작이다. [공식 도구 목록](https://code.claude.com/docs/en/tools-reference)

### 파일과 패치

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-TOOL-001 / L** 프로젝트 탐색 | 디렉터리·glob·정규식 내용 검색, 파일 유형·경로 필터, ignore 적용, 결과 페이지를 제공한다. 검색 결과는 경로와 위치를 포함한다. | 큰 저장소에서 전체 내용을 모델에 보내지 않고 목표 심볼의 후보 파일을 찾는다. 결과 잘림·검색 제외 범위가 드러난다. |
| **LAT-TOOL-002 / L** 범위 읽기 | 텍스트 파일의 줄/범위 읽기와 변경 감지를 제공한다. 인코딩·binary·대용량을 구분하고 읽은 revision/hash를 기록한다. | 한글·CRLF·빈 파일·잘못된 인코딩에서 내용을 조용히 훼손하지 않는다. 오래된 읽기 결과로 편집하려 하면 재확인이 필요하다. |
| **LAT-TOOL-003 / L** 변경 작업 | 새 파일, 정확한 내용 치환, patch, rename/move, 삭제를 공통 변경 계획으로 표현한다. 적용 전 대상·diff·기존 내용 검증을 수행한다. | 같은 문자열이 여러 곳이면 불명확한 치환을 거절한다. 다중 파일 적용 중 실패한 위치와 성공한 변경을 구분해 복구할 수 있다. |
| **LAT-TOOL-004 / L** 경로와 동시 변경 | canonical path, workspace 경계, symlink/hard link, 권한, 대소문자 충돌을 검증한다. 외부 편집과 에이전트 편집을 덮어쓰지 않는다. | `../`, 링크 우회, 파일 교체, 적용 직전 revision 변경을 검사하고 허용되지 않은 대상에 쓰지 않는다. |
| **LAT-TOOL-005 / L** notebook | `.ipynb` cell ID를 기준으로 코드/markdown cell 삽입·수정·삭제와 cell diff를 제공한다. 관련 없는 metadata를 보존한다. 실행은 별도 kernel/명령 작업으로 기록한다. | cell 변경 후 notebook JSON을 다시 열 수 있고 다른 cell·metadata가 유지된다. cell source 변경만으로 실행 성공을 표시하지 않는다. |

### 명령과 터미널

각 tool 명령은 `executable + arguments + cwd + environment profile` 또는 명시적 shell script로 기록한다. 모델이 생성한 문자열을 인자형 실행 경로에서 다시 shell로 해석하지 않는다. GUI에서 시작한 앱의 PATH가 사용자의 개발 shell과 다를 수 있으므로 실행 환경을 설정 화면에서 확인할 수 있어야 한다.

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-TOOL-006 / L** 명령 실행 | zsh/bash 및 설치된 사용자 shell, cwd, 환경 profile, 제한 시간, stdout/stderr, exit status를 지원한다. 실행마다 적용된 설정을 남긴다. | 빌드 도구·패키지 매니저·테스트·Git을 실행한다. 명령별 환경 변수의 수명과 cwd 지속 여부가 명시되고 다음 실행에 우연히 누출되지 않는다. |
| **LAT-TOOL-007 / L** 대량 출력 | stdout/stderr를 동시에 소비하고 UI를 막지 않는다. 원본은 제한된 spool 파일로 저장하며 모델에는 요약·검색 가능한 참조를 전달한다. | 양쪽 pipe가 가득 차도 교착하지 않는다. 출력 제한 도달 시 잘림·종료 정책이 표시되고 로그를 부분 조회할 수 있다. |
| **LAT-TOOL-008 / L** 대화형 PTY | 비대화형 명령과 PTY 세션을 구분한다. 터미널 크기, ANSI, stdin, EOF, Ctrl-C, foreground/background, 재연결 가능한 화면을 제공한다. | 테스트 watch 또는 대화형 개발 명령을 사용자가 직접 제어할 수 있다. 입력이 필요한데 pipe로 시작한 명령은 무한 대기하지 않는다. |
| **LAT-TOOL-009 / L** 프로세스 수명 | 프로세스 그룹과 task ID를 연결하고 취소·timeout·앱 종료 정책을 정의한다. 종료 시 정상 종료 요청 뒤 강제 종료를 단계적으로 적용한다. | 자식·손자 프로세스가 남는 사례를 시험한다. 재시작 후 PID만으로 무관한 프로세스를 종료하지 않는다. |
| **LAT-TOOL-010 / L** 테스트·개발 서버 | 테스트 결과, build 진단, server URL/port와 준비 상태를 실행 task에 연결한다. 서버 실행과 페이지 열기를 분리한다. | server가 계속 실행되는 동안 대화와 다른 작업을 진행할 수 있다. 포트 충돌·준비 실패·종료가 task 상태에 반영된다. |

### 실행 환경·테스트·디버거

shell에서 명령을 실행하는 기능과 재사용할 실행 설정·구조화된 테스트 결과·디버거 제어를 구분한다.
[실행·디버깅 계약](execution-and-debugging.md)이 세부 동작을 정한다. LLDB/DAP 통합은 Lathe의 네이티브 강화 목표이며
Claude Code 자체에 동일한 디버거 UI가 있다고 주장하지 않는다.

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-EXEC-001 / L** 실행 profile | build/run/test/debug별 executable/args/cwd/env 참조·target/scheme/configuration/destination·준비 조건·출력 위치를 revision 있는 profile로 저장한다. `.claude/launch.json`의 지원 필드를 읽고 `.lathe`에 native override를 쓴다. | 같은 profile을 GUI/CLI/agent가 사용해 같은 실행을 재현한다. server ready와 process alive를 구분하고 미지원 import 필드를 진단한다. |
| **LAT-EXEC-002 / L** 환경 준비 | PATH·toolchain·SDK/runtime·package manager·lockfile을 진단하고 허용된 setup profile로 dependency/worktree 환경을 준비한다. `.worktreeinclude`의 선택 파일 전달도 source/target별로 검증한다. | fresh worktree에서 필요한 dependency/env가 준비되어 테스트가 실행된다. 실패·취소·재실행 상태를 구분하고 프로젝트를 열거나 파일을 발견했다는 이유만으로 설치 script를 실행하지 않는다. |
| **LAT-EXEC-003 / L** 검증 결과 모델 | test/build 결과를 case ID·실행 profile·소스 revision·환경·상태·duration·원본 artifact와 연결한다. 지원 adapter는 xcresult/JUnit 등 결과 형식을 읽는다. | 0 tests·skipped·cancelled·일부만 실행·기존 실패와 새 실패를 구분한다. exit 0 또는 이전 revision의 성공만으로 현재 수정 검증 완료를 표시하지 않는다. |
| **LAT-DEBUG-001 / L+I** 디버거 제어 | LLDB-DAP를 시작 adapter로 launch/attach, breakpoint·exception stop, continue/pause/step, threads/stack을 typed tool과 공통 UI/CLI에서 제어한다. | 실행 가능한 debug fixture에서 breakpoint 적중→step→실제 frame 확인→수정·재실행을 완료한다. adapter/toolchain별 미지원 capability를 표시한다. |
| **LAT-DEBUG-002 / L+I** 상태 검사 | stopped 상태의 scopes/variables/watch와 명시적 evaluate를 지원한다. session/stop generation으로 frame·변수 handle을 식별한다. | resume 뒤 낡은 handle을 거절하고 큰 변수는 페이지/한도로 처리한다. evaluate·조건식·formatter의 코드 실행 가능성을 effect로 취급해 Plan/권한을 우회하지 않는다. |
| **LAT-DEBUG-003 / L+I** 디버거 수명 | 디버거·debuggee 소유자, launch/attach, detach/terminate, timeout/cancel/adapter crash를 기록한다. | 자신이 launch한 프로세스 종료와 외부 attach 대상 detach를 구분한다. 재시작 후 PID만으로 자동 attach/종료하지 않고 debug stop을 agent 완료로 오인하지 않는다. |

### Web·이미지·문서 입력

참고 동작: Claude Code는 이미지 붙여넣기·파일 경로·drag and drop과 파일/디렉터리 참조를 지원한다. [공식 이미지·참조 흐름](https://code.claude.com/docs/en/common-workflows#work-with-images)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-TOOL-011 / L+I** URL 읽기 | 사용자가 지정하거나 검색으로 얻은 URL을 fetch하고 제목·본문·최종 URL·시각을 반환한다. HTML 본문 추출과 다운로드를 분리하고 인증·redirect 정책을 적용한다. | 문서 fetch 결과를 링크와 함께 인용할 수 있다. 로그인 벽·unsupported media·실패 응답을 실제 본문으로 오인하지 않는다. |
| **LAT-TOOL-012 / L+P+I** 웹 검색 | provider hosted search, 독립 검색 API, 자체 호스팅 검색, MCP 검색 adapter를 수용한다. 모델 연결과 별도로 backend·domain/기간 필터·결과 한도·출처를 설정한다. | local LLM에서도 검색→문서 읽기→출처 첨부가 된다. backend의 미지원 필터와 일부 실패를 표시하고 검색 연결이 없으면 검색한 척하지 않는다. |
| **LAT-TOOL-013 / L+P** 이미지 | clipboard·drag/drop·파일 선택으로 이미지를 추가하고 미리보기·제거·크기 변환 정보를 보여준다. vision 모델에만 이미지 데이터를 전달한다. | 지원 모델에서 screenshot 기반 수정 요청을 실행한다. 미지원 모델 전환 시 이미지를 조용히 버리거나 base64를 text로 보내지 않는다. |
| **LAT-TOOL-014 / L+P** 문서와 binary | PDF 페이지/텍스트, notebook, 일반 binary를 구분한다. 로컬 추출 결과와 모델이 실제 본 원본/이미지 범위를 명시한다. | 스캔 PDF에 텍스트가 없음을 감지한다. 일부 페이지만 처리했으면 전체 문서를 읽었다고 표시하지 않는다. |

Web 검색 서비스, PDF renderer, PTY emulator의 구체 라이브러리는 구현 결정으로 기록한다. OS 네이티브 UI 요구가 모든 parser·CLI 의존성을 Swift로 재작성해야 한다는 뜻은 아니다.

## 4. 계획·권한·실행 격리

참고 동작: 공식 권한 모드는 Manual/default, acceptEdits, plan, auto, dontAsk, bypassPermissions로 구분된다. Auto는 일상적인 승인 창을 없애는 단순 allow 모드가 아니라 별도 classifier 검토를 사용한다. [권한 규칙](https://code.claude.com/docs/en/permissions), [모드 설명](https://code.claude.com/docs/en/permission-modes)

Lathe는 아래 의미를 UI와 CLI에서 일관되게 구현한다. 명칭은 UI 번역에 따라 바뀔 수 있지만 내부 모드와 권한 결정을 안정적으로 기록한다.

| 모드 | Lathe 동작 |
| --- | --- |
| `manual` | 범위 내 읽기와 명시적 허용 규칙을 적용하고, 승인되지 않은 쓰기·명령·네트워크 효과는 요청한다. |
| `acceptEdits` | 허용 workspace의 구조화된 파일 변경을 자동 승인한다. 임의 shell·외부 효과 전체를 자동 승인하지 않는다. |
| `plan` | 소스 변경과 부작용 도구를 막고 탐색·질문·계획 revision을 허용한다. 계획은 앱 저장소에 저장한다. |
| `auto` | 명시적 deny와 격리 정책을 먼저 적용하고, 별도 평가기가 사용자 의도·인수·효과를 검사한다. 불확실하면 승인 대기로 간다. |
| `dontAsk` | UI를 띄우지 않는다. 기존 규칙으로 허용되지 않은 호출은 거부 결과를 모델/호출자에게 반환한다. |
| `bypass` | 사용자가 명시적으로 고른 세션에서 일상 tool 승인 창을 건너뛴다. OS 권한·실행 격리·실행 한도·강제 정책을 없애지 않는다. |

`acceptEdits`의 정확한 자동 허용 범위와 `bypass`의 강제 정책 유지 등은 Lathe 설계이며 Claude Code의 모든 세부 규칙을 그대로 모사한다는 뜻은 아니다. Auto 평가기의 공급자·비용·실패 정책이 구현되지 않았으면 해당 모드를 비활성으로 표시하고 완료로 주장하지 않는다.
Plan 진입은 세션 소유 writer/process의 중지·대기와 mutation hook/전처리 차단을 포함한다. 이 세션이 요청한 source 변경을 막는 계약이며 다른 editor나 세션까지 파일을 동결하는 보장은 아니다.

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-PERM-001 / L** 모드·규칙 | allow/ask/deny 규칙을 tool, 파일 범위, executable/arguments, network target에 적용한다. deny 우선, 출처·유효 범위·만료를 보여준다. | 모드 전환은 다음 실행 경계부터 적용된다. UI·CLI·subagent·background가 같은 정책 결정을 사용한다. |
| **LAT-PERM-002 / L** 승인 UI | 목적·정확한 대상·diff/명령·작업 경로·효과를 보여주고 한 번, 세션, 프로젝트 규칙의 범위를 구분한다. 승인/거절에 코멘트를 달 수 있다. | 승인 후 인수나 파일 revision이 바뀌면 기존 승인을 재사용하지 않는다. 승인 대기 중 취소·앱 재시작에도 자동 실행하지 않는다. |
| **LAT-PERM-003 / L** 계획 모드 | 탐색 결과, 목표, 변경 파일 후보, 단계, 검증 방식, 미해결 질문을 plan revision으로 저장한다. 검토·수정·선택 실행을 제공한다. | plan 실행 전에는 소스가 바뀌지 않는다. 사용자가 승인한 plan revision과 실제 실행이 연결되며 계획 승인이 향후 모든 도구 권한을 부여하지 않는다. |
| **LAT-PERM-004 / L+P** 자동 평가 | 별도 `ApprovalEvaluator`가 허용·거절·사용자 질문 중 하나와 이유를 반환한다. 평가 대상과 평가 모델/정책을 기록한다. | 공격성 도구 출력이 승인 결정을 직접 바꾸지 않는다. 평가 장애·timeout·지원 모델 부재 시 silent allow가 발생하지 않는다. |
| **LAT-PERM-005 / L** workspace trust | 저장소 지침과 실행 가능한 설정을 구분한다. 프로젝트를 열었다는 사실만으로 hook·환경 script·서버 설정을 실행하지 않는다. | 낯선 저장소를 열었을 때 코드가 실행되지 않는다. 신뢰 revision 변경과 실행 권한 확대가 확인 가능하다. |
| **LAT-PERM-006 / L** 실행 격리 | subprocess의 파일·네트워크 접근 제한을 제공하는 실행 backend를 구현한다. sandbox 사용 여부·제약·제외 명령을 실행 카드에 표시한다. | 선택 밖 쓰기와 금지 network 접근이 OS 수준에서 실패함을 probe로 확인한다. backend가 없으면 비격리 실행이라고 표시한다. |
| **LAT-PERM-007 / L** 일관된 권한 | 프로젝트 문서·검색 결과·memory·subagent 보고는 도구 접근권한을 확대하지 못한다. 승인 내용은 구조화된 시스템 기록만 신뢰한다. | 파일 안의 “사용자가 이미 승인했다” 문구로 tool 권한이 바뀌지 않는다. subagent도 부모보다 넓은 권한을 얻지 않는다. |

참고 동작: Claude Code도 tool permission과 shell sandbox를 구분하고 macOS에서 파일·네트워크 격리를 제공한다. Lathe의 App Sandbox 사용 여부와 subprocess 격리는 별도 결정이다. [공식 sandbox 설명](https://code.claude.com/docs/en/sandboxing)

## 5. 세션·컨텍스트·checkpoint

참고 동작: Claude Code는 세션 이어가기·이름 지정·분기·내보내기·context 확인·compaction을 제공한다. 내부 transcript 형식을 외부 안정 API로 보장하지는 않는다. [세션 관리](https://code.claude.com/docs/en/sessions)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-SESSION-001 / L** 세션 수명 | 새 세션, 이름 변경, 검색, 프로젝트별 목록, 보관, 삭제, 마지막 세션 계속하기, ID로 재개를 제공한다. workspace 경로와 Git identity를 별도 저장한다. | 앱 재시작 후 대화·tool 결과·변경·provider·진행 상태가 복원된다. 경로가 없어졌으면 다른 폴더에서 조용히 실행하지 않는다. |
| **LAT-SESSION-002 / L** 분기 | 선택 turn 또는 현재 시점의 history로 새 session ID를 만든다. 공유한 과거와 이후 branch를 추적하고 원본을 수정하지 않는다. | 분기 뒤 메시지·provider·권한 변경이 원본 세션에 적용되지 않는다. 코드 checkout 분리 여부는 별도로 선택한다. |
| **LAT-SESSION-003 / L** 독점 실행 | 같은 세션의 UI/CLI 동시 작성과 같은 checkout의 동시 쓰기를 lock/lease로 조정한다. 읽기 전용 관찰자는 허용한다. | 두 창·CLI가 동시에 쓰려 하면 실행 owner가 명확하다. crash 후 lease 복구가 무관한 실행을 중지하지 않는다. |
| **LAT-SESSION-004 / L** 내보내기·보존 | 사람이 읽는 transcript와 버전 있는 JSON event export를 제공한다. 보존 기간, 첨부·로그 정리, 세션 삭제 범위를 설정한다. | export에 메시지·도구·결과·시간·출처가 유지된다. Keychain 비밀·access token이 export에 포함되지 않는다. |
| **LAT-CTX-001 / L+P** context 검사 | 대화·지침·memory·tool schema·파일·출력·요약의 context 기여를 보여준다. 정확한 token 수와 추정을 구분한다. | 선택 모델의 한도가 변경되면 예산이 재계산된다. 줄인 context에서 빠진 범위를 사용자가 확인할 수 있다. |
| **LAT-CTX-002 / L** 자동·수동 요약 | 자동 임계점과 수동 focus 요약, 선택 이전/이후 구간 요약을 제공한다. 원본 transcript를 보존하고 요약 출처를 연결한다. | tool-call/결과/서명 묶음을 절단하지 않는다. 반복 요약이 context를 줄이지 못하면 무한 반복 대신 원인과 조치를 표시한다. |
| **LAT-CTX-003 / L+P** provider 변경 | 완료된 turn에서 provider/model을 바꿀 수 있다. 공통 context와 provider continuation을 분리하여 재사용 가능성은 adapter가 판정한다. | OpenAI→Gemini→local endpoint 전환 중 타 provider의 opaque signature를 보내지 않는다. 전환·요약으로 잃는 context를 기록한다. |
| **LAT-CTX-004 / L** context 참조 | `@파일`, `@폴더`, 줄 선택, 검색 결과, diff, command output을 첨부할 수 있다. 링크 참조와 실제 전송 내용을 구분한다. | 큰 파일을 붙였을 때 실제 포함 범위와 생략 이유가 나타난다. 외부에서 수정된 참조는 최신 읽기 여부가 표시된다. |
| **LAT-SESSION-005 / L** checkpoint | 직접 파일 도구의 변경 전 snapshot과 변경 후 hash를 turn·agent·workspace에 연결한다. 코드만, 대화만, 둘 다 되돌리기를 제공한다. | 코드 복원 전 영향 diff를 확인하고 현재 hash가 다르면 충돌을 알린다. 생성·삭제·rename도 복원 대상과 결과를 구분한다. |
| **LAT-SESSION-006 / L** 복원 한계 | shell, 외부 API, DB, 배포, 사용자의 외부 편집을 완전 rollback 가능하다고 표시하지 않는다. 추적된 child-agent 변경은 owner를 유지한다. | checkpoint 화면이 복원 가능/불가능/충돌 경로를 나누고, 부분 복원 결과를 보존한다. Git history를 reset해서 복원을 흉내 내지 않는다. |
| **LAT-SESSION-007 / L+I** 세션 간 메시지 | session ID·workspace·발신 actor·메시지 ID·시각·출처를 포함해 세션을 조회하고 메시지를 전달한다. 수신 정책은 허용·보류·거절이며 idle 알림 구독도 지원한다. 원격 전달은 별도 연결 권한을 요구한다. | 동일 이름의 세션을 ID로 구분한다. 재연결 시 메시지가 중복 실행되지 않고, 수신 문구를 인간 지시나 승인 기록으로 위장할 수 없다. 발신자의 거부된 작업을 다른 세션에서 우회하지 못한다. |
| **LAT-WORKSPACE-001 / L** 여러 작업 root | 한 세션에 여러 폴더/저장소를 추가·제거하고 primary root와 현재 cwd를 구분한다. root마다 Git identity·지침·read/write 범위·trust를 관리한다. | frontend/backend 두 저장소의 Git·diff·cwd를 구분한다. fork의 root 제거는 원본에 적용되지 않으며 전역 권한 철회는 모든 세션에 적용한다. 파일 접근 추가가 hook/MCP 설정 활성화를 자동 허용하지 않는다. |

참고 동작: Claude Code의 rewind는 코드·대화 복원을 구분하고, shell이 만든 파일 변경이나 외부 시스템 효과는 checkpoint로 되돌리지 못한다. Lathe는 child-agent가 공통 파일 도구로 수행한 변경까지 owner와 함께 journal에 남기는 것을 자체 설계 목표로 한다. [checkpoint 범위](https://code.claude.com/docs/en/checkpointing)

참고 동작: 세션 간 메시지는 다른 세션에 텍스트를 보내며, 활성 작업에서는 tool 경계에서 수신하고 idle 세션에서는 새 turn을 시작할 수 있다. 수신 세션의 권한은 유지된다. Lathe의 송신·수신 정책은 사용자 설정으로 명시하며 단순 세션 열람이 송신 허용을 뜻하지 않는다. [세션 간 메시지](https://code.claude.com/docs/en/cross-session-messaging)

## 6. 프로젝트 지침과 기억

참고 동작: Claude Code에는 사용자가 작성하는 CLAUDE.md/AGENTS.md 계열 지침과 세션을 넘어 축적하는 auto memory가 있고, 둘 다 강제 접근정책 자체는 아니다. [공식 memory 문서](https://code.claude.com/docs/en/memory)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-MEM-001 / L** 지침 로딩 | 사용자 지침, repository 지침, 경로별 규칙, 현재 대화 지시의 출처·적용 경로·revision을 추적한다. AGENTS.md와 CLAUDE.md 호환 입력을 지원한다. | 중첩 디렉터리에 적용된 지침을 UI에서 열 수 있다. 같은 파일의 중복 loading과 순환 import를 차단하고 충돌을 진단한다. |
| **LAT-MEM-002 / L** 호환성 profile | 지원하는 파일·frontmatter·import 규칙을 명시한다. 지원하지 않는 Claude 설정은 무시 사실을 보여주고 Lathe policy와 혼합하지 않는다. | 두 지침 파일이 공존할 때 적용 방식이 결정적이다. migration preview 없이 원래 지침을 덮어쓰지 않는다. |
| **LAT-MEM-003 / L** 기억 저장 | 사용자 정정·선호·장기 프로젝트 정보의 기억 제안/자동 저장 모드를 제공한다. scope, 출처, 수정 시각, 확인 상태와 수정·삭제·끄기를 지원한다. | “이 프로젝트는 pnpm 사용” 기억이 다음 세션에 전달된다. 삭제/비활성화한 기억은 새 요청에 포함되지 않는다. |
| **LAT-MEM-004 / L** 기억 분리 | repository/worktree 공통 기억, 사용자 공통 기억, agent 전용 기억을 분리한다. topic별 상세 내용은 필요할 때 로드한다. | unrelated repository의 정보를 기본으로 끌어오지 않는다. 저장소 경로 이동 후 identity를 확인하고 의도한 memory를 연결한다. |
| **LAT-MEM-005 / L** 초기화·진단 | 프로젝트 분석 후 지침 초안을 만들고 적용 전 diff를 보여준다. 어떤 지침·memory가 왜 로드되었는지 확인한다. | 기존 파일이 있으면 병합 제안으로 보여준다. `doctor`에서 깨진 참조·과도한 context·잘못된 scope를 찾는다. |

명령·skill 정의, hook 설정, MCP와 LSP 설정의 상세 호환성은 [extensions.md](extensions.md)에서 별도 정의한다.

## 7. 작업 목록·백그라운드·다중 에이전트

참고 동작: Claude Code의 subagent는 자체 context에서 작업하고 결과를 보고하며 foreground/background와 역할별 도구 제한을 지원한다. 별도의 agent teams는 협업·공유 작업 기능을 제공하고 공식 문서상 실험적 제약이 있다. [subagents](https://code.claude.com/docs/en/sub-agents), [agent teams](https://code.claude.com/docs/en/agent-teams)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-TASK-001 / L** 작업 목록 | 목표를 task로 나누고 상태·담당 agent·의존성·산출물·완료 근거를 저장한다. 모델과 사용자가 모두 갱신할 수 있다. | 의존성 cycle을 거절한다. task 완료와 실행 종료를 구분하고, 사용자가 잘못된 상태를 수정할 수 있다. |
| **LAT-TASK-002 / L** background task | command·agent·watch 작업의 ID, owner, 상태, output cursor, 알림, 취소를 공통 UI로 제공한다. 대화 완료와 background 완료를 구분한다. | 긴 테스트를 background로 옮긴 뒤 다른 작업을 진행한다. 실제 완료 이벤트가 오기 전 성공 결과를 보고하지 않는다. |
| **LAT-TASK-003 / L** subagent | 역할·목표·tool subset·provider/model·context 전달 방식·예산·workspace를 명시하여 생성한다. fresh context와 conversation fork를 구분한다. | 부모 제한을 넘는 tool 요청이 차단된다. 결과에 근거·수정 파일·실패가 포함되고 부모가 transcript를 열 수 있다. |
| **LAT-TASK-004 / L** agent 수명 | 대기·진행·질문·승인·실패·중단·완료, 메시지 전송, 재개, 결과 handoff를 지원한다. 부모 취소가 child에 미치는 정책을 명시한다. | 죽은 child에게 메시지를 전송하면 재개/실패가 구분된다. 승인 요청에는 실제 요청 agent와 workspace가 표시된다. |
| **LAT-TASK-005 / L** 팀 협업 | coordinator와 peer agent, 공유 task board, 주소 지정 메시지, 파일 소유 범위와 통합 검토를 제공한다. | 두 agent가 독립 worktree에서 변경하고 coordinator가 diff·테스트 결과를 검토해 통합한다. 메시지가 사용자 승인으로 승격되지 않는다. |
| **LAT-TASK-006 / L** 관찰·주기 작업 | log tail·파일 변화·명령 상태 관찰과 세션 단위 일회/반복 prompt를 제공한다. 조건·주기·종료·취소·중복 실행 방지를 저장한다. | 상태가 그대로면 모델을 무한 호출하지 않는다. 사용자 취소 후 다음 예약이 실행되지 않는다. 잠자기·앱 종료·재개 시 missed-run 정책이 명시된다. |
| **LAT-TASK-007 / L** 앱 작업 수명 | 진행 중 작업이나 미전송 입력이 있을 때 마지막 작업 창 닫기·종료에서 중단 후 종료/백그라운드 유지/취소를 선택한다. 미완료 작업이 없으면 바로 종료한다. runtime과 작업의 owner는 앱 프로세스다. | 앱 종료 뒤 독립 engine·로그인 agent가 남지 않는다. 중단은 runner 정리까지 기다리고, 재시작은 불명확한 비멱등 작업을 자동 반복하지 않는다. |
| **LAT-TASK-008 / L+P** 목표 반복 실행 | 완료 조건·증거·예산·중단 조건을 저장하고 turn 종료마다 별도 평가로 달성·계속·차단을 판정한다. 사용자 중지·목표 변경·진행 없음·회복 불가능한 오류를 처리한다. 평가기의 provider/model을 선택하고 비용에 합산한다. | 작업 모델의 완료 선언만으로 성공하지 않는다. 평가 결과와 근거가 기록되고 계속 판정이어도 시간·turn·비용 상한을 넘지 않는다. 목표 설정이 tool 권한을 변경하지 않는다. |
| **LAT-TASK-009 / L** 지속 로컬 예약 | 세션 밖에서 예약 이름·prompt revision·workspace/ref·모델·권한 profile·시간대·일정·실행 이력을 저장한다. 새 run/session, 지금 실행, 수정, 일시 정지, 삭제를 제공한다. | 재시작 후 일정이 남는다. DST·잠자기·오프라인·중복 due 이벤트를 시험하며 catch-up/skip, 동시 실행 금지, 실패 재시도 정책대로 한 번만 실행한다. 기존 checkout과 매 실행 worktree를 구분한다. |
| **LAT-TASK-010 / L** script workflow | 검토 가능한 script가 agent 실행·순서·조건 분기·반복·fan-out/fan-in·결과 취합을 정의한다. script revision, 입력 schema, phase, agent 결과, 재사용 명령, 중지·재개를 지원한다. | 다중 파일 migration을 병렬 실행하고 검증 phase를 거쳐 요약한다. 완료 step은 재개 시 재실행하지 않고 효과가 불명확한 step은 확인을 요구한다. script 자체에는 임의 파일·shell 접근을 주지 않고 agent tool broker를 거친다. |

참고 동작: Claude Code는 세션 내 예약 prompt, turn 종료 뒤 목표 평가, Desktop의 지속 로컬 예약, cloud routine을 구분한다. Desktop 로컬 예약은 일정이 재시작을 넘어 보존되지만 실행에는 앱과 깨어 있는 컴퓨터가 필요하다. Lathe는 앱이 살아 있는 동안만 로컬 예약을 실행한다. 앱 밖 background service나 로그인 agent를 설치하지 않으며 컴퓨터가 꺼진 상태의 실행을 보장하지 않는다. [세션 예약](https://code.claude.com/docs/en/scheduled-tasks), [goal](https://code.claude.com/docs/en/goal), [Desktop 예약](https://code.claude.com/docs/en/desktop-scheduled-tasks)

| 실행 방식 | 다음 작업을 시작하는 조건 | 보존 단위 | Lathe 구현 경계 |
| --- | --- | --- | --- |
| session loop/watch | 시간 경과 또는 관찰 상태 변화 | 기존 session과 task | LAT-TASK-006; 실행 중인 Lathe 앱/runner 필요 |
| goal | turn 종료 후 완료 조건 미달 | session goal revision과 평가 이력 | LAT-TASK-008; 예산·권한 정책 유지 |
| 로컬 예약 | 저장된 일정의 due 시점 | session과 독립적인 schedule | LAT-TASK-009; Lathe 앱과 Mac이 실행 중이어야 함 |
| script workflow | script의 dependency·분기 조건 | workflow run·step journal | LAT-TASK-010; scheduler가 실행 순서를 결정 |
| hosted routine | 원격 일정·API·외부 이벤트 | 원격 routine과 run | LAT-INTEGRATION-007; 별도 executor/서비스 필요 |

참고 동작: 공식 dynamic workflow는 script가 다수 subagent의 실행 순서와 중간 결과를 관리하고, 저장·재사용·background 진행·재개를 제공한다. agent teams의 실험적 상태를 workflow 전체에 적용하지 않는다. Lathe는 Swift 엔진 안에서 실행 계약을 정의하고 script 포맷·격리 runtime을 별도 결정한다. [dynamic workflows](https://code.claude.com/docs/en/workflows)

## 8. Git와 worktree

참고 동작: Claude Code는 worktree를 통한 checkout 분리와 세션 재개를 제공하고 정리할 때 변경·untracked·commit 상태를 검사한다. [공식 worktree 흐름](https://code.claude.com/docs/en/worktrees)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-GIT-001 / L** 변경 검토 | status, staged/unstaged diff, branch/base 비교, history, 사용자 기존 변경과 에이전트 변경의 출처를 보여준다. | dirty repo를 열어도 기존 변경을 삭제하지 않는다. mixed hunk는 불확실한 귀속으로 표시하고 사용자 수정으로부터 분리했다고 과장하지 않는다. |
| **LAT-GIT-002 / L** Git 동작 | 사용자가 요청한 stage/unstage/commit/branch/merge/rebase를 agent와 UI에서 실행한다. 대상 파일·현재 HEAD·계획을 기록한다. | 허용된 파일만 commit하고 변경 밖 파일을 stage하지 않는다. 충돌은 별도 상태이며 강제 reset으로 자동 해결하지 않는다. |
| **LAT-GIT-003 / L** worktree 수명 | 기준 ref, 새 branch, 경로, checkout identity, owner, 실행 lock을 기록한다. 생성·재사용·연결·보관·정리를 제공한다. | 동시에 두 writer가 같은 checkout을 점유하지 않는다. dirty/untracked/unpushed·submodule 상태를 확인하지 못하면 정리를 완료로 표시하지 않는다. |
| **LAT-GIT-004 / L** 변경 통합 | worktree diff·commit을 원본/대상 branch로 적용할 수 있게 하며 통합 전 비교·충돌·검증 단계를 제공한다. | agent 결과를 cherry-pick/merge/patch 중 선택한 방식으로 적용한다. 다른 agent의 미완료 변경을 조용히 포함하지 않는다. |
| **LAT-GIT-005 / I** GitHub 흐름 | 인증된 GitHub 연결 또는 `gh` adapter로 issue/PR 조회, 요청한 push·PR 생성·검토·수정을 연결한다. | local commit과 원격 push 성공이 따로 기록된다. remote 인증 실패 시 변경과 commit은 보존되고 성공 URL을 만들지 않는다. |
| **LAT-GIT-006 / L+I** PR·CI 관찰 | PR head·checks·review·merge 상태를 task로 관찰하고 변경 시 알린다. 실패 수정·review 응답·재검증·auto-merge는 사용자가 선택한 각각의 정책으로 처리한다. | 같은 실패를 반복 보고하지 않는다. PR head가 바뀌면 오래된 CI 성공으로 merge하지 않고 취소·rate limit·인증 만료를 상태로 남긴다. watch를 켰다는 이유만으로 push나 merge하지 않는다. |
| **LAT-GIT-007 / L** 검토 코멘트 | 파일·diff line·revision에 코멘트를 달고 선택 코멘트를 새 수정 요청으로 묶는다. 설명 요청과 코드 수정 요청을 구분한다. | 편집 뒤 line이 이동하면 기존 코멘트가 가리키는 revision을 유지한다. 사용자가 고른 코멘트만 다음 agent 입력으로 전달된다. |

참고 동작: Desktop은 diff 검토 코멘트와 PR 상태 관찰을 작업 화면에 연결한다. Lathe의 push·merge·자동 수정 권한은 위 요구사항처럼 분리한다. [Desktop 검토·PR 흐름](https://code.claude.com/docs/en/desktop)

Lathe 개발 저장소에서 모든 변경을 커밋하는 팀의 개발 규칙과, 완성 앱이 사용자의 저장소를 언제 commit/push하는지는 별개다. 앱은 명시적 요청 또는 사용자가 저장한 프로젝트 자동화 정책에 따라 Git 변경을 수행한다.

## 9. 개발 client·headless 검증·자동화

참고 동작: Claude Code는 비대화형 실행, stdin, text/JSON/stream-json 출력, resume, tool 제한, schema 출력 등을 제공한다. [headless 실행](https://code.claude.com/docs/en/headless), [CLI reference](https://code.claude.com/docs/en/cli-reference)

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-CLI-001 / L** 같은 앱 runtime | 선택적으로 빌드한 개발 `lathe` client가 local IPC로 실행 중인 앱의 provider·context·tool·permission·session 동작을 사용한다. 배포 앱과 별도로 설치하지 않는다. | 앱이 없으면 기본 client는 연결 오류로 끝나며 daemon을 만들지 않는다. 명시적인 개발 engine/데이터 root를 지정한 CI harness만 독립 실행할 수 있다. 두 client가 같은 run을 중복 시작하지 않는다. |
| **LAT-CLI-002 / L** 입출력 계약 | prompt 인자/stdin, text, 최종 JSON, 버전 있는 NDJSON event stream을 제공한다. stdout 데이터와 stderr 진단을 분리한다. | stream consumer가 모든 이벤트를 JSON으로 parse할 수 있다. 종료 이벤트는 성공·실패·취소·승인 부재를 구분한다. |
| **LAT-CLI-003 / L** 무인 권한 | 사람이 없는 실행에서는 규칙으로 해결되지 않은 승인을 거절하거나 `needsApproval`로 종료한다. 한도·tool subset·bare profile을 지원한다. | CI가 승인창을 기다리며 영구 대기하지 않는다. headless 전환만으로 bypass 권한이 켜지지 않는다. |
| **LAT-CLI-004 / L+P** 구조화 결과 | 최종 결과에 JSON Schema를 지정하고 검증한다. provider native structured output과 로컬 검증/제한된 repair를 구분한다. | schema 오류는 명확한 실패로 끝나며 무제한 repair하지 않는다. tool workflow와 최종 JSON 결과를 혼합하지 않는다. |
| **LAT-CLI-005 / L** 재개·관찰 | session ID resume/fork, 실행 목록·상태·event cursor 조회, stop, SIGINT/SIGTERM을 지원한다. | 중지 시 subprocess cleanup과 저장을 시험한다. 관찰 연결이 끊겨도 실행 owner의 정책대로 동작한다. |
| **LAT-CLI-006 / I** CI 연동 | GitHub Actions에서 명시적인 개발 빌드/harness로 client를 호출하고 결과·diff·log를 남긴다. 일반 배포 artifact에는 앱만 담는다. | macOS runner의 mock provider 실행을 재현한다. 실제 API key는 fixture·출력·저장소에 넣지 않는다. |

이 절의 CLI 요구사항 ID는 개발·자동화 검증 계약으로 보존하며 별도 제품 설치를 요구하지 않는다. 제안 명령 표면은 `lathe run`, `lathe sessions`, `lathe resume`, `lathe fork`, `lathe tasks`, `lathe stop`, `lathe doctor`다. 정확한 flags와 event schema는 구현 전에 별도 계약으로 고정한다. Claude CLI와 모든 flag 이름이 동일하다고 주장하지 않는다.

## 10. 네이티브 앱과 프로바이더 경험

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-UI-001 / L** 작업 화면 | 프로젝트·세션 sidebar, 대화·tool 카드, plan/tasks, 파일/diff inspector, log/terminal panel을 제공한다. | 키보드로 프로젝트 열기→요청→승인→diff→로그 확인을 완료한다. 긴 transcript·출력에서도 입력과 취소가 반응한다. |
| **LAT-UI-002 / L** command palette | 세션·context·모델·권한·plan·memory·tasks·checkpoint·doctor·extension 동작을 검색한다. slash 입력을 같은 action으로 연결한다. | UI와 slash 실행이 같은 결과를 내고 현재 상태에서 불가능한 동작의 이유를 표시한다. |
| **LAT-UI-003 / L** 알림·접근성 | 완료·실패·승인 필요·사용자 질문의 알림 설정, VoiceOver, Dynamic Type/가독성, 접근 가능한 diff·상태 표현을 제공한다. | 색상만으로 상태를 구분하지 않고, 사용자가 보고 있는 세션에 알림을 중복 발송하지 않는다. |
| **LAT-UI-004 / L+I** 개발 미리보기 | 개발 서버 task와 앱 내 browser preview를 연결한다. URL·port·준비 상태·reload·console·screenshot·DOM 확인·사용자 조작·요소 지정 피드백을 제공한다. browser 자동 조작은 동일한 권한 경계를 사용한다. | UI 변경 후 실제 preview에서 click·입력·시각 확인을 수행한다. 서버 종료·원격 port tunnel·페이지 오류를 구분하고, preview cookie 저장소를 명시한다. |
| **LAT-UI-005 / L** 파일 editor | 파일 tree와 탭, syntax highlight, 검색, 줄 이동, 저장, 외부 editor 열기, 수정 충돌 처리를 네이티브 화면으로 제공한다. | 사용자가 수정 중인 buffer를 agent가 덮어쓰지 않는다. 저장되지 않은 buffer와 disk revision 차이가 표시되고 어느 내용을 모델이 읽었는지 확인할 수 있다. |
| **LAT-UI-006 / L** 편집 복구·적용 | base/buffer/disk revision과 agent patch를 비교하고 충돌 없는 hunk 적용·충돌 해결·undo·미저장 buffer 복구를 제공한다. | 외부 편집과 agent patch가 겹치면 선택 전 덮어쓰지 않는다. crash 후 복구 buffer를 disk 최신값에 대조하고, 적용한 patch만 새 revision에서 검증한다. |
| **LAT-UI-007 / L+I** 음성 입력 | 녹음 시작/중지/취소, 전사 중/완료 상태, 기존 입력과 병합·편집·전송을 제공한다. 전사 backend·처리 위치·마이크 권한을 모델 추론 연결과 분리한다. | 마이크 거부·전사 실패·취소를 처리하고 전사만으로 메시지를 자동 전송하거나 도구 승인을 발급하지 않는다. VoiceOver와 별도 기능으로 검증한다. |
| **LAT-PROVIDER-001 / L** 필수 연결 | OpenAI, Google AI Studio, standard Vertex, Anthropic Claude, vLLM, Ollama, 기타 API 호환 서버를 설정·진단·저장한다. | 각각 모델 응답뿐 아니라 tool 왕복·파일 수정·검증 흐름을 수행한다. 하나의 provider 성공만으로 전체 지원 완료로 표시하지 않는다. |
| **LAT-PROVIDER-002 / L** 서버 위치 | localhost·LAN·외부 HTTPS·proxy prefix·선택 인증을 동일한 연결 모델로 지원한다. | 원격 vLLM/Ollama에서 인증·streaming·timeout·prefix를 실제 검증한다. 원격 추론 연결을 원격 shell로 오인하지 않는다. |
| **LAT-PROVIDER-003 / L+P** capability | model/connection revision별 지원·검증·미지원 상태와 사용량·latency·옵션을 보여준다. | reasoning/vision/tools 옵션이 무조건 모든 모델에 전송되지 않는다. 모델 목록 성공만으로 agent tool 지원을 보장하지 않는다. |
| **LAT-PROVIDER-004 / L** 인증 | API key는 Keychain, Vertex는 외부 ADC login 후 gcloud helper, custom header는 연결 scope로 처리한다. | 토큰 갱신·권한 부족·gcloud 없음·quota 설정 오류가 구분된다. redirect로 다른 origin에 인증을 넘기지 않는다. |
| **LAT-PROVIDER-005 / L+P** 진단과 비용 | 요청/응답 ID, 실제 입력/output token, 추정치, cache/추론 usage 등 provider가 제공한 값을 구분해 표시한다. | local endpoint가 usage를 생략하면 “알 수 없음”으로 표시한다. 코드·비밀 원문 없이 연결 진단을 export할 수 있다. |
| **LAT-PROVIDER-006 / L+P** 응답 종료 의미 | final/client tool/server continuation/blocked/truncated/empty 오류를 구분하고 provider state와 연결한다. 정상 HTTP와 작업 완료를 분리한다. | pause_turn·candidate 없음·refusal·미완료 hosted tool에서 빈 성공이나 로컬 도구 중복 실행이 없다. continuation도 취소·steering·예산·반복 한도를 따른다. |
| **LAT-PROVIDER-007 / L+P** 실제 context | 모델 최대 길이·서버 설정 길이·요청 유효 길이를 따로 저장하고 tokenizer/추정치·출력 예약과 함께 사용한다. | 앱 32k/서버 4k 불일치를 드러내며 축약·요청 옵션·설정 안내 중 검증된 방법을 사용한다. 원격 서버의 전역 설정을 임의 변경하지 않는다. |
| **LAT-PROVIDER-008 / L** 연결 갱신 | model alias/metadata·endpoint·credential revision 변경 때 관련 검증을 stale로 만들고 의존 세션·Ultra 역할·예약을 진단한다. | 삭제 전에 참조를 표시하고 명시적 이관 또는 비활성화를 제공한다. 과거 snapshot은 유지하며 같은 이름의 다른 모델로 조용히 대체하지 않는다. 실제 backend identity를 확인 못 하면 그 한계를 표시한다. |

참고 동작: Desktop은 editor·terminal·preview 등 작업 pane을 제공하며 개발 서버의 실제 화면을 작업에 연결한다. 세부 기능 제공 여부는 실행 interface·provider·모델·계정 조건에 따라 다르므로 Lathe도 기능별 검증 상태를 표시한다. [Desktop 작업 화면](https://code.claude.com/docs/en/desktop), [공식 feature availability](https://code.claude.com/docs/en/feature-availability)

### 추론 단계와 Ultra

사용자 추가 요구이며 [추론·Ultra 계약](reasoning-and-ultra.md)이 옵션 매핑과 실행 구조를 정의한다.
추론 모드, agent 구성, 권한 모드는 독립적이다. Off에서도 일반 코딩 loop·검색·MCP는 사용할 수 있다.

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-REASON-001 / L+P** 제공자 고유 제어 | OpenAI·Google AI Studio/Vertex·Claude의 모델/API별 effort·level·budget·mode 등 실제 옵션을 노출한다. | 지원 값·조합만 전송한다. 동일 서비스의 모든 모델에 같은 Off나 기본값을 가정하지 않는다. |
| **LAT-REASON-002 / L+P** Off/On | 로컬·개인 서버의 추론 생성 제어를 Off/On으로 선택한다. 서버/template 설정과 근거를 보관한다. | hybrid·always-on·non-reasoning·unknown 모델을 구분한다. 출력 숨김, parser 설정, prompt만으로 Off 지원을 표시하지 않는다. |
| **LAT-REASON-003 / L+P** Ultra 실행 | 추론 활성 coordinator·조사·구현·검토·검증 agent가 역할과 독립 context를 갖고 하나의 목표를 수행한다. | 실제 child run과 결과 인계가 존재한다. 단일 요청의 높은 effort나 답변 재생성을 Ultra 성공으로 처리하지 않는다. |
| **LAT-REASON-004 / L** 구성·한도 | agent 수·역할별 모델/추론·최대 동시 요청·반복·시간·공유 token/비용 예산을 조절한다. | 자식 예약과 coordinator 사용량이 root 총량에 포함된다. 서버가 usage를 생략하면 보수적 예약과 확인 가능한 상한을 사용한다. |
| **LAT-REASON-005 / L** 서버 부하·변경 충돌 | 동일 serving resource의 요청을 합산 제한하고, 공유 checkout 쓰기는 직렬화하며 병렬 writer는 worktree로 분리한다. | 서버 처리량이 1이어도 논리 다중 agent를 큐로 진행한다. 같은 서버를 다른 URL로 등록해도 지정된 resource group 상한이 유지된다. |
| **LAT-REASON-006 / L** 중단·복구·전환 | task tree·결정된 옵션·예산·artifact를 기록한다. 단계 변경은 안전한 실행 경계에서 새 snapshot으로 적용한다. | Ultra 취소가 queued/running children에 전파되고 재시작 때 완료한 쓰기를 중복 실행하지 않는다. 한 child 실패와 전체 실패를 구분한다. |
| **LAT-REASON-007 / L+P** 표시·진단 | 선택 단계·실제 요청 옵션·활성/대기 agent·서버 병목·usage·provider가 공개한 추론 요약을 구분한다. | raw private reasoning을 요구하거나 만들어 표시하지 않는다. endpoint가 옵션을 무시할 가능성/증거 부족을 verified로 숨기지 않는다. |
| **LAT-REASON-008 / L** 모델 간 역할 분담 | 동일 local model로 Ultra를 실행하고, 사용자가 설정하면 역할별로 다른 local/remote/cloud 모델을 사용한다. | 지정한 연결 범위 안에서만 배정한다. 장애·작은 context를 이유로 코드를 임의 클라우드에 보내지 않고 private continuation을 다른 provider에 넘기지 않는다. |

### 도구와 MCP 자동화

[확장 계약](extensions.md)은 MCP wire/config 호환을, [검색·MCP 제작 계약](tools-and-mcp-authoring.md)은
실제 도구 목록·설정/제작 흐름·실패 복구를 소유한다. 아래 기능도 최종 제품의 필수 범위다.

| ID / 분류 | Lathe 요구사항 | 수용 기준 |
| --- | --- | --- |
| **LAT-MCP-001 / L+I** 전체 client | stdio·Streamable HTTP·legacy SSE, tools/resources/prompts, pagination/list 변경, progress/cancel/reconnect를 지원한다. | transport·protocol version·capability별 테스트와 지원 상태가 존재한다. SDK 설치만으로 최신 protocol 전체 지원을 표시하지 않는다. |
| **LAT-MCP-002 / L** 도구 탐색 | 도구 이름·설명·schema·연결 상태를 검색하고 필요한 schema만 context에 로드한다. builtin/skill/MCP의 출처를 구분한다. | 많은 도구에서도 선택→schema load→call이 된다. schema/연결 revision이 바뀐 오래된 호출은 재검증한다. |
| **LAT-MCP-003 / L+I** 인증·사용자 입력 | API key/header/env 참조, OAuth, elicitation, 실제 지원하는 roots/sampling 등을 제공한다. | secret은 Keychain 참조로 등록하고 모델·로그로 누출하지 않는다. capability별 입력·거절·만료·예산을 검증한다. |
| **LAT-MCP-004 / L+I** 자동 설정 | 자연어 요청으로 기존 서버 조사→설정 계획→의존성/credential 확인→연결 시험→등록/활성화→실제 호출을 수행한다. | 승인된 scope 안에서는 매 단계 재승인 없이 완료한다. 누락 secret/OAuth 상호작용/권한 확대가 필요한 단계만 이유와 함께 기다린다. |
| **LAT-MCP-005 / L** 서버 제작 | 필요한 도구의 입력·출력·효과를 정의하고 SDK template, 소스, dependency pin, 실행 설정, 사용 안내를 생성한다. | 실제 build 가능한 서버 산출물과 소유 경로가 남는다. Swift 앱 코어와 별도로 사용자가 허용한 Swift/TypeScript/Python 서버 runtime을 사용할 수 있다. |
| **LAT-MCP-006 / L** 제작 검증 | schema/unit/protocol/실제 agent 왕복 검증을 통해 만든 서버를 사용한다. mock과 실제 연결 검증을 구분한다. | initialize→list→call→결과 활용과 실패/timeout/cancel을 통과해야 활성 검증 완료가 된다. destructive tool은 허용된 fixture 대상으로 검증한다. |
| **LAT-MCP-007 / L+I** 유지·복구 | 서버 상태/로그/환경 진단, 수정·업데이트·재시험·reload·disable·이전 revision rollback을 제공한다. | 실패한 변경은 기존 정상 server/config를 유지한다. 불명확한 외부 부수효과는 자동 재호출/복원하지 않는다. |
| **LAT-MCP-008 / L** 위임·활성화 경계 | 사용자 출처 grant로 설정 대상·runtime/dependency·network/effect 범위를 고정하고 검증된 revision을 활성화한다. | agent가 grant를 스스로 만들거나 deny를 바꾸지 못한다. Plan·grant 취소·범위 초과에서는 중지하고, grant 안의 MCP 제작/등록은 반복 승인 없이 이어진다. |
| **LAT-MCP-009 / L+P** 비텍스트 결과 | text/structured/image/audio/resource link/embedded resource를 typed content로 보존하고 모델/API별 지원 경로로 전달한다. | screenshot 도구→이미지 blob→vision 판단→후속 재사용을 검증한다. 미지원 content를 조용히 버리거나 base64를 text로 보내고 이해했다고 표시하지 않는다. |
| **LAT-MCP-010 / L+I** MCP server 모드 | Lathe의 선택된 파일·명령 도구를 외부 client가 사용하는 stdio server 모드를 제공한다. client별 workspace·tool subset·grant·수명을 제한하고 같은 broker/journal을 사용한다. | 외부 fixture client가 initialize/list/read/edit/run을 수행한다. 승인 client가 없으면 명확한 오류로 끝내며, MCP 입력만으로 새 권한을 발급하거나 자신의 server를 재귀 호출하지 않는다. |
| **LAT-EXT-001 / L+I** plugin 의존성 | plugin 간 직접/전이 dependency·version 제약·source·lock과 설치/업데이트/disable/remove를 graph로 처리한다. | A→B 설치와 충돌/cycle/누락 실패를 구분한다. 업데이트 실패는 기존 정상 graph를 유지하고 B 제거 시 A의 실행 가능 상태를 재검사한다. package SDK lock과 구분한다. |

## 11. 외부/hosted 기능의 별도 계약

참고 동작: Claude Code의 Remote Control은 로컬 실행을 원격 UI에서 제어하는 형태이고, cloud 실행은 별도 실행 환경이다. [Remote Control](https://code.claude.com/docs/en/remote-control), [cloud 실행](https://code.claude.com/docs/en/claude-code-on-the-web)

참고 동작: Desktop에는 SSH 세션이 있고, 모바일은 로컬/클라우드 세션을 제어하는 client다. Slack의 코딩 요청과 원격 routine의 일정·API·GitHub trigger는 별도 서비스 흐름이다. [SSH 세션](https://code.claude.com/docs/en/desktop#ssh-sessions), [mobile](https://code.claude.com/docs/en/mobile), [Slack](https://code.claude.com/docs/en/slack), [routines](https://code.claude.com/docs/en/routines)

참고 동작: macOS computer use는 공식 문서상 research preview이고, Desktop iOS simulator pane은 public beta다. Lathe는 이들까지 비교 대상으로 기록하되 자체 구현의 안정성 단계·모델 조건·OS 권한을 따로 표시한다. [computer use](https://code.claude.com/docs/en/computer-use), [iOS simulator](https://code.claude.com/docs/en/desktop-ios-simulator)

| ID / 분류 | Lathe 대응 목표 | 완료 조건·범위 |
| --- | --- | --- |
| **LAT-INTEGRATION-001 / I** 브라우저/IDE | 브라우저 screenshot·상태 읽기·조작, IDE의 선택 코드·진단·diff 연결을 확장 계약으로 제공한다. | browser/IDE별 연결·권한·대상 선택과 사용자가 실제 조작 대상을 볼 수 있는 UI가 필요하다. 단순 URL fetch를 브라우저 조작 지원으로 부르지 않는다. |
| **LAT-INTEGRATION-002 / I** 원격 제어 | Mac에서 수행 중인 세션을 인증된 원격 client가 관찰·승인·중단·입력할 수 있게 한다. | pairing·client 해지·접속 표시·권한·재연결 event cursor가 검증되어야 한다. 로컬 endpoint URL 입력과 별개의 기능이다. |
| **LAT-INTEGRATION-003 / I** hosted executor | 사용자가 선택한 cloud 실행 환경에 workspace·tools를 둔다. 모델 provider와 executor를 별도로 선택한다. | fresh clone/환경 준비·secret scope·network 정책·job 수명·log·취소·결과 반입·실행 비용 계약이 검증되어야 한다. Anthropic 관리 VM이나 계정 권한의 재사용을 전제하지 않는다. |
| **LAT-INTEGRATION-004 / I** 외부 알림·공유 | GitHub·Slack 등 연결이 있을 때 작업 상태 공유·외부 trigger를 제공한다. Slack mention/명령을 session에 연결하고 답변·diff/PR 링크를 원래 thread로 보낸다. | 송신 대상·내용·계정·scope와 사용자 허용 정책이 필요하다. webhook 서명·중복 이벤트·권한 변경을 검증하고, 외부 메시지를 저장소 실행 권한으로 자동 승격하지 않는다. |
| **LAT-INTEGRATION-005 / L+I** 산출물 | 코드·텍스트·HTML·이미지·문서 결과를 파일로 보존하고 앱에서 미리보기·외부 열기를 제공한다. hosted 공유는 별도 저장소 adapter다. | 로컬 생성 owner·revision·경로를 표시한다. 공유에는 인증·접근 범위·만료·삭제·다운로드 계약이 필요하며 로컬 생성만으로 공개 업로드하지 않는다. |
| **LAT-INTEGRATION-006 / I** SSH executor | host profile, 사용자 SSH config/agent, host key 확인, remote root, 원격 runner 버전·capability, 연결·재연결을 지원한다. remote file·tool·Git·PTY와 preview tunnel을 같은 세션에 연결한다. | 원격 workspace에서 E2E-01·03을 수행한다. 연결 단절 뒤 작업 상태를 확인하기 전 비멱등 명령을 재전송하지 않고, remote path를 local path로 실행하지 않는다. |
| **LAT-INTEGRATION-007 / I** hosted routine | Mac이 꺼져 있어도 원격 executor에서 일정·API 호출·GitHub 이벤트로 새 run을 시작한다. routine revision·환경·secret scope·동시 실행·재시도·알림·이력을 관리한다. | 실제 hosted scheduler/executor·인증·비용·보존 정책이 연결되어야 한다. 중복 trigger와 취소를 검증하고 로컬 예약 성공만으로 완료 처리하지 않는다. |
| **LAT-INTEGRATION-008 / I** mobile client | 인증된 모바일 화면에서 세션 시작·계속하기·진행 관찰·질문/승인·중단·diff 확인·desktop handoff를 제공한다. native companion 또는 responsive client를 별도 결정한다. | 작은 화면에서 정확한 명령/변경을 확인하고 승인할 수 있다. push 알림은 비밀을 노출하지 않고 device revoke가 실행 권한을 즉시 차단한다. |
| **LAT-INTEGRATION-009 / L+P+I** computer use | 화면 읽기·앱 선택·클릭·입력·스크롤을 별도 tool adapter로 제공하고 vision 가능 모델·macOS 접근 권한·대상 앱 정책을 확인한다. | 현재 제어 대상과 사용 중 상태가 보이고 즉시 중지할 수 있다. OS 권한 거부·화면 변경·로그인·보호된 입력에서 적절히 중단하며 일반 파일 tool 권한과 혼합하지 않는다. |
| **LAT-INTEGRATION-010 / L+I** iOS simulator | 설치된 Xcode·simulator를 감지하고 빌드·실행·기기 선택·화면 캡처·입력·log를 개발 작업에 연결한다. | 실제 simulator에서 수정 앱을 실행·확인한다. Xcode·runtime 부재는 설치 필요 상태이며 단순 build 성공을 화면 검증 성공으로 표시하지 않는다. |

이 연동들은 최종 비교 목록에 남긴다. 계정·서버·라이브러리 선택이나 구현이 없으면 명시적으로 “설계됨/연결 필요/미구현”으로 표시하며, 앱 전체가 Claude Code의 모든 서비스와 동일하다고 소개하지 않는다.

## 12. 최종 parity 검증 시나리오

개별 버튼 존재가 아니라 실제 작업을 기준으로 판정한다. deterministic fixture/mock은 엔진 계약을 검증하고, 실제 모델 시험은 별도 기록한다. 모델 실패와 앱 protocol 실패를 구분하되 미완료 작업을 성공으로 계산하지 않는다.

| 시나리오 | 연결 요구사항 | 통과 기준 |
| --- | --- | --- |
| **E2E-01 버그 수정** | LAT-CORE-001/007, LAT-TOOL-001~004/006~007, LAT-GIT-001 | 실패 재현→관련 코드 검색→다중 파일 수정→테스트→diff/결과 보고 |
| **E2E-02 계획 후 구현** | LAT-PERM-001~003, LAT-CORE-003/004 | plan 중 소스 불변→질문→계획 수정→선택 실행→승인 정책 유지 |
| **E2E-03 중단과 재개** | LAT-CORE-002/006, LAT-SESSION-001/003/005/006 | 명령·편집 중 취소/강제 종료→이력 복원→중복 효과 없이 재개/복원 |
| **E2E-04 장기 세션** | LAT-CTX-001~004, LAT-MEM-001~004 | 긴 tool 출력→compaction→provider 변경→목표·지침 유지→새 세션 기억 |
| **E2E-05 병렬 구현** | LAT-TASK-001~005, LAT-GIT-003/004 | 조사 agent와 두 worktree writer→실패/승인 처리→결과 검토·통합 |
| **E2E-06 혼합 입력** | LAT-TOOL-005/011~014 | 문서 검색·이미지/PDF·notebook 입력→근거 있는 수정과 실제 검증 |
| **E2E-07 개발 자동화** | LAT-CLI-001~006, LAT-PERM-001/006 | 명시적 test harness 또는 실행 중 앱에 연결→stdin prompt→허용 tool→JSON stream→중지/오류 exit. 기본 client가 daemon을 만들지 않음 |
| **E2E-08 모든 연결** | LAT-PROVIDER-001~005 | 여섯 필수 연결과 별도 호환 서버, 원격 vLLM/Ollama에서 최소 E2E-01·03 수행 |
| **E2E-09 실행 격리** | LAT-PERM-005~007, LAT-TASK-003 | 악성 project 설정·tool 출력·경로 우회·부모 권한 확대 요청이 실행 정책을 바꾸지 않음 |
| **E2E-10 지속 작업** | LAT-TASK-002/006~009 | watch·goal·로컬 예약을 각기 실행→sleep/재시작→중복 방지→상태 변경 알림→취소 |
| **E2E-11 다중 대화** | LAT-CORE-003/008, LAT-SESSION-007 | 본 작업 중 side chat→선택 답변 전달→다른 세션 메시지→수신 보류/허용→권한 유지 |
| **E2E-12 workflow** | LAT-TASK-010, LAT-TASK-003/004, LAT-GIT-003/004 | script 검토→fan-out 조사/수정→하나의 child 실패→중지·재개→fan-in 검증→결과 취합 |
| **E2E-13 개발·검토 화면** | LAT-UI-004/005, LAT-GIT-006/007 | editor·preview 실행→요소 피드백→diff 코멘트→수정→PR/CI 관찰→자동 동작 범위 확인 |
| **E2E-14 원격 작업** | LAT-INTEGRATION-002/003/006/008 | SSH 또는 hosted 실행→remote/mobile 관찰·승인→연결 단절→재연결→취소→결과 반입 |
| **E2E-15 외부 자동화** | LAT-INTEGRATION-004/005/007 | 서명된 trigger→중복 억제→hosted run→결과 artifact→허용한 Slack/GitHub 알림→접근 해지 |
| **E2E-16 화면·simulator** | LAT-INTEGRATION-001/009/010 | 대상 선택→권한 확인→화면 기반 조작/실행→검증 기록→사용자 중지·권한 회수 |
| **E2E-17 추론 단계** | LAT-REASON-001/002/006/007 | native 옵션과 원격 vLLM/Ollama Off/On→실제 payload 검사→미지원/무시 옵션 표시→재개 시 snapshot 유지 |
| **E2E-18 Ultra** | LAT-REASON-003~008, LAT-TASK-003~005 | 동일 local 모델의 역할 분담→서버 큐·공유 예산→단일 writer/별도 worktree→독립 검토/테스트→중간 실패·취소·재개 |
| **E2E-19 독립 검색** | LAT-TOOL-001/011/012, LAT-MCP-002 | local 모델로 코드 검색·웹 검색·본문 읽기·도구 검색을 구분 수행→출처→backend 실패/필터 미지원 표시 |
| **E2E-20 MCP 자동 설정** | LAT-MCP-001~004/007/008 | 자연어 연결 요청→인증 참조→실제 시험→허용 scope 등록/활성화→호출→연결 단절·token 만료·설정 rollback |
| **E2E-21 MCP 자체 제작** | LAT-MCP-005~008 | 요구 분석→server scaffold→build→schema/protocol 테스트→등록→agent가 새 도구 사용→업데이트 실패 복구·grant 취소 |
| **E2E-22 실행 환경 재현** | LAT-EXEC-001~003, LAT-GIT-003 | profile 선택→fresh worktree setup→build/test→case별 증거→취소·setup 실패·0 tests·오래된 결과 구분 |
| **E2E-23 실제 디버깅** | LAT-DEBUG-001~003, LAT-EXEC-001 | launch/attach→breakpoint→stack/variable→step→원인 수정→재실행; stale handle·adapter crash·외부 대상 detach |
| **E2E-24 여러 저장소** | LAT-WORKSPACE-001, LAT-GIT-001~004 | frontend/backend root 추가→각 cwd·지침·권한으로 변경/검증→저장소별 diff→fork의 root 제거 격리·전역 철회·resume |
| **E2E-25 편집 내용 보존** | LAT-UI-005/006, LAT-SESSION-005 | 미저장 buffer+외부 수정+agent patch→충돌 해결/선택 적용→undo→crash 복구→현재 revision 검증 |
| **E2E-26 provider 경계** | LAT-PROVIDER-006~008 | 정상 HTTP pause/blocked/empty→제한된 continuation→context 불일치→동일 alias 교체→stale 진단·의존 profile 이관 |
| **E2E-27 MCP 결과·역방향 연결** | LAT-MCP-009/010 | screenshot 이미지 판단·미지원 결과 보존; 같은 clientInfo의 두 외부 client→ingress별 scope 유지→무인 승인 오류·재귀 차단·취소 |
| **E2E-28 plugin 의존성** | LAT-EXT-001 | A→B 설치→버전 충돌·cycle→실패한 업데이트 rollback→의존 plugin disable/remove |
| **E2E-29 음성 입력** | LAT-UI-007 | 마이크 허가/거부→전사→기존 입력과 편집→명시적 전송→취소/실패 시 draft 보존 |

필수 연결의 범위는 OpenAI, AI Studio, Vertex, Claude, vLLM, Ollama다. “기타 호환 서버”는 이름만 추가하는 대신 버전·모델·API flavor를 명시한 최소 한 개의 실제 추가 서버 fixture/smoke test를 남긴다. vision 등 P 기능은 지원 조합에서 시험하고 미지원 조합에서는 정확한 unavailable 동작을 시험한다.

## 13. 추적과 완료 표시

각 요구사항은 `planned → implementing → verified` 상태와 테스트 링크·검증 날짜·provider/model/server 조건을 갖는다. 구현이 있지만 실제 연결을 시험하지 못했으면 `implemented, integration unverified`로 기록한다. 제약이 있는 경우 `partial`과 남은 조건을 함께 둔다.

커밋/이슈에는 해당 LAT ID를 넣고 다음을 연결한다: 사용자 동작, 계약 변경, 실패 처리, 검증 결과, 남은 차이. 첫 milestone 이후에도 이 문서의 L/P/I 목표와 미구현 목록을 유지하며, 최종 parity 선언은 이 목록과 [확장 요구사항](extensions.md)의 검증 결과를 함께 검토한 뒤에만 한다.
