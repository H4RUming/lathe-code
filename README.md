# lathe-code
Lathe: a native macOS coding agent in Swift

Swift로 만드는 개인용 macOS 코딩 에이전트. Claude Code와 동등한 코딩 작업 흐름을
네이티브 앱과 공통 CLI에서 제공하는 것이 목표입니다. OpenAI, Google AI Studio,
Vertex AI, Anthropic Claude, vLLM, Ollama 및 기타 모델 서버를 지원할 계획입니다.
모델 서버는 같은 Mac, LAN, 외부 서버 어디에나 둘 수 있습니다.

현재는 설계 단계입니다. 앱 기능과 빌드 프로젝트는 아직 구현하지 않았습니다.

- [기능 정의와 완료 기준](docs/features.md)
- [상세 아키텍처](docs/architecture.md)
- [설정·Skills·Hooks·MCP·Plugins 호환 계약](docs/extensions.md)
- [프로바이더와 원격 모델 연결](docs/providers.md)
- [추론 단계와 Ultra 다중 에이전트](docs/reasoning-and-ultra.md)
- [검색 도구와 MCP 자동 설정·제작](docs/tools-and-mcp-authoring.md)
- [실행 환경·테스트·디버거 계약](docs/execution-and-debugging.md)
- [기능 누락 점검과 보완 우선순위](docs/functional-gap-audit.md)
- [구현 순서와 변경별 커밋 계획](docs/roadmap.md)

로컬·개인 서버 모델에는 `Off / On / Ultra`를 제공할 계획입니다. Ultra는 추론을 켠
여러 에이전트가 조사·구현·검증을 분담하는 실행 방식입니다. 클라우드 모델의 고유 추론
옵션은 별도로 보존합니다. 검색과 MCP는 모델 연결과 독립적이며, MCP 서버의 제작·테스트·
등록·사용까지 사용자가 맡긴 범위 안에서 자동으로 이어가는 것이 목표입니다.

개인 사용과 GitHub 소스 배포를 우선합니다. 최소 지원 버전은 macOS 15 이상을
제안하며, SwiftUI와 AppKit으로 네이티브 UI를 구성합니다.
코드뿐 아니라 설계·문서·설정도 의미 있는 변경 단위마다 검증 후 커밋하고 GitHub에 반영합니다.
