# lathe-code
Lathe: a native macOS coding agent in Swift

Swift로 만드는 개인용 macOS 코딩 에이전트. Claude Code와 동등한 코딩 작업 흐름을
네이티브 앱과 공통 CLI에서 제공하는 것이 목표입니다. OpenAI, Google AI Studio,
Vertex AI, Anthropic Claude, vLLM, Ollama 및 기타 모델 서버를 지원할 계획입니다.
모델 서버는 같은 Mac, LAN, 외부 서버 어디에나 둘 수 있습니다.

현재 **M0 실행 기반의 첫 구현**입니다. SwiftUI/AppKit 앱과 CLI가 별도 Swift 엔진에
연결되어 세션 생성, 모의 응답 스트리밍, 중단, 대화 이력 조회와 재접속을 제공합니다.
SQLite에 작업과 이벤트를 저장하며 엔진 재시작 시 미완료 작업을 `interrupted`로 복구합니다.

실제 모델·파일 편집·터미널·검색·MCP·Ultra는 후속 단계입니다. 현재 앱은 **mock 모드**를
명시하며 프로젝트 파일을 변경하거나 모델 API를 호출하지 않습니다.

## 빌드와 실행

macOS 15 이상, Swift 6을 제공하는 Xcode가 필요합니다. Xcode의 Command Line Tools를 선택한 뒤:

```sh
Scripts/build-app.sh
open .build/macos/Lathe.app
```

Xcode에서는 `Apps/Lathe/Lathe.xcodeproj`의 **Lathe** scheme을 실행합니다.
앱의 **프로젝트 열기**로 폴더를 고르고 요청을 전송하면 모의 스트림이 시작됩니다.
앱을 닫아도 엔진은 유지되며 같은 사용자의 CLI가 동일한 세션에 연결됩니다.

```sh
.build/macos/lathe status
.build/macos/lathe run --workspace "$PWD" "스트리밍 테스트"
.build/macos/lathe sessions
swift test --package-path Packages/LatheKit
python3 Scripts/smoke-engine.py --bin-dir .build/macos
```

빌드 결과는 현재 Mac 아키텍처용 개발 빌드이며 ad-hoc 서명입니다.
공증된 배포판은 아직 제공하지 않습니다. 상세 구조·실행·검증·제약은 [개발 가이드](docs/development.md)를 참고하세요.

## 설계

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

개인 사용과 GitHub 소스 배포를 우선합니다. 빌드의 최소 버전은 macOS 15이며,
SwiftUI와 AppKit으로 네이티브 UI를 구성합니다. 최소 OS에서의 실행 검증은 별도로 추적합니다.
코드뿐 아니라 설계·문서·설정도 의미 있는 변경 단위마다 검증 후 커밋하고 GitHub에 반영합니다.
