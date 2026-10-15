# 네이티브 실행 helper 계약

2026-10-15. `LatheExecution`은 Swift 실행 라이브러리, `lathe-runner`는 별도 네이티브
실행 helper다. `LAT-TOOL-007/008`, EXEC, PERM의 기반이며 전체 요구사항 완료가 아니다.
M1 첫 coding loop에서 공통 ToolBroker/PolicyEngine을 거친 승인된 `run_command`를 연결했다.
모델 도구는 비대화형 pipe 실행이며 아래 PTY 제어는 아직 앱 터미널에 연결하지 않았다.
제품 사용 계약과 실제 승인 범위는 [첫 코딩 흐름](coding-preview.md)을 따른다.

## 실행과 수명

- 실행 파일·작업 폴더는 절대 경로다. argv를 그대로 전달하며 shell 해석이 필요하면
  호출자가 `/bin/sh` 등과 인자를 명시한다. 부모의 cwd를 바꾸지 않는다.
- 환경 변수는 명시적으로 지정한 값만 전달한다. 부모 API 키나 PATH를 자동 상속하지 않는다.
- `posix_spawn`으로 새 session/process group을 만든다. pipe 모드는 stdout/stderr를 분리하고,
  PTY는 controlling terminal을 연결해 하나의 terminal byte stream으로 전달한다.
- Swift worker가 두 출력을 함께 읽는다. 임의 UTF-8 decoding 없이 `Data`로 보존한다.
  입력 queue는 1 MiB, 출력은 요청의 합계 byte 한도(기본 1 MiB, 최대 64 MiB)를 적용한다.
- 취소·timeout·출력 초과 및 주 프로세스 종료 시 소유한 원래 group에 TERM을 보내고 grace 뒤 KILL한다.
  leader는 group 정리까지 reap하지 않아 PID 재사용에 따른 잘못된 signal을 방지한다.
- 주 프로세스의 exit code/signal과 종료 이유 `exited/cancelled/timedOut/outputLimit`을 분리한다.
  이벤트 callback은 잠금 밖에서 순차 호출된다. 라이브러리 사용자는 callback을 막지 않아야 한다.

process group은 OS 격리가 아니다. 자식이 새 group/session을 만들거나 job control을 쓰면 이 정리
범위를 벗어날 수 있다. helper SIGKILL·host crash에서도 자식 전체 종료를 보장하지 않는다.
남은 프로세스가 pipe를 유지하더라도 drain은 종료하며 결과의 불명확한 외부 효과를 자동 재실행하지 않는다.
일반 명령의 detached/background 생존 정책은 후속이다.

PTY `resize`는 행·열과 WINCH를 전달한다. `eof`는 canonical 모드의 EOT이며 실제 half-close가 아니다.
raw-mode 앱의 EOF 동작이나 ANSI 화면 에뮬레이터·scrollback·재연결 화면은 제공하지 않는다.

## helper 프로토콜 v1

```sh
lathe-runner --request /absolute/request.json --journal /absolute/fresh-directory
```

요청 파일은 128 KiB 이하 JSON이다. Codable 기본 인자는 파일 decoding의 생략값이 아니므로 모든
command 필드를 보낸다. 다음은 구조 예시이며 실행 요청은 supervisor가 작성한다.

```json
{
  "protocolVersion": 1,
  "command": {
    "executable": "/usr/bin/printf",
    "arguments": ["hello\n"],
    "workingDirectory": "/tmp",
    "environment": {},
    "mode": "pipes",
    "timeoutSeconds": 30,
    "terminationGraceSeconds": 0.5,
    "outputLimitBytes": 1048576,
    "terminalColumns": 80,
    "terminalRows": 24
  }
}
```

stdin은 supervisor 제어용 NDJSON이며 line당 64 KiB 이하이다.
`input`의 `data`는 base64, `resize`는 `columns/rows`, `eof`는 대상 입력 종료,
`cancel`은 실행 취소다. supervisor는 실행 중 stdin을 열어 둔다. **stdin EOF는 owner loss로 취소**하며
대상 stdin만 닫으려면 `{"action":"eof"}`를 보낸다. SIGINT/SIGTERM도 실행 취소로 처리한다.

stdout은 `protocolVersion`, 순번, 시간, `CommandEvent`를 포함한 NDJSON이다.
event payload는 Swift Codable enum 형태(`started.pid`, `output.stream/data`, `finished._0`)다.
stdout을 읽지 않거나 닫으면 최대 1초의 전송 대기 뒤 취소하고 실패 receipt를 남긴다.
파싱 실패·초과 제어 프레임도 실패 처리한다. stderr에는 helper 진단만 보낸다.

helper 종료 코드는 target exit code, signal은 128+signal, 취소 130, timeout 124,
출력 초과 125, helper 오류 1이다. 코드가 겹칠 수 있으므로 결과의 reason/status를 함께 확인한다.

## 실행 기록과 복구

새 journal 디렉터리를 0700, 파일을 0600으로 생성한다. 기존 디렉터리는 재사용하지 않는다.

1. 실행 인자·cwd·한도·환경 변수 **키**를 `intent.json`에 fsync한 뒤 명령을 시작한다.
2. 순번이 있는 `events.ndjson`에 시작·byte 출력·종료 이벤트를 기록하고 fsync한 뒤 supervisor로 보낸다.
3. `result.json`에 결과 또는 helper 실패를 저장한다. intent/result는 같은 디렉터리의 임시 파일을
   fsync한 후 atomic link로 공개하고 디렉터리를 fsync한다. 쓰기는 열린 directory FD를 기준으로 한다.

환경 변수 값은 intent에서 제외하지만 **argv와 프로그램 출력은 그대로 기록**한다. 이를 secret redaction으로
표시하지 않으며 실제 provider secret은 실행 인자/출력에 넣지 않는다. 엔진은 별도의 일반 blob 저장소를
사용하지만 helper journal의 retention·암호화는 후속이다.
event stream은 중단 시 마지막 line이 불완전할 수 있다. 유효한 result가 없거나 helper 오류가 있으면
조사·reconciliation이 필요하며 실행 성공이나 안전한 재실행을 추정하지 않는다.
helper journal은 엔진 데이터 아래 invocation별 디렉터리에 보존한다. 엔진은 SQLite ToolInvocation에
승인·실행·terminal 상태를 기록하고, bridge가 helper의 event/result 일치를 확인한 뒤 결과 blob을 저장한다.
엔진 재시작 시 실행 중 호출은 unknown으로 남기며 helper journal을 근거로 자동 재실행하지 않는다.

## 검증

```sh
swift test --package-path Packages/LatheKit
Scripts/build-app.sh
python3 Scripts/smoke-runner.py --runner .build/macos/lathe-runner
```

단위 테스트는 실제 byte pipe, explicit argv/env/cwd, PTY input/resize/EOF, 취소,
출력 제한과 주 프로세스 종료 뒤 같은 group의 자식 정리를 검사한다.
helper smoke는 실제 바이너리와 임시 디렉터리로 제어 채널·journal·실패 결과를 검사한다.
[sandbox probe](probes/sandbox.md)와 [LLDB-DAP probe](probes/lldb-dap.md)는 별도 기술 검증이며
이 실행 helper에 production sandbox나 debugger가 연결된 것은 아니다.
