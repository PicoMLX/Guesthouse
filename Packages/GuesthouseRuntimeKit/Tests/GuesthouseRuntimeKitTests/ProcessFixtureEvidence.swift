import Testing
@testable import GuesthouseRuntimeKit

/// Test-only evidence. Inspect the typed Result without throwing away timing/flags on failure.
struct ProcessFixtureEvidence {
    let report: ProcessReport
    let runReturn: Duration
    let reportWait: Duration

    var succeeded: Bool {
        report.childExit == .success(.status(0)) && !report.timedOut && !report.canceled
    }

    var comment: Comment {
        "ACL fixture run return=\(runReturn); report wait=\(reportWait); exit=\(report.childExit); timedOut=\(report.timedOut); canceled=\(report.canceled); terminationRefused=\(report.terminationRefused); inputClosed=\(report.inputClosed); outputComplete=\(report.outputComplete)"
    }
}

@Suite struct ProcessFixtureEvidenceTests {
    @Test(arguments: [false, true], [false, true])
    func preservesEveryExitOutcome(timedOut: Bool, canceled: Bool) {
        let outcomes: [(Result<OwnedChild.ExitReason, OwnedChild.Failure>?, Bool)] = [
            (nil, false), (.success(.status(0)), true), (.success(.status(7)), false),
            (.success(.signal(15)), false), (.failure(.waitAuthorityLost(10)), false),
        ]
        for (outcome, zeroExit) in outcomes {
            let report = ProcessReport(childExit: outcome, timedOut: timedOut, canceled: canceled,
                terminationRefused: false, input: nil, inputClosed: true, outputComplete: true)
            let evidence = ProcessFixtureEvidence(report: report, runReturn: .seconds(1), reportWait: .seconds(2))
            #expect(evidence.succeeded == (zeroExit && !timedOut && !canceled))
            let expected: Comment = "ACL fixture run return=\(Duration.seconds(1)); report wait=\(Duration.seconds(2)); exit=\(outcome); timedOut=\(timedOut); canceled=\(canceled); terminationRefused=\(false); inputClosed=\(true); outputComplete=\(true)"
            #expect(evidence.comment.rawValue == expected.rawValue)
        }
    }
}
