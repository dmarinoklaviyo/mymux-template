import Foundation

final class RingBuffer {
    private var buffer: [UInt8]
    private var writeIndex: Int = 0
    private var count: Int = 0
    let capacity: Int

    init(capacity: Int = 4096) {
        self.capacity = capacity
        self.buffer = [UInt8](repeating: 0, count: capacity)
    }

    func write(_ data: ArraySlice<UInt8>) {
        for byte in data {
            buffer[writeIndex] = byte
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    func lastBytes(_ n: Int) -> [UInt8] {
        let bytesToRead = min(n, count)
        guard bytesToRead > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: bytesToRead)
        let startIndex = (writeIndex - bytesToRead + capacity) % capacity
        for i in 0..<bytesToRead {
            result[i] = buffer[(startIndex + i) % capacity]
        }
        return result
    }
}
