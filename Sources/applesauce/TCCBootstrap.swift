import Darwin
import Foundation

/// Makes applesauce responsible for its own macOS privacy permissions.
///
/// Without this, macOS checks the permissions of the parent app (Terminal, the host app, node),
/// and a server started by some apps never gets a prompt. The process starts itself again
/// with the private `responsibility_spawnattrs_setdisclaim` spawn attribute, then macOS
/// treats the applesauce binary as the responsible process.
///
/// Pattern credit: high5 ventures, apple-reminders-mcp (MIT).
/// This must run before anything reads stdin. If the private symbol is missing,
/// applesauce continues without it.
enum TCCBootstrap {
    private static let marker = "APPLESAUCE_DISCLAIMED"

    static func disclaimIfNeeded() {
        if getenv(marker) != nil {
            // Already started again. Do not pass the marker to child processes.
            unsetenv(marker)
            return
        }
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"),
            let path = executablePath
        else { return }

        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        guard setDisclaim(&attributes, 1) == 0,
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0
        else { return }

        setenv(marker, "1", 1)
        var pid: pid_t = 0
        // With POSIX_SPAWN_SETEXEC this call only returns when it fails.
        _ = posix_spawn(&pid, path, nil, &attributes, CommandLine.unsafeArgv, environ)
        unsetenv(marker)
    }

    /// Absolute path of this binary, with symlinks resolved.
    static var executablePath: String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else {
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
