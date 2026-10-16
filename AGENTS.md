# Lathe 작업 규칙

## 제품 방향

- Swift 기반 macOS 네이티브 **단일 앱**을 만든다. runtime/DB/모델/도구 실행의 owner는 앱 프로세스다.
- 별도 상주 engine, 로그인 agent, 시스템 CLI를 설치하지 않는다. CLI와 standalone engine은 명시적인 개발·검증 빌드에서만 제공한다.
- 마지막 작업 창 닫기·종료 시 진행 중 작업이나 미전송 입력이 있으면 중단 후 종료/백그라운드 유지/취소를 선택한다. 미완료 작업이 없으면 종료하며 앱 밖 daemon을 남기지 않는다.
- Claude Code의 작업 흐름과 확장 기능 동등성을 목표로 한다. 모델 결과 품질의 동일성을 약속하지 않는다.
- OpenAI, Google AI Studio, Vertex, Claude, vLLM, Ollama 및 기타 모델 서버를 지원한다.
- 모델 서버는 localhost/LAN/외부 주소 모두 가능하다. 모델 연결과 코드 실행 환경을 분리한다.
- 로컬·개인 서버의 Off/On/Ultra와 provider 고유 추론 옵션을 지원한다. Ultra는 추론 활성 다중 agent 실행이며 출력 숨김이나 단순 token 증액과 구분한다.
- 사용자가 준 GitHub/Markdown/설치 문서를 읽고 기존 MCP 또는 관련 설정을 설치·구성·검증·적용한다. dependency 설치·기존 서버 build는 포함하지만 새 MCP 서버 scaffold/구현/제작은 범위에서 제외한다. 문서와 agent가 자신의 권한을 새로 발급할 수는 없다.
- 권한은 fullAccess(추가 승인 없음), autoApprove(낮은 위험만 자동/나머지 승인), acceptEdits(읽기·쓰기 자동/실행 승인), requestApproval(읽기·쓰기·실행 모두 승인)의 네 모드다. 계획 작업은 별도 개념이며 plan/dontAsk는 새 권한 모드로 제공하지 않는다.
- 개인용 GitHub 배포를 우선한다.

## 설계와 구현

- 설계 요청에서는 설계 문서를 구체화하고, 구현 요청에서는 관련 요구사항과 마일스톤을 확인해 작업한다.
- `docs/features.md`의 LAT ID, `docs/extensions.md`의 호환 계약, `docs/architecture.md`의 경계를 유지한다.
- 추론/Ultra는 `docs/reasoning-and-ultra.md`, 검색/MCP 자동화는 `docs/tools-and-mcp-setup.md`의 세부 계약도 확인한다.
- 구조나 범위가 달라지면 관련 문서도 갱신한다. 일부 구현을 전체 기능 지원으로 표시하지 않는다.
- 앱과 선택적인 개발 client는 앱 내부의 같은 runtime과 ToolBroker를 사용한다. 개발 CLI는 기본 attach-only이며 독립 테스트 engine 시작은 명시적인 옵션·데이터 root가 필요하다. provider DTO를 UI나 공통 실행 코어에 퍼뜨리지 않는다.
- 취소·복구·권한·스트리밍 경계의 검증을 우선하고, 실제로 수행하지 않은 검증은 완료했다고 보고하지 않는다.
- 사용자에게 표시하는 고정 문구를 Swift 코드에 직접 쓰지 않는다. 의미가 안정적인 semantic key와 LatheLocalization 리소스를 사용하고 한국어·영어 번역 파일을 함께 관리한다. 표시 문장 자체를 key로 쓰지 않는다.
- 값이 들어가는 문장은 전체 문장을 번역 리소스에 두고 타입에 맞는 format placeholder로 삽입한다. 번역 문장 조각을 연결하거나 Swift 문자열 보간으로 문장을 조립하지 않는다. 버튼·메뉴·상태·오류 안내·접근성 설명도 같은 규칙을 따른다.
- 앱 문구와 오류 문구는 독립된 언어 설정을 따른다. 일반 문구는 `L10n.text/format`, 오류와 오류 안의 고정 설명은 `L10n.errorText/errorFormat`을 사용한다. 실행 helper에도 두 언어를 각각 전달하며 대상 명령의 환경에는 섞지 않는다.
- 사용자 입력·모델 응답·서버/OS 원시 진단·protocol 식별자는 번역문으로 재작성하지 않는다. 앱의 안내 문구는 리소스로 분리하고 원시 값은 자리표시자로 전달한다. 리소스 변경 시 언어별 key와 placeholder 일치, 누락 key, 번들 포함 여부를 검증한다.

## 변경 기록

- 사용자의 명시적 지시: 코드·설계·문서·설정의 의미 있는 변경 단위마다 검증 후 Git 커밋을 만든다.
- GitHub에 push하고 로컬 커밋 성공과 원격 반영 성공을 구분해 보고한다.
- 사용자 변경을 섞지 않는다. 기존 이력을 임의로 amend/squash/force-push하지 않는다.
- 새 브랜치가 필요하면 `codex/` 접두사를 기본으로 사용한다.
- API key·토큰·개인 프로젝트 내용·실제 세션 기록을 저장소나 테스트 fixture에 넣지 않는다.
