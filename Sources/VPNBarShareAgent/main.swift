import Foundation
import Darwin

// The connector must not outlive the app, including an app crash or SIGKILL.
nonisolated(unsafe) var stopping: Int32 = 0
signal(SIGTERM) { _ in stopping = 1 }
signal(SIGINT) { _ in stopping = 1 }
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let parent = Int32(args[0]), parent == getppid() else { exit(1) }
let child = Process()
child.executableURL = URL(fileURLWithPath: args[1]); child.arguments = Array(args.dropFirst(2))
child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
do { try child.run() } catch { FileHandle.standardError.write(Data("Impossibile avviare cloudflared.\n".utf8)); exit(1) }
while child.isRunning && stopping == 0 && getppid() == parent { usleep(100000) }
if child.isRunning {
    child.terminate()
    let deadline = Date().addingTimeInterval(3)
    while child.isRunning && Date() < deadline { usleep(50000) }
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
}
child.waitUntilExit()
exit(child.terminationStatus)
