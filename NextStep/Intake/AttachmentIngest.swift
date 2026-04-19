import Foundation
import PDFKit

/// Error surface for attachment ingest. Keeps UI copy in one place.
enum AttachmentError: LocalizedError {
    case tooManyFiles(limit: Int)
    case totalTooLarge(limit: Int)
    case unsupportedType(ext: String)
    case unreadable(filename: String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles(let limit):
            return "最多 \(limit) 个附件。"
        case .totalTooLarge(let limit):
            return "附件总字符数超过 \(limit) 上限。请删掉一个或替换成更短的。"
        case .unsupportedType(let ext):
            return "不支持的格式：.\(ext)。目前只吃 .pdf / .md / .txt。"
        case .unreadable(let filename):
            return "\(filename) 读不出文本（可能是扫描版 PDF 或加密文件）。"
        }
    }
}

/// Max concurrent attachments + combined character limit. Kept conservative
/// so we stay well under provider context windows even for long system
/// prompts + multi-turn history.
enum AttachmentLimits {
    static let maxFiles = 3
    static let maxTotalChars = 50_000
    /// Individual file cap so a single PDF can't starve the others.
    static let maxPerFileChars = 30_000
}

enum AttachmentIngest {
    /// Pull plain text out of one local file URL. Dispatches on extension.
    /// Synchronous + quick on typical docs; wrap in a detached Task from
    /// the UI if a massive PDF is plausible.
    static func extract(from url: URL) throws -> AttachmentPayload {
        let ext = url.pathExtension.lowercased()
        let raw: String
        switch ext {
        case "pdf":
            raw = try extractPDF(url: url)
        case "md", "markdown", "txt":
            raw = try extractText(url: url)
        default:
            throw AttachmentError.unsupportedType(ext: ext)
        }
        let trimmed = trim(raw, cap: AttachmentLimits.maxPerFileChars)
        return AttachmentPayload(
            filename: url.lastPathComponent,
            content: trimmed
        )
    }

    /// Validate that adding `next` to the existing attachment list stays
    /// within limits. Throws the appropriate `AttachmentError` if not.
    static func validate(adding next: AttachmentPayload, to existing: [AttachmentPayload]) throws {
        if existing.count + 1 > AttachmentLimits.maxFiles {
            throw AttachmentError.tooManyFiles(limit: AttachmentLimits.maxFiles)
        }
        let totalChars = existing.reduce(0) { $0 + $1.content.count } + next.content.count
        if totalChars > AttachmentLimits.maxTotalChars {
            throw AttachmentError.totalTooLarge(limit: AttachmentLimits.maxTotalChars)
        }
    }

    // MARK: - Extractors

    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw AttachmentError.unreadable(filename: url.lastPathComponent)
        }
        let full = doc.string ?? ""
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError.unreadable(filename: url.lastPathComponent)
        }
        return full
    }

    private static func extractText(url: URL) throws -> String {
        // Try UTF-8 first, then a couple of common fallbacks before giving up.
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        if let data = try? Data(contentsOf: url) {
            for enc: String.Encoding in [.utf16, .isoLatin1, .macOSRoman] {
                if let s = String(data: data, encoding: enc) {
                    return s
                }
            }
        }
        throw AttachmentError.unreadable(filename: url.lastPathComponent)
    }

    /// Truncate long strings with an ellipsis marker so the model knows
    /// it was cut (rather than thinking the doc actually ends mid-sentence).
    private static func trim(_ s: String, cap: Int) -> String {
        guard s.count > cap else { return s }
        let idx = s.index(s.startIndex, offsetBy: cap)
        return String(s[..<idx]) + "\n\n…（文档后续内容已截断以符合长度上限）"
    }
}
