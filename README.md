# lathe-code
Lathe: a native macOS coding agent in Swift

Swift로 만드는 개인용 macOS 코딩 에이전트. Claude Code와 동등한 코딩 작업 흐름을
네이티브 앱과 공통 CLI에서 제공하는 것이 목표입니다. OpenAI, Google AI Studio,
Vertex AI, Anthropic Claude, vLLM, Ollama 및 기타 모델 서버를 지원할 계획입니다.
모델 서버는 같은 Mac, LAN, 외부 서버 어디에나 둘 수 있습니다.

현재 **M1의 첫 코딩 흐름을 구현 중**입니다. SwiftUI/AppKit 앱과 CLI가 같은 Swift 엔진에
연결되며 OpenAI Responses 또는 OpenAI 호환 Chat API를 통해 파일 읽기·쓰기와 명령 실행을
이어갑니다. 네이티브 모델 설정, Keychain 인증, 도구별 승인, SQLite 실행 기록과 blob을 제공합니다.

기본 선택은 **mock 모드**입니다. 설정에서 연결을 저장하고 작성창에서 선택한 실행만 실제 모델과
도구를 사용합니다. 명령은 승인 후 **sandbox 없이 이 Mac에서 실행**됩니다.
현재 범위·한도·사용법은 [첫 코딩 흐름](docs/coding-preview.md)을 참고하세요.
실제 OpenAI/vLLM/Ollama 서버 검증, 검색·MCP·Ultra와 전체 기능 동등성은 아직 완료하지 않았습니다.

## 빌드와 실행

macOS 15 이상, Swift 6을 제공하는 Xcode가 필요합니다. Xcode의 Command Line Tools를 선택한 뒤:

```sh
Scripts/build-app.sh
open .build/macos/Lathe.app
```

Xcode에서는 `Apps/Lathe/Lathe.xcodeproj`의 **Lathe** scheme을 실행합니다.
앱의 **프로젝트 열기**로 폴더를 고릅니다. `⌘,`에서 모델 연결을 저장하고 작성창에서 선택하면
실제 코딩 흐름을 사용하며, **모의 모델**은 외부 호출 없이 연결을 시험합니다.
앱을 닫아도 엔진은 유지되며 같은 사용자의 CLI가 동일한 세션에 연결됩니다.

```sh
.build/macos/lathe status
.build/macos/lathe run --workspace "$PWD" "스트리밍 테스트"
.build/macos/lathe sessions
swift test --package-path Packages/LatheKit
python3 Scripts/smoke-engine.py --bin-dir .build/macos
python3 Scripts/smoke-runner.py --runner .build/macos/lathe-runner
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
