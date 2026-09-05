import Foundation

// A test fixture that stands in for a long-running VM process: it accepts any arguments,
// never touches them (so an arguments digest taken at launch still matches later; `yes`,
// for example, rewrites its argv), and ends on SIGTERM like Tart does.
while true {
    sleep(3600)
}
