import Foundation
import Darwin

// Only the probe creates this path and process. The running loop has a bounded lifetime.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--attach" {
    let heartbeat = CommandLine.arguments[2]
    for tick in 0..<600 {
        try String(tick).write(toFile: heartbeat, atomically: true, encoding: .utf8)
        usleep(100_000)
    }
    exit(0)
}

alarm(60)

@inline(never)
func inspectLocal() {
    var probeValue = 41
    probeValue += 1 // LATHE_BREAKPOINT
    print("lathe-probe-value=\(probeValue)") // LATHE_AFTER_STEP
}

inspectLocal()
