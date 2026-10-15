# 실제 모델 서버 검사

2026-10-16. 사용자 지정 원격 vLLM **0.27.1**, Qwen 계열 제공 모델 한 구성에서
`Scripts/probe-provider.py`의 6개 검사가 통과했다. 실제 URLSession → engine → CLI → native runner를 사용했다.
서버 주소, 인증 정보, 실제 세션 transcript는 저장소에 넣지 않는다.

검사에는 `Scripts/build-app.sh --developer-tools`로 추가 빌드한 독립 개발 harness를 사용한다.
일반 배포 앱은 같은 실행 코어를 앱 프로세스 안에서 소유하며 별도 엔진을 설치하지 않는다.

## 확인한 동작

- 새 임시 데이터와 workspace를 사용하는 개발 전용 엔진에 연결한다.
- 모델이 합성 `source.txt`를 읽고 SHA-256을 얻는다.
- `add` 함수의 뺄셈을 덧셈으로 고치는 정확한 내용만 일회 승인한다.
- 수정 완료 후 고정 `/usr/bin/printf` 인자만 일회 승인한다.
- 파일 전체 내용, 명령의 stdout·stderr·exit code, 세 도구의 완료 상태와 모델 최종 응답을 확인한다.
- 직접 띄운 엔진을 종료하고 임시 workspace·데이터를 정리한다.

테스트 서버는 실제 스트림에 `reasoning`을 반환했다. Chat decoder는 이 필드와 이전
`reasoning_content`를 원래 이름으로 보존하여 다음 요청에 전달한다. 두 필드의 합산 UTF-8 1 MiB
한도, 비문자열 거절, tool 왕복 중 보존은 별도 provider 계약 테스트로 확인했다.
형식 근거는 [현재 vLLM reasoning](https://docs.vllm.ai/en/stable/features/reasoning_outputs/)과
[v0.10.2 reasoning_content](https://docs.vllm.ai/en/v0.10.2/features/reasoning_outputs.html) 문서다.

## 한계와 재실행

이 probe는 고정 명령 실행까지 검사한다. 수정한 함수의 테스트 실행, 대형 저장소 작업 품질,
로컬 Off/On 제어, Ultra, 인증된 서버나 다른 모델·API 구성의 호환성을 입증하지 않는다.
모델 추론을 포함한 실제 응답은 테스트 과정의 임시 저장소에서만 다루며 보고서에는 검사 결과와 도구 상태만 남긴다.
보고서는 기본적으로 Git에서 제외되는 `.build/probes`에 저장한다.

사용자 지정 서버에 요청을 보내므로 CI에서 자동 실행하지 않는다. 명령과 승인 범위는
[개발 가이드](../development.md#검증과-한계)를 따른다. 현재 probe는 인증 없는 OpenAI 호환 Chat API용이다.
