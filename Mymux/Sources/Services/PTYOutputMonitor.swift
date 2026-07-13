import Foundation

final class PTYOutputMonitor {
    private let ringBuffer = RingBuffer(capacity: 4096)
    private var lastOutputTimestamp: Date = Date()
    private var currentStatus: DisplayStatus = .active
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.mymux.ptymonitor")
    private var isTerminated = false

    var onStatusChanged: ((DisplayStatus) -> Void)?

    private static let promptPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^>\s*$"#, options: .anchorsMatchLines),
        try! NSRegularExpression(pattern: #"^❯\s*$"#, options: .anchorsMatchLines),
        try! NSRegularExpression(pattern: #"^\$\s*$"#, options: .anchorsMatchLines),
        try! NSRegularExpression(pattern: #"\(y/n\)"#),
        try! NSRegularExpression(pattern: #"\[Y/n\]"#),
        try! NSRegularExpression(pattern: #"Do you want to"#),
        try! NSRegularExpression(pattern: #"Allow .+\?"#),
        try! NSRegularExpression(pattern: #"Press Enter"#),
    ]

    init() {
        start()
    }

    func dataReceived(_ slice: ArraySlice<UInt8>) {
        timerQueue.async { [weak self] in
            guard let self = self, !self.isTerminated else { return }
            self.ringBuffer.write(slice)
            self.lastOutputTimestamp = Date()
            self.transition(to: .active)
        }
    }

    func processTerminated() {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            self.isTerminated = true
            self.timer?.cancel()
            self.timer = nil
            self.transition(to: .suspended)
        }
    }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.evaluateState() }
        t.resume()
        self.timer = t
    }

    private func evaluateState() {
        guard !isTerminated else { return }
        let silence = Date().timeIntervalSince(lastOutputTimestamp)

        if silence < 1.0 {
            // already active — no-op
        } else if silence < 3.0 {
            transition(to: .thinking)
        } else {
            // check prompt patterns
            let lastBytes = ringBuffer.lastBytes(512)
            let text = ANSIStripper.strip(bytes: lastBytes)
            if matchesPromptPattern(text) {
                transition(to: .waiting)
            } else {
                transition(to: .thinking)
            }
        }
    }

    private func matchesPromptPattern(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in Self.promptPatterns {
            if pattern.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    private func transition(to newStatus: DisplayStatus) {
        guard newStatus != currentStatus else { return }
        currentStatus = newStatus
        let cb = onStatusChanged
        DispatchQueue.main.async {
            cb?(newStatus)
        }
    }

    deinit {
        timer?.cancel()
    }
}
