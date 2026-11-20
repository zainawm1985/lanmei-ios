import Foundation
import AVFoundation
import Photos
import UIKit

extension Notification.Name {
    static let zzDownloadsChanged = Notification.Name("zz.downloads.changed")
}

enum DLState: Int {
    case waiting = 0
    case running = 1
    case done = 2
    case failed = 3
    case cancelled = 4
}

final class DownloadItem {
    let id: String
    let url: String
    var title: String
    var state: DLState = .waiting
    var progress: Int = 0
    var result: String?
    var error: String?

    init(url: String, title: String) {
        self.id = String(Int(Date().timeIntervalSince1970)) + "_" + String(Int.random(in: 100...999))
        self.url = url
        self.title = title
    }

    var finished: Bool { state == .done || state == .failed || state == .cancelled }
}

/// 下载引擎：m3u8 分片并行下载 -> 合并 -> 导出 mp4 -> 写入相册。
final class MediaDownloader: NSObject {

    static let shared = MediaDownloader()

    private let lock = NSLock()
    private(set) var items: [DownloadItem] = []
    private var queue: [DownloadItem] = []
    private var working = false
    private let workQueue = DispatchQueue(label: "zz.dl.work")

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: - 队列

    func snapshot() -> [DownloadItem] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func enqueue(url: String, title: String) -> DownloadItem {
        let item = DownloadItem(url: url, title: title)
        lock.lock()
        items.insert(item, at: 0)
        queue.append(item)
        lock.unlock()
        notify()
        pump()
        return item
    }

    func retry(_ item: DownloadItem) {
        lock.lock()
        guard item.finished else { lock.unlock(); return }
        item.state = .waiting
        item.progress = 0
        item.error = nil
        item.result = nil
        queue.append(item)
        lock.unlock()
        notify()
        pump()
    }

    func cancel(_ item: DownloadItem) {
        lock.lock()
        item.state = .cancelled
        lock.unlock()
        notify()
    }

    func remove(_ item: DownloadItem) {
        lock.lock()
        items.removeAll { $0 === item }
        lock.unlock()
        notify()
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .zzDownloadsChanged, object: nil)
        }
    }

    private func pump() {
        lock.lock()
        if working || queue.isEmpty { lock.unlock(); return }
        let next = queue.removeFirst()
        working = true
        lock.unlock()

        next.state = .running
        notify()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.run(next)
            self.lock.lock()
            self.working = false
            self.lock.unlock()
            self.notify()
            self.pump()
        }
    }

    // MARK: - 单任务

    private func run(_ item: DownloadItem) {
        do {
            let out = try self.download(item: item)
            if item.state == .cancelled { return }
            let saved = try self.saveToPhotos(file: out)
            item.result = saved
            item.progress = 100
            item.state = .done
        } catch {
            item.error = error.localizedDescription
            item.state = (item.state == .cancelled) ? .cancelled : .failed
        }
    }

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("zzdl", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func download(item: DownloadItem) throws -> URL {
        let lower = item.url.lowercased()
        let dir = tmpDir()
        if !lower.contains(".m3u8") {
            let out = dir.appendingPathComponent("video_\(item.id).mp4")
            try downloadDirect(item: item, to: out)
            return out
        }
        let referer = origin(of: item.url)
        let text = try fetchText(item.url, referer: referer)
        var (segments, variant) = parsePlaylist(text)
        var base = item.url
        if let v = variant {
            base = resolve(base: item.url, ref: v)
            (segments, _) = parsePlaylist(try fetchText(base, referer: referer))
        }
        guard !segments.isEmpty else { throw NSError(domain: "zz", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "m3u8 中没有分片"]) }

        let merged = dir.appendingPathComponent("merged_\(item.id).ts")
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let handle = try FileHandle(forWritingTo: merged)
        defer { try? handle.close() }

        let window = 8
        var index = 0
        var written = 0
        let total = segments.count
        while index < total {
            if item.state == .cancelled { throw NSError(domain: "zz", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "已取消"]) }
            let end = min(total, index + window)
            let group = DispatchGroup()
            var buffers = [Int: Data]()
            let bufLock = NSLock()
            for i in index..<end {
                group.enter()
                let segURL = resolve(base: base, ref: segments[i])
                fetchData(segURL, referer: referer) { data in
                    if let d = data {
                        bufLock.lock(); buffers[i] = d; bufLock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
            for i in index..<end {
                guard let d = buffers[i] else {
                    throw NSError(domain: "zz", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "分片下载失败"])
                }
                handle.write(d)
                written += 1
            }
            index = end
            item.progress = Int(Double(written) * 100.0 / Double(total))
            notify()
        }

        let mp4 = dir.appendingPathComponent("video_\(item.id).mp4")
        if let exported = try? export(ts: merged, to: mp4) {
            try? FileManager.default.removeItem(at: merged)
            return exported
        }
        return merged
    }

    private func export(ts: URL, to mp4: URL) throws -> URL {
        let asset = AVURLAsset(url: ts)
        try? FileManager.default.removeItem(at: mp4)

        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputURL = mp4
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true

            let sem = DispatchSemaphore(value: 0)
            session.exportAsynchronously { sem.signal() }
            sem.wait()

            if session.status == .completed, FileManager.default.fileExists(atPath: mp4.path) {
                return mp4
            }
        }
        throw NSError(domain: "zz", code: -4,
                      userInfo: [NSLocalizedDescriptionKey: "封装 mp4 失败"])
    }

    // MARK: - 网络

    private func request(_ url: String, referer: String?) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = 30
        r.setValue(MediaDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        if let ref = referer { r.setValue(ref, forHTTPHeaderField: "Referer") }
        return r
    }

    private func fetchText(_ url: String, referer: String?) throws -> String {
        var out: String = ""
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        guard let req = request(url, referer: referer) else {
            throw NSError(domain: "zz", code: -5, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        URLSession.shared.dataTask(with: req) { data, _, e in
            if let d = data { out = String(data: d, encoding: .utf8) ?? "" }
            err = e
            sem.signal()
        }.resume()
        sem.wait()
        if let e = err { throw e }
        return out
    }

    private func fetchData(_ url: String, referer: String?, completion: @escaping (Data?) -> Void) {
        guard let req = request(url, referer: referer) else { completion(nil); return }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                completion(nil); return
            }
            completion(data)
        }.resume()
    }

    private func downloadDirect(item: DownloadItem, to out: URL) throws {
        guard let req = request(item.url, referer: origin(of: item.url)) else {
            throw NSError(domain: "zz", code: -6, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        URLSession.shared.downloadTask(with: req) { tmp, resp, e in
            defer { sem.signal() }
            if let e = e { err = e; return }
            guard let tmp = tmp else {
                err = NSError(domain: "zz", code: -7,
                              userInfo: [NSLocalizedDescriptionKey: "下载失败"])
                return
            }
            try? FileManager.default.removeItem(at: out)
            do { try FileManager.default.moveItem(at: tmp, to: out) } catch { err = error }
        }.resume()
        sem.wait()
        if let e = err { throw e }
    }

    // MARK: - m3u8

    private func parsePlaylist(_ text: String) -> (segments: [String], variant: String?) {
        var segments: [String] = []
        var variant: String?
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let ln = lines[i].trimmingCharacters(in: .whitespaces)
            if ln.hasPrefix("#EXT-X-STREAM-INF") {
                var j = i + 1
                while j < lines.count {
                    let nx = lines[j].trimmingCharacters(in: .whitespaces)
                    if !nx.isEmpty && !nx.hasPrefix("#") { variant = nx; break }
                    j += 1
                }
            } else if ln.hasPrefix("#EXTINF") {
                var j = i + 1
                while j < lines.count {
                    let nx = lines[j].trimmingCharacters(in: .whitespaces)
                    if !nx.isEmpty && !nx.hasPrefix("#") { segments.append(nx); break }
                    j += 1
                }
            }
            i += 1
        }
        return (segments, variant)
    }

    private func resolve(base: String, ref: String) -> String {
        if ref.hasPrefix("http") { return ref }
        guard let b = URL(string: base) else { return ref }
        return URL(string: ref, relativeTo: b)?.absoluteString ?? ref
    }

    private func origin(of url: String) -> String? {
        guard let u = URL(string: url), let scheme = u.scheme, let host = u.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    // MARK: - 相册

    @discardableResult
    private func saveToPhotos(file: URL) throws -> String {
        var status: PHAuthorizationStatus = .notDetermined
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            status = s
            sem.signal()
        }
        sem.wait()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "zz", code: -8,
                          userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限，请到 设置→隐私→照片 打开"])
        }

        var saveError: Error?
        let done = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
        }) { ok, err in
            if !ok { saveError = err ?? NSError(domain: "zz", code: -9,
                userInfo: [NSLocalizedDescriptionKey: "保存到相册失败"]) }
            done.signal()
        }
        done.wait()
        if let e = saveError { throw e }
        return "已保存到相册：\(file.lastPathComponent)"
    }
}
