import Darwin

public enum ProcessSafety {
    /// Containerization's socket relay uses write(2). A disconnected peer must
    /// produce EPIPE for its existing cleanup path, not terminate the host app.
    /// Install before starting any runtime workers; never change other signals.
    public static func installBrokenPipeProtection() {
        _ = installed
    }

    private static let installed: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}
