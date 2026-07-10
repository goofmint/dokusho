import Foundation
import Testing

@testable import KomgaKit

@Suite("Pages / download / thumbnail / progress")
struct ClientPageProgressTests {
    @Test("pages hits books/{id}/pages and decodes")
    func pages() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("pages")) }
        let pages = try await harness.client.pages(bookID: "0BOOK0001")
        #expect(pages.count == 2)
        #expect(pages[0].number == 1)
        #expect(harness.lastRequest?.url?.path == "/api/v1/books/0BOOK0001/pages")
    }

    @Test("pageImageRequest uses 1-based path and no convert by default")
    func pageImageNoConvert() throws {
        let config = try TestConfig.make()
        let client = KomgaClient(config: config)
        let request = try client.pageImageRequest(bookID: "0BOOK0001", page: 1, convert: nil)
        #expect(request.url?.path == "/api/v1/books/0BOOK0001/pages/1")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == TestConfig.apiKey)
    }

    // Sending Accept: application/json to image/file endpoints makes Komga's
    // content negotiation answer 406, so these must ask for the right types.
    @Test("image and file requests send a non-JSON Accept header")
    func binaryAcceptHeaders() throws {
        let client = KomgaClient(config: try TestConfig.make())
        let page = try client.pageImageRequest(bookID: "b", page: 1, convert: nil)
        #expect(page.value(forHTTPHeaderField: "Accept") == "image/*")
        let thumb = try client.thumbnailRequest(for: .series(id: "s1"))
        #expect(thumb.value(forHTTPHeaderField: "Accept") == "image/*")
        let file = try client.fileDownloadRequest(bookID: "b")
        #expect(file.value(forHTTPHeaderField: "Accept") == "*/*")
    }

    @Test("pageImageRequest adds convert=jpeg")
    func pageImageConvertJpeg() throws {
        let client = KomgaClient(config: try TestConfig.make())
        let request = try client.pageImageRequest(bookID: "b", page: 5, convert: .jpeg)
        #expect(request.url?.path == "/api/v1/books/b/pages/5")
        #expect(queryDictionary(request)["convert"] == "jpeg")
    }

    @Test("pageImageRequest adds convert=png")
    func pageImageConvertPng() throws {
        let client = KomgaClient(config: try TestConfig.make())
        let request = try client.pageImageRequest(bookID: "b", page: 5, convert: .png)
        #expect(queryDictionary(request)["convert"] == "png")
    }

    @Test("fileDownloadRequest hits books/{id}/file with API key")
    func fileDownload() throws {
        let client = KomgaClient(config: try TestConfig.make())
        let request = try client.fileDownloadRequest(bookID: "0BOOK0001")
        #expect(request.url?.path == "/api/v1/books/0BOOK0001/file")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == TestConfig.apiKey)
    }

    @Test(
        "thumbnailRequest maps every target",
        arguments: [
            (ThumbnailTarget.book(id: "b1"), "/api/v1/books/b1/thumbnail"),
            (ThumbnailTarget.series(id: "s1"), "/api/v1/series/s1/thumbnail"),
            (ThumbnailTarget.collection(id: "c1"), "/api/v1/collections/c1/thumbnail"),
            (ThumbnailTarget.readList(id: "r1"), "/api/v1/readlists/r1/thumbnail"),
        ]
    )
    func thumbnails(target: ThumbnailTarget, expectedPath: String) throws {
        let client = KomgaClient(config: try TestConfig.make())
        let request = try client.thumbnailRequest(for: target)
        #expect(request.url?.path == expectedPath)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == TestConfig.apiKey)
    }

    @Test("updateReadProgress PATCHes with page + completed body")
    func updateProgressBoth() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 204) }
        try await harness.client.updateReadProgress(
            bookID: "0BOOK0001", page: 42, completed: false
        )
        let request = try #require(harness.lastRequest)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/v1/books/0BOOK0001/read-progress")

        let body = try #require(bodyData(request))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["page"] as? Int == 42)
        #expect(json?["completed"] as? Bool == false)
    }

    @Test("updateReadProgress omits nil fields")
    func updateProgressCompletedOnly() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 204) }
        try await harness.client.updateReadProgress(bookID: "b", page: nil, completed: true)
        let request = try #require(harness.lastRequest)
        let body = try #require(bodyData(request))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["completed"] as? Bool == true)
        #expect(json?["page"] == nil)
    }

    @Test("updateReadProgress surfaces server errors")
    func updateProgressError() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 403) }
        await #expect(throws: KomgaError.forbidden) {
            try await harness.client.updateReadProgress(bookID: "b", page: 1, completed: nil)
        }
    }
}

/// Reads the body from a captured request. `URLProtocol` may deliver the body
/// via `httpBodyStream` rather than `httpBody`, so handle both.
private func bodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
