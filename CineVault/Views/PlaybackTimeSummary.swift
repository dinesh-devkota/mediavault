import Foundation

enum PlaybackTimeSummary {
    /// Prefer the duration measured from this file; metadata is only a fallback.
    static func remaining(duration: Double, runtimeMinutes: Int?, position: Double) -> String? {
        let total: Double
        if duration.isFinite && duration > 0 {
            total = duration
        } else if let runtimeMinutes, runtimeMinutes > 0 {
            total = Double(runtimeMinutes) * 60
        } else {
            return nil
        }
        guard position.isFinite, position >= 0, position < total else { return nil }
        let seconds = total - position
        if seconds < 60 { return "Less than a minute left" }
        // Ceil before converting so 61 seconds never promises only one minute.
        let minutes = ceil(seconds / 60)
        guard minutes < Double(Int.max) else { return nil }
        let count = Int(minutes)
        let hours = count / 60
        let remainder = count % 60
        let durationText = hours == 0 ? "\(count) min" :
            remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        return "About \(durationText) left"
    }
}
