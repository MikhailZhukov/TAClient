import Foundation
import Darwin.Mach

/// Process-level memory diagnostics for the `[Mem]` log markers used by the
/// video cache + playback subsystems. Reads `mach_task_basic_info`
/// synchronously — safe from any thread, no actor hop.
///
/// Marker is PERMANENT (not part of the v0.9.1 diagnostic-cleanup bucket).
/// See `docs/plans/20260527-fix-memory-pressure-recovery.md` for context.
enum MemoryDiagnostics {

    /// Returns the process's current resident memory in bytes. Reads
    /// `mach_task_basic_info` synchronously — safe from any thread.
    /// Returns 0 on `task_info` failure (defensive; we'd rather log a
    /// zero than crash).
    nonisolated static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// Formatted MB string for logging: "1234MB".
    nonisolated static func residentMBString() -> String {
        "\(residentBytes() / 1_000_000)MB"
    }
}
