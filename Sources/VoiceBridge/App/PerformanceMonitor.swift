import Foundation

/// Lightweight process CPU-usage sampler for the CPU display. GPU utilization
/// on Apple Silicon is not exposed through a simple public API; the UI shows it
/// as "n/a" honestly rather than faking a number. If you need real GPU load,
/// sample it via a Metal counter set or IOReport in a later phase.
@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double = 0

    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.cpuPercent = Self.processCPUUsage()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Sum of per-thread CPU usage for this process (0…100 × cores).
    static func processCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(threads))),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT is a C macro Swift doesn't import; compute it.
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }
}
