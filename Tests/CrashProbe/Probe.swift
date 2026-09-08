import ContainerizationOS
import Darwin
import Foundation
import StudioDiagnostics

// Isolated from the test runner: this executable deliberately exercises SIGPIPE.
// Never package this target in the application.
@main struct Probe {
    static func pair() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        return fds
    }

    static func main() async throws {
        alarm(10) // A stuck relay fails the subprocess instead of hanging CI.
        signal(SIGPIPE, SIG_DFL) // Do not inherit the test runner's disposition.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "log-exit" {
            let log = try DiagnosticLog(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            log.append(source: "fixture", message: "last record before abrupt exit")
            kill(getpid(), SIGKILL)
            exit(8)
        }
        let protected = CommandLine.arguments.contains("protected")
        if protected {
            ProcessSafety.installBrokenPipeProtection()
            ProcessSafety.installBrokenPipeProtection()
        }
        if !CommandLine.arguments.contains("unprotected-relay") {
            let sockets = try pair()
            close(sockets[1])
            let count = "request".withCString { write(sockets[0], $0, 7) }
            guard count == -1, errno == EPIPE else { exit(2) }
            close(sockets[0])
            guard protected else { exit(3) }
        }

        // Queue source data before closing the destination. The relay must drain
        // it into the closed socket, regardless of which EOF callback runs first.
        for _ in 0..<16 {
            let source = try pair()
            let destination = try pair()
            guard "payload".withCString({ write(source[1], $0, 7) }) == 7 else { exit(5) }
            close(destination[1])
            let relay = BidirectionalRelay(fd1: source[0], fd2: destination[0])
            try relay.start()
            await relay.waitForCompletion()
            close(source[1])
        }

        // Other connections still work after failed clients in both directions.
        let source = try pair()
        let destination = try pair()
        let relay = BidirectionalRelay(fd1: source[0], fd2: destination[0])
        try relay.start()
        for (sender, receiver) in [(source[1], destination[1]), (destination[1], source[1])] {
            guard "OK".withCString({ write(sender, $0, 2) }) == 2 else { exit(6) }
            var received = [UInt8](repeating: 0, count: 2)
            guard recv(receiver, &received, 2, MSG_WAITALL) == 2, received == [79, 75] else { exit(7) }
        }
        relay.stop()
        await relay.waitForCompletion()
        close(source[1])
        close(destination[1])
    }
}
