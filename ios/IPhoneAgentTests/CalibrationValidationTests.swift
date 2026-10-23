import XCTest
@testable import IPhoneAgent

final class CalibrationValidationTests: XCTestCase {
    func testBothHomeAndRelativeChecksAreRequired() {
        var v = CalibrationValidation()
        for target in CalibrationValidation.targets {
            XCTAssertTrue(v.record(target: target, actual: target))
        }
        XCTAssertFalse(v.accepted, "a check from home alone does not exercise relative movements")
        for target in CalibrationValidation.targets.reversed() {
            XCTAssertTrue(v.record(target: target, actual: target))
        }
        XCTAssertTrue(v.accepted)
    }

    func testObservedLowerKeypadMissRejectsGoodCentreCheck() {
        var v = CalibrationValidation()
        XCTAssertTrue(v.record(target: CGPoint(x: 0.5, y: 0.62), actual: CGPoint(x: 0.506, y: 0.618)))
        XCTAssertFalse(v.record(target: CGPoint(x: 0.15, y: 0.78), actual: CGPoint(x: 0.15, y: 0.74)))
        XCTAssertFalse(v.accepted)
        XCTAssertEqual(v.worstError, 0.04, accuracy: 1e-9)
        XCTAssertNotNil(v.problem)
    }

    func testMissingCheckCannotFallBackToFitResidual() {
        var v = CalibrationValidation()
        XCTAssertFalse(v.record(target: CalibrationValidation.targets[0], actual: nil))
        for target in CalibrationValidation.targets {
            XCTAssertFalse(v.record(target: target, actual: target), "a failed check cannot be repaired by later checks")
        }
        XCTAssertFalse(v.accepted)
    }

    func testRelativeMoveFailureRejectsOtherwiseGoodCalibration() {
        var v = CalibrationValidation()
        for target in CalibrationValidation.targets { XCTAssertTrue(v.record(target: target, actual: target)) }
        let target = CalibrationValidation.targets.last!
        XCTAssertFalse(v.record(target: target, actual: CGPoint(x: target.x + 0.03, y: target.y)))
        XCTAssertFalse(v.accepted)
    }

    func testWorstErrorNotLastErrorIsReported() {
        var v = CalibrationValidation()
        let targets = CalibrationValidation.targets + CalibrationValidation.targets.reversed()
        for (i, target) in targets.enumerated() {
            XCTAssertTrue(v.record(target: target, actual: CGPoint(x: target.x, y: target.y + (i == 0 ? 0.012 : 0.001))))
        }
        XCTAssertTrue(v.accepted)
        XCTAssertEqual(v.worstError, 0.012, accuracy: 1e-9)
    }

    func testNonFiniteTouchIsRejected() {
        for value in [Double.nan, .infinity, -.infinity] {
            var v = CalibrationValidation()
            XCTAssertFalse(v.record(target: CGPoint(x: 0, y: 0), actual: CGPoint(x: value, y: 0)))
            XCTAssertFalse(v.accepted)
        }
    }
}

@MainActor final class CalibrationPersistenceTests: XCTestCase {
    private func makePointer(_ file: URL) -> Pointer { Pointer(device: FakeDevice(), calibrationFile: file) }

    func testDiagonalFirmwareVerificationDoesNotAuthorizeOrthogonalFirmware() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"w":773,"h":1644,"quality":0.008,"verificationVersion":1}"#.utf8).write(to: file)
        XCTAssertTrue(makePointer(file).calibrated)
        XCTAssertFalse(makePointer(file).verified)
    }

    func testOldSavedCalibrationDoesNotAuthorizeNewRuns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"w":524,"h":1204,"quality":0.003,"aspect":0.46}"#.utf8).write(to: file)
        let pointer = makePointer(file)
        XCTAssertTrue(pointer.calibrated, "retain the old mapping as a candidate")
        XCTAssertFalse(pointer.verified, "old single-point success is not multi-point validation")
    }

    func testVerifiedMappingPersistsButCancelledAttemptRevokesIt() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = makePointer(file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertFalse(pointer.verified)
        pointer.acceptVerification(0.006)
        XCTAssertTrue(makePointer(file).verified)
        pointer.invalidateVerification()
        XCTAssertFalse(makePointer(file).verified)
        XCTAssertTrue(makePointer(file).calibrated)
    }

    func testBadQualityCannotAuthorizeCalibration() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = makePointer(file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        for error in [0.04, Double.nan, .infinity, -0.01] {
            pointer.acceptVerification(0.006)
            pointer.acceptVerification(error)
            XCTAssertFalse(pointer.verified)
        }
    }

    func testProbeOffsetsAreBaselineNotPostCalibrationDrift() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = makePointer(file)
        let samples = [100.0, 200, 300].map { u in
            (ux: u, uy: u, fx: 0.049 + u / 523, fy: 0.055 + u / 1368)
        }
        pointer.applyProbe(x: .init(a: 1.0 / 523, b: 0.049, rms: 0),
                           y: .init(a: 1.0 / 1368, b: 0.055, rms: 0), samples: samples)
        XCTAssertNotEqual(pointer.fix(0.5, "y"), 0.5)
        XCTAssertEqual(pointer.drift, 0, accuracy: 1e-9)
        XCTAssertEqual(makePointer(file).drift, 0, accuracy: 1e-9)
        XCTAssertFalse(pointer.verified)
    }
}
