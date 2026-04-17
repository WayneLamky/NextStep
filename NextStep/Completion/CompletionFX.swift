import AppKit
import SwiftUI

/// M6 · 完成反馈
///
/// 两种可听化的节点：
/// - `playNextStep()` — 用户按"完成并推下一步"，成功推出下一步时触发
/// - `playProjectArchived()` — 整个项目归档时触发
///
/// 都走系统 `/System/Library/Sounds/` 里的内置音效，避免打包第三方资源。
/// 用户可以在设置 → 通用里关掉所有音效（`soundEnabled` 开关）。
@MainActor
enum CompletionFX {
    /// 推下一步的轻音效。
    static func playNextStep() {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    /// 归档整个项目的大音效。
    static func playProjectArchived() {
        guard soundEnabled else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    private static var soundEnabled: Bool {
        // `soundEnabled` 默认 true。设置页面 UI 已经在 M2 里连上。
        UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    }
}

// MARK: - Hero flip transition

/// 3D "卡片翻转" transition — 新旧文字分别绕 Y 轴转出/转入，≈ 400ms。
/// 用于便利贴 hero 区的 currentNextAction 文本推下一步时。
struct HeroFlipModifier: ViewModifier {
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.6
            )
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// 新的 hero 文字从右侧翻进来；旧的往左侧翻出去。
    /// Computed (not stored) because `AnyTransition` isn't Sendable — a static
    /// stored constant would trip Swift 6 strict concurrency.
    static var heroFlip: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: HeroFlipModifier(angle: 80, opacity: 0),
                identity: HeroFlipModifier(angle: 0, opacity: 1)
            ),
            removal: .modifier(
                active: HeroFlipModifier(angle: -80, opacity: 0),
                identity: HeroFlipModifier(angle: 0, opacity: 1)
            )
        )
    }
}
