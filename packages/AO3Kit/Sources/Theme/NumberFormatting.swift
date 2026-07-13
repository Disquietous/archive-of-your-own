import Foundation

extension Int {
    var abbreviated: String {
        if self >= 10000 {
            return "\(self / 1000)k"
        } else if self >= 1000 {
            let k = Double(self) / 1000.0
            let formatted = String(format: "%.1f", k)
            return formatted.hasSuffix(".0") ? "\(self / 1000)k" : "\(formatted)k"
        }
        return "\(self)"
    }
}
