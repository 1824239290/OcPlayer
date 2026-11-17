import AppDesignKit
import XCTest
@testable import OcPlayer

@MainActor
final class DetailBackdropArtworkTests: XCTestCase {
    private let home = BackdropSourceLatch.Target(url: URL(string: "https://images.test/home")!, authHeader: "home-auth")
    private let detail = BackdropSourceLatch.Target(url: URL(string: "https://images.test/detail")!, authHeader: "detail-auth")

    private func image() -> PlatformImage {
        #if os(macOS)
        PlatformImage(size: CGSize(width: 2, height: 2))
        #else
        PlatformImage()
        #endif
    }

    func testEntryCapturesPixelsOnceAndSurvivesPoolChangeAndEviction() {
        let pixels = image()
        var cached: PlatformImage? = pixels
        var reads = 0
        let artwork = DetailBackdropArtwork(cachedImage: { url, auth, _, size in
            reads += 1
            XCTAssertEqual(url, self.home.url)
            XCTAssertEqual(auth, self.home.authHeader)
            XCTAssertEqual(size, DetailAmbienceImage.decodePixels)
            return cached
        })
        artwork.captureEntry(target: home)
        cached = nil
        artwork.captureEntry(target: detail)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(artwork.entry?.target, home)
        XCTAssertTrue(artwork.entry?.image === pixels)
    }

    func testMissingEntryDoesNotFollowLaterPoolWarmup() {
        var cached: PlatformImage?
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in cached })
        artwork.captureEntry(target: home)
        cached = image()
        artwork.captureEntry(target: detail)
        XCTAssertNil(artwork.entry)
    }

    func testContentIsCommittedOnlyAfterDecodeAndRepeatedPrepareSharesLoad() async throws {
        let entryPixels = image()
        let detailPixels = image()
        let gate = LoadGate()
        let started = expectation(description: "detail decode started")
        gate.started[detail.url!] = started
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, size in
            size == DetailAmbienceImage.decodePixels ? entryPixels : nil
        }, loader: gate.load)
        artwork.captureEntry(target: home)
        let first = try XCTUnwrap(artwork.prepare(target: detail))
        await fulfillment(of: [started], timeout: 2)
        let repeated = try XCTUnwrap(artwork.prepare(target: detail))
        XCTAssertNil(artwork.content, "A URL alone must not replace the visible entry pixels")
        XCTAssertTrue(artwork.entry?.image === entryPixels)
        XCTAssertEqual(gate.requests.count, 1)
        XCTAssertEqual(gate.requests.first?.auth, detail.authHeader)
        XCTAssertEqual(gate.requests.first?.size, DetailAmbienceImage.artDecodePixels)
        gate.finish(detail.url!, with: detailPixels)
        await first.value
        await repeated.value
        XCTAssertEqual(artwork.content?.target, detail)
        XCTAssertTrue(artwork.content?.image === detailPixels)
        XCTAssertTrue(artwork.entry?.image === entryPixels)
    }

    func testCachedContentCommitsWithoutAnotherRequest() {
        let pixels = image()
        var loads = 0
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in pixels }, loader: { _, _, _, _ in
            loads += 1
            return nil
        })
        XCTAssertNil(artwork.prepare(target: detail))
        XCTAssertTrue(artwork.content?.image === pixels)
        XCTAssertEqual(loads, 0)
    }

    func testFailedLoadKeepsEntryAndDoesNotPublishPlaceholder() async throws {
        enum Failure: Error { case decode }
        let pixels = image()
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, size in
            size == DetailAmbienceImage.decodePixels ? pixels : nil
        }, loader: { _, _, _, _ in throw Failure.decode })
        artwork.captureEntry(target: home)
        let task = try XCTUnwrap(artwork.prepare(target: detail))
        await task.value
        XCTAssertNil(artwork.content)
        XCTAssertTrue(artwork.entry?.image === pixels)
    }

    func testLateCanceledLoadCannotOverwriteNewContent() async throws {
        let gate = LoadGate()
        let oldStarted = expectation(description: "old load")
        let newStarted = expectation(description: "new load")
        gate.started[home.url!] = oldStarted
        gate.started[detail.url!] = newStarted
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in nil }, loader: gate.load)
        let oldTask = try XCTUnwrap(artwork.prepare(target: home))
        await fulfillment(of: [oldStarted], timeout: 2)
        let newTask = try XCTUnwrap(artwork.prepare(target: detail))
        await fulfillment(of: [newStarted], timeout: 2)
        let newPixels = image()
        gate.finish(detail.url!, with: newPixels)
        await newTask.value
        // This loader deliberately ignores cancellation and returns old pixels late.
        gate.finish(home.url!, with: image())
        await oldTask.value
        XCTAssertEqual(artwork.content?.target, detail)
        XCTAssertTrue(artwork.content?.image === newPixels)
    }

    func testDisappearCancellationAllowsSameTargetToRestart() async throws {
        let gate = LoadGate()
        let started = expectation(description: "first visit")
        gate.started[detail.url!] = started
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in nil }, loader: gate.load)
        let first = try XCTUnwrap(artwork.prepare(target: detail))
        await fulfillment(of: [started], timeout: 2)
        artwork.cancel()
        gate.finish(detail.url!, with: image())
        await first.value
        XCTAssertNil(artwork.content)
        let restarted = expectation(description: "return visit")
        gate.started[detail.url!] = restarted
        let second = try XCTUnwrap(artwork.prepare(target: detail))
        await fulfillment(of: [restarted], timeout: 2)
        let pixels = image()
        gate.finish(detail.url!, with: pixels)
        await second.value
        XCTAssertEqual(gate.requests.count, 2)
        XCTAssertTrue(artwork.content?.image === pixels)
    }

    func testAbsentTargetDoesNotLoad() {
        var reads = 0
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in reads += 1; return nil })
        XCTAssertNil(artwork.prepare(target: .init(url: nil, authHeader: nil)))
        XCTAssertEqual(reads, 0)
        XCTAssertNil(artwork.content)
    }

    func testCanceledCallerCannotRestartPreparationOrCommitCachedPixels() async {
        let pixels = image()
        var reads = 0
        let artwork = DetailBackdropArtwork(cachedImage: { _, _, _, _ in
            reads += 1
            return pixels
        })
        let ready = expectation(description: "caller suspended")
        var continuation: CheckedContinuation<Void, Never>?
        let caller = Task {
            await withCheckedContinuation { continuation = $0; ready.fulfill() }
            XCTAssertNil(artwork.prepare(target: detail))
        }
        await fulfillment(of: [ready], timeout: 2)
        caller.cancel()
        continuation?.resume()
        await caller.value
        XCTAssertEqual(reads, 0, "A canceled page task must not restart image preparation")
        XCTAssertNil(artwork.content)
    }

    @MainActor private final class LoadGate {
        struct Request { let auth: String?; let size: Int }
        var started: [URL: XCTestExpectation] = [:]
        var requests: [Request] = []
        private var pending: [URL: CheckedContinuation<PlatformImage?, Error>] = [:]

        func load(_ url: URL, _ auth: String?, _ scope: String?, _ size: Int) async throws -> PlatformImage? {
            requests.append(Request(auth: auth, size: size))
            return try await withCheckedThrowingContinuation { continuation in
                pending[url] = continuation
                started[url]?.fulfill()
            }
        }
        func finish(_ url: URL, with image: PlatformImage) {
            pending.removeValue(forKey: url)?.resume(returning: image)
        }
    }
}
