# lathe-code
Lathe: a native macOS coding agent in Swift

Swift로 만드는 개인용 macOS 코딩 에이전트. OpenAI, Google AI Studio,
Vertex AI, Anthropic Claude, vLLM, Ollama 및 기타 호환 모델 서버를 지원할 계획입니다.
모델 서버는 같은 Mac, LAN, 외부 서버 어디에나 둘 수 있습니다.

현재는 설계 단계입니다. 앱 기능과 빌드 프로젝트는 아직 구현하지 않았습니다.

- [아키텍처 설계](docs/architecture.md)
- [구현 순서와 기능별 커밋 계획](docs/roadmap.md)

개인 사용과 GitHub 소스 배포를 우선합니다. 최소 지원 버전은 macOS 15 이상을
제안하며, SwiftUI와 AppKit으로 네이티브 UI를 구성합니다.
