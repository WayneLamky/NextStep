import AppKit
import Foundation

/// "关于 NextStep" — uses the system About panel with a custom credits
/// attributed string. Simpler and more polished than rolling our own
/// NSWindow.
///
/// The panel reads app name / version / build from the main bundle's
/// `Info.plist`, so `CFBundleShortVersionString` and `CFBundleVersion`
/// should be kept current there.
@MainActor
enum AboutWindow {
    static func show() {
        let credits = makeCredits()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "NextStep",
            .applicationVersion: displayVersion(),
            .version: displayBuild(),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func displayVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "0.1"
    }

    private static func displayBuild() -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build ?? "dev"
    }

    private static func makeCredits() -> NSAttributedString {
        let body = """
        并行项目的"下一步仪表盘"——桌面便利贴 × 本地 Markdown × AI 生成下一步。

        给 ADHD / 多线程工作者：帮助启动，不制造待办。

        © 2026 claw
        """

        let attributed = NSMutableAttributedString(string: body)
        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        attributed.addAttributes(
            [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ],
            range: NSRange(location: 0, length: attributed.length)
        )
        return attributed
    }
}
