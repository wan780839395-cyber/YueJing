import Combine
import Foundation
import ReaderDomain
import TXTCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var service: LibraryService?
    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var importing = false
    @Published var encodingChoice: EncodingChoice?
    @Published var message: String?
    private var ticket: UUID?
    private var importTask: Task<Void, Never>?
    private var starting = false
    private var reloadGeneration = UUID()

    func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard service == nil else { await reload(); return }
        do { service = try await LibraryService.openDefault(); await reload() }
        catch { message = "无法打开书架：\(error.localizedDescription)" }
    }

    func reload() async {
        guard let service else { return }
        reloadGeneration = UUID()
        let generation = reloadGeneration
        do { let result = try await service.store.books(); if generation == reloadGeneration { books = result } }
        catch { message = "读取书架失败：\(error.localizedDescription)" }
    }

    func importFile(_ url: URL) {
        guard let service, !importing else { return }
        let id = UUID(); ticket = id; importing = true
        importTask = Task {
            do {
                let result = try await service.prepareImport(url: url, ticket: id)
                guard ticket == id else { _ = await service.cancelImport(id); return }
                switch result {
                case .completed(let receipt): await finish(receipt, id: id)
                case .choose(let choice): encodingChoice = choice
                }
            } catch { await failed(error, id: id) }
        }
    }

    func choose(_ encoding: TXTEncoding, for choice: EncodingChoice) {
        guard let service, ticket == choice.id, encodingChoice?.id == choice.id else { return }
        encodingChoice = nil
        importTask = Task {
            do { await finish(try await service.confirmImport(ticket: choice.id, encoding: encoding), id: choice.id) }
            catch { await failed(error, id: choice.id) }
        }
    }

    func cancelImport() async {
        guard let id = ticket, let service else { return }
        importTask?.cancel()
        let result = await service.cancelImport(id)
        guard ticket == id else { return }
        switch result {
        case .alreadyCommitted(let receipt): await finish(receipt, id: id)
        case .cancelled:
            ticket = nil; importing = false; encodingChoice = nil
            message = "已取消，未添加新书。"
            await reload()
        }
    }

    private func finish(_ receipt: ImportReceipt, id: UUID) async {
        guard ticket == id else { return }
        ticket = nil; importing = false; encodingChoice = nil
        message = receipt.duplicate ? "这本书已在书架，原阅读位置已保留。" : "已加入书架。"
        await reload()
    }

    private func failed(_ error: Error, id: UUID) async {
        guard ticket == id else { return }
        // Ask the commit authority before reporting cancellation; a late cancel may lose to commit.
        if let service, case .alreadyCommitted(let receipt) = await service.cancelImport(id) {
            await finish(receipt, id: id); return
        }
        ticket = nil; importing = false; encodingChoice = nil
        if error is CancellationError { message = "已取消，未添加新书。" }
        else if let error = error as? TXTError {
            switch error {
            case .unsupportedBOM: message = "暂不支持这份文件的文本格式，未加入书架。"
            case .noSupportedEncoding, .malformedInput: message = "文件包含无法完整识别或损坏的文字字节，未加入书架。"
            default: message = "这份文字无法按所选方式读取，未加入书架。"
            }
        } else { message = "未能导入：\(error.localizedDescription)" }
        await reload()
    }
}
