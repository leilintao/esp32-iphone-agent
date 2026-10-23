import Foundation

/// Independent checks, not fitting samples. Include the lower keypad and both sides of the screen.
struct CalibrationValidation {
    static let version = 2  // orthogonal-motion firmware requires a new mapping, not a legacy verified span
    static let tolerance = 0.015
    static let targets = [CGPoint(x: 0.5, y: 0.62), CGPoint(x: 0.15, y: 0.78),
                          CGPoint(x: 0.85, y: 0.78), CGPoint(x: 0.5, y: 0.3)]
    static var checkCount: Int { targets.count * 2 }  // from home, then relative moves

    private(set) var count = 0
    private(set) var worstError = 0.0
    private(set) var problem: String?

    mutating func record(target: CGPoint, actual: CGPoint?) -> Bool {
        guard problem == nil, count < Self.checkCount else { return false }
        guard let actual, actual.x.isFinite, actual.y.isFinite else {
            problem = "Calibration check did not receive a valid touch."
            return false
        }
        let error = max(abs(actual.x - target.x), abs(actual.y - target.y))
        worstError = max(worstError, error)
        count += 1
        guard error <= Self.tolerance else {
            problem = String(format: "Calibration check at (%.2f, %.2f) missed by %.1f%%; limit %.1f%%.",
                             target.x, target.y, error * 100, Self.tolerance * 100)
            return false
        }
        return true
    }

    var accepted: Bool { problem == nil && count == Self.checkCount && worstError <= Self.tolerance }
}
