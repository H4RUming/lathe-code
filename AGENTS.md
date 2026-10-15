# Lathe 작업 규칙

## 제품 방향

- Swift 기반 macOS 네이티브 앱과 공통 CLI를 만든다.
- Claude Code의 작업 흐름과 확장 기능 동등성을 목표로 한다. 모델 결과 품질의 동일성을 약속하지 않는다.
- OpenAI, Google AI Studio, Vertex, Claude, vLLM, Ollama 및 기타 모델 서버를 지원한다.
- 모델 서버는 localhost/LAN/외부 주소 모두 가능하다. 모델 연결과 코드 실행 환경을 분리한다.
- 개인용 GitHub 배포를 우선한다.

## 설계와 구현

- 설계 요청에서는 설계 문서를 구체화하고, 구현 요청에서는 관련 요구사항과 마일스톤을 확인해 작업한다.
- `docs/features.md`의 LAT ID, `docs/extensions.md`의 호환 계약, `docs/architecture.md`의 경계를 유지한다.
- 구조나 범위가 달라지면 관련 문서도 갱신한다. 일부 구현을 전체 기능 지원으로 표시하지 않는다.
- GUI/CLI는 같은 engine과 ToolBroker를 사용한다. provider DTO를 UI나 공통 실행 코어에 퍼뜨리지 않는다.
- 취소·복구·권한·스트리밍 경계의 검증을 우선하고, 실제로 수행하지 않은 검증은 완료했다고 보고하지 않는다.

## 변경 기록

- 사용자의 명시적 지시: 코드·설계·문서·설정의 의미 있는 변경 단위마다 검증 후 Git 커밋을 만든다.
- GitHub에 push하고 로컬 커밋 성공과 원격 반영 성공을 구분해 보고한다.
- 사용자 변경을 섞지 않는다. 기존 이력을 임의로 amend/squash/force-push하지 않는다.
- 새 브랜치가 필요하면 `codex/` 접두사를 기본으로 사용한다.
- API key·토큰·개인 프로젝트 내용·실제 세션 기록을 저장소나 테스트 fixture에 넣지 않는다.
