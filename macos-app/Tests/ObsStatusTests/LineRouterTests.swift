import XCTest

@testable import ObsStatus

/// Regression tests for the LineRouter and LineSplitter, the two most
/// concurrency-sensitive parts of USBCDCService: the splitter turns a raw
/// byte stream into lines, and the router decides what each line means
/// (event broadcast, pending-command completion, or log noise to drop).
final class LineRouterTests: XCTestCase {

    // MARK: - LineRouter

    private func makeRouter() -> LineRouter {
        let router = LineRouter()
        router.restart()
        return router
    }

    /// Arms a pending command and resolves to the line (or error) that
    /// completes it. `static` (no instance state) so the `Task` closures
    /// below can call it without capturing the non-Sendable test-case self.
    private static func pendingResult(
        _ router: LineRouter,
        id: UUID
    ) async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            router.registerPending(id: id, continuation: continuation)
        }
    }

    /// Polls `hasPending` briefly so tests can wait for a command to arm
    /// without racing the registration task.
    private func waitForPending(_ router: LineRouter) async {
        for _ in 0..<1000 {
            if router.hasPending { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Router never had a pending command")
    }

    func testEventLinesReachEventSubscribers() async {
        let router = makeRouter()
        var iterator = router.eventStream().makeAsyncIterator()
        router.handleLine("EVENT:TOGGLE_PAUSE")
        let line = await iterator.next()
        XCTAssertEqual(line, "EVENT:TOGGLE_PAUSE")
    }

    func testEventLinesDoNotCompleteAPendingCommand() async {
        let router = makeRouter()
        let id = UUID()
        let response = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        router.handleLine("EVENT:TOGGLE_PAUSE")
        router.handleLine("OK")
        let result = await response.value
        XCTAssertEqual(result, "OK")
    }

    func testResponseArrivingBeforePendingIsStashed() async {
        let router = makeRouter()
        router.handleLine("OK")  // no pending command: must be stashed
        let result = try? await Self.pendingResult(router, id: UUID())
        XCTAssertEqual(result, "OK")
    }

    func testPendingCompletesWithTheNextWellFormedResponse() async {
        let router = makeRouter()
        let id = UUID()
        let response = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        let line = "STATUS:LED=1,POWER=ON,ORIENTATION=UP,SCENE=Live|AUTH=1"
        router.handleLine(line)
        let result = await response.value
        XCTAssertEqual(result, line)
    }

    func testFirmwareLogLinesAreDroppedInsteadOfMisdelivered() async {
        let router = makeRouter()
        let id = UUID()
        let response = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        router.handleLine("I (1234) app: Tap detected - toggling record pause")
        let stillArmed = router.hasPending
        XCTAssertTrue(stillArmed)  // the log line was dropped
        router.handleLine("OK")
        let result = await response.value
        XCTAssertEqual(result, "OK")
    }

    func testStaleResponseIsDiscardedBeforeTheNextCommand() async {
        let router = makeRouter()
        router.handleLine("OK")  // stashed
        router.discardStaleResponse()
        let id = UUID()
        let response = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        let stillArmed = router.hasPending
        XCTAssertTrue(stillArmed)  // the stale response was dropped
        router.handleLine("OK")
        let result = await response.value
        XCTAssertEqual(result, "OK")
    }

    func testTimeoutFailsTheMatchingPendingCommand() async {
        let router = makeRouter()
        let id = UUID()
        let outcome = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        router.timeout(id: id)
        _ = await outcome.value
        let hasPending = router.hasPending
        XCTAssertFalse(hasPending)
    }

    func testTimeoutWithAnotherIDLeavesThePendingCommand() async {
        let router = makeRouter()
        let id = UUID()
        let outcome = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        router.timeout(id: UUID())  // a different command timed out
        let stillArmed = router.hasPending
        XCTAssertTrue(stillArmed)
        router.timeout(id: id)
        _ = await outcome.value
        let hasPending = router.hasPending
        XCTAssertFalse(hasPending)
    }

    func testStopFailsPendingAndRejectsNewCommands() async {
        let router = makeRouter()
        let id = UUID()
        let outcome = Task { try? await Self.pendingResult(router, id: id) }
        await waitForPending(router)
        router.stop()
        _ = await outcome.value
        let hasPending = router.hasPending
        XCTAssertFalse(hasPending)
        do {
            // Only the throw matters (a success would mean stop() was ignored);
            // discard the result explicitly to silence the unused-result warning.
            _ = try await Self.pendingResult(router, id: UUID())
            XCTFail("Expected notConnected to be thrown")
        } catch {
            guard case USBCDCError.notConnected = error else {
                return XCTFail("Expected notConnected, got \(error)")
            }
        }
    }

    /// A pending command that survives to restart() must be failed and
    /// cleared: otherwise its armed slot would reject every new command of
    /// the restarted session (notConnected) and its continuation would hang.
    func testRestartFailsAndClearsAStalePendingCommand() async {
        let router = makeRouter()
        let id = UUID()
        let stale = Task { () -> String? in
            do {
                return try await Self.pendingResult(router, id: id)
            } catch {
                guard case USBCDCError.notConnected = error else {
                    return "unexpected: \(error)"
                }
                return nil
            }
        }
        await waitForPending(router)
        router.restart()
        let result = await stale.value
        XCTAssertNil(result, "The stale pending must fail with notConnected, got \(result ?? "OK")")
        XCTAssertFalse(router.hasPending, "The pending slot must be cleared by restart()")
        // And a new command may arm freely after the restart.
        let newOutcome = Task { try? await Self.pendingResult(router, id: UUID()) }
        await waitForPending(router)
        router.handleLine("OK")
        let newResult = await newOutcome.value
        XCTAssertEqual(newResult, "OK")
    }

    func testRestartClearsStashAndAllowsNewSessions() async {
        let router = makeRouter()
        router.handleLine("OK")  // stashed
        router.stop()
        router.restart()
        // The stashed response from the previous session must not be handed
        // to a command of the new one.
        let response = Task { try? await Self.pendingResult(router, id: UUID()) }
        await waitForPending(router)
        router.handleLine("OK")
        let result = await response.value
        XCTAssertEqual(result, "OK")
    }

    // MARK: - LineSplitter

    func testSplitterBuffersUntilNewline() {
        var splitter = LineSplitter()
        var lines = splitter.feed(Array("STAT".utf8))
        lines += splitter.feed(Array("US:LED".utf8))
        lines += splitter.feed(Array("=1\n".utf8))
        XCTAssertEqual(lines, ["STATUS:LED=1"])
    }

    func testSplitterHandlesCRLFAndSkipsBareCR() {
        var splitter = LineSplitter()
        // Carriage returns are skipped (not line terminators): the firmware
        // only sends LF, and the original reader loop had this behavior.
        let lines = splitter.feed(Array("OK\r\nA\rB\n".utf8))
        XCTAssertEqual(lines, ["OK", "AB"])
    }

    func testSplitterDiscardsOversizedLines() {
        var splitter = LineSplitter(maxLineBytes: 8)
        // Bytes 1-8 fill the buffer, byte 9 overflows and is dropped, the
        // buffer restarts, ... the surviving tail after the last overflow is
        // "xx", so the line is "xxOK" (the host drops such log fragments).
        let lines = splitter.feed(
            Array((String(repeating: "x", count: 20) + "OK\n").utf8)
        )
        XCTAssertEqual(lines, ["xxOK"])
    }

    func testSplitterKeepsPartialLineAfterOverflow() {
        var splitter = LineSplitter(maxLineBytes: 8)
        let overflowed = splitter.feed(Array(String(repeating: "x", count: 20).utf8))
        XCTAssertEqual(overflowed, [])  // no newline yet
        let lines = splitter.feed(Array("OK\n".utf8))
        XCTAssertEqual(lines, ["xxOK"])
    }

    // MARK: - Response/event classification

    func testResponseClassification() {
        XCTAssertTrue(ObsResponse.isResponse("OK"))
        XCTAssertTrue(ObsResponse.isResponse("ERROR: UNKNOWN_COMMAND"))
        XCTAssertTrue(ObsResponse.isResponse("STATUS:LED=1"))
        XCTAssertFalse(ObsResponse.isResponse("I (1234) app: boot log"))
        XCTAssertFalse(ObsResponse.isResponse("EVENT:TOGGLE_PAUSE"))
        XCTAssertTrue(ObsResponse.isErrorResponse("ERROR: AUTH_FAILED"))
        XCTAssertFalse(ObsResponse.isErrorResponse("OK"))
    }

    func testEventParsing() {
        XCTAssertEqual(ObsEvent.parse("EVENT:TOGGLE_PAUSE"), .togglePause)
        XCTAssertNil(ObsEvent.parse("OK"))
        XCTAssertNil(ObsEvent.parse("EVENT:UNKNOWN_THING"))
    }
}
