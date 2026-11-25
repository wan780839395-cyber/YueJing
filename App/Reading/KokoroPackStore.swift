import Combine
import Foundation

@MainActor
final class KokoroPackStore: ObservableObject {
    static let shared = KokoroPackStore(
        root: URL.applicationSupportDirectory.appendingPathComponent("KokoroPacks", isDirectory: true),
        defaults: .standard
    )

    @Published private(set) var installedDirectory: URL?
    @Published private(set) var isInstalling = false
    @Published private(set) var statusText = "正在检查本地语音包…"
    @Published var useKokoro: Bool {
        didSet { defaults.set(useKokoro, forKey: Self.preferenceKey) }
    }

    /// Content identity, not a path or install date. Identical reinstalls render identically.
    var revision: String? { installedDirectory == nil ? nil : KokoroPackIndex.archiveSHA256 }

    private static let preferenceKey = "reading.kokoro.preferred"
    private let defaults: UserDefaults
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var canCancelDownload = false
    private var downloadJob: Task<Void, Never>?
    private var downloadID: UUID?
    private let workRoot: URL
    private let disk: KokoroPackDisk
    private var initialCheck: Task<Void, Never>?

    init(root: URL, defaults: UserDefaults, index: KokoroPackIndex? = nil) {
        self.defaults = defaults
        workRoot = root.appendingPathComponent(".download", isDirectory: true)
        disk = KokoroPackDisk(root: root, index: index)
        useKokoro = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        initialCheck = Task { [weak self] in
            guard let self else { return }
            do {
                // No transfer starts until initialCheck finishes. Reclaim only this store's own partial download.
                try? FileManager.default.removeItem(at: workRoot)
                installedDirectory = try await disk.restore()
                statusText = installedDirectory == nil ? "未安装本地语音包" : "本地语音包已就绪"
            } catch {
                statusText = "无法验证本地语音包，请重新下载。"
            }
        }
    }

    typealias Fetch = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    func downloadAndInstall() async {
        await downloadAndInstall { url, progress in try await KokoroPackDownload(progress: progress).fetch(to: url) }
    }

    func downloadAndInstall(using fetch: @escaping Fetch) async {
        await initialCheck?.value
        guard !isInstalling else { return }
        let id = UUID(); downloadID = id; isInstalling = true; canCancelDownload = true
        downloadProgress = 0; statusText = "正在下载 Kokoro 离线语音包…"
        let job = Task { [self] in
            let fm = FileManager.default
            // A previous process may have died mid-transfer. Only reclaim our named scratch folder.
            defer {
                try? fm.removeItem(at: workRoot)
                downloadProgress = nil; canCancelDownload = false; downloadID = nil; isInstalling = false; downloadJob = nil
            }
            do {
                if fm.fileExists(atPath: workRoot.path) { try fm.removeItem(at: workRoot) }
                try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
                var folder = workRoot, flags = URLResourceValues(); flags.isExcludedFromBackup = true
                try folder.setResourceValues(flags)
                if let bytes = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   bytes < 540_000_000 { throw KokoroDownloadError.space }
                let file = folder.appendingPathComponent("voice.tar.bz2")
                try Task.checkCancellation()
                try await fetch(file) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, downloadID == id, canCancelDownload, let last = downloadProgress else { return }
                        downloadProgress = max(last, min(1, progress))
                    }
                }
                try Task.checkCancellation()
                downloadProgress = nil; canCancelDownload = false; statusText = "正在校验并安装离线语音包…"
                installedDirectory = try await disk.installArchive(from: file)
                useKokoro = true; statusText = "Kokoro 离线语音已就绪"
            } catch {
                if Task.isCancelled || error is CancellationError { statusText = "下载已取消，可重新下载。" }
                else if error as? KokoroDownloadError == .space || (error as NSError).code == NSFileWriteOutOfSpaceError { statusText = "空间不足，请留出约 540 MB 后重试。" }
                else if downloadProgress != nil { statusText = "下载失败，请检查网络后重试。" }
                else { statusText = "语音包校验或安装失败，原有语音未更改，请重试。" }
            }
        }
        downloadJob = job; await job.value
    }

    func cancelDownload() {
        guard canCancelDownload else { return }
        canCancelDownload = false; statusText = "正在取消下载…"; downloadJob?.cancel()
    }

    func install(from source: URL) async {
        await initialCheck?.value
        guard !isInstalling else { return }
        isInstalling = true
        statusText = "正在复制并校验语音包…"
        defer { isInstalling = false }
        do {
            installedDirectory = try await disk.install(from: source)
            statusText = "本地语音包已就绪"
        } catch is CancellationError {
            statusText = "已取消导入"
        } catch {
            statusText = "未安装新语音包。请确认已完整解压官方 int8 v1_1 文件夹，并检查可用空间。"
        }
    }

    func remove() async {
        await initialCheck?.value
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            try await disk.remove()
            installedDirectory = nil
            statusText = "未安装本地语音包"
        } catch {
            statusText = "未能移除本地语音包"
        }
    }
}
