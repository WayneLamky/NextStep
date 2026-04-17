# NextStep (macOS) — PRD

## Context

ADHD / 多线程工作者的两难：
- **线性 Todo 列表**让人窒息——打开就瘫痪，因为看到的是 50 个未完成项
- **纯粹隐藏式工具**（v1 NextStep 飞书机器人）又让并行项目感失去触感，"我还在推进哪些事"要靠脑力记

**NextStep macOS 版**把 v1 飞书机器人的"只推一个下一步"哲学搬到原生桌面：

- 每个项目 = 一张桌面便利贴 = 一个 markdown 文件
- 每张便利贴上**只显示这个项目当前能立刻开始的那一个动作**——不是清单
- 桌面上最多平铺 **1 个月目标 + 4 个周目标 + 3 个日目标**（共 8 张），永远一眼看得完
- 完成当前动作 → AI 生成下一个动作（不是 archive，是流转）
- 临时任务不占便利贴，直接进 Apple Reminders

这不是"便利贴版待办清单"。这是**桌面上并行项目的"下一步仪表盘"**，帮你启动，不帮你收纳。

v1 (飞书机器人) → v2 (macOS 原生) 的核心移植：相同的 **每项目一个 markdown 文件 + AI 生成下一步** 灵魂，换成**视觉化、可触摸、所见即并行**的桌面形态。

目标用户：ADHD / 多线程工作者、研究生、创作者、创业者——任何被"我应该做什么"的决策成本反复拖垮的人。

目录：`/Users/claw/Desktop/Mac Weight`（产品已更名为 NextStep；目录为历史遗留，不影响）

---

## 核心设计原则（承袭 v1）

| 原则 | 在 NextStep macOS 的体现 |
|---|---|
| **帮助启动，不制造待办** | 便利贴只显示"现在能开始的那一步"，不显示子任务清单 |
| **模糊 → 清晰** | LLM 的职责是把"写文献综述"变成"打开 Zotero，给这 5 篇文章打标签"，不是生成更多任务 |
| **并行管理，无强制优先级** | 桌面上同时看见所有项目的下一步，用户自己决定先点哪个 |
| **数据本地化** | 每个项目 = 用户指定文件夹里的一个 `.md` 文件，Markdown 是 source of truth，便利贴 UI 是视图 |
| **容量限制防过载** | 月 ×1、周 ×4、日 ×3，超过时提示用户合并/降级/替换，不默默吞掉 |

---

## Goals / Non-Goals

**Goals (v1)**
- 项目便利贴：每张显示"下一个动作"+ 项目名 + 层级 badge；拖拽、多 Space 常驻
- LLM 生成下一步：点"完成并推下一步"→ 当前动作记入 markdown，AI 基于项目上下文输出新动作
- 双入口：⌥⌘P 新建项目便利贴；⌥⌘N 临时任务（直接 → Reminders，不占便利贴）
- 容量提示：创建超限时弹出提示（降级 / 替换 / 忽略）
- Markdown 文件双向同步：sticky ↔ `~/Documents/NextStep/projects/<name>.md`
- EventKit：临时任务完全 mirror Reminders；项目便利贴的当前下一步写入 Reminders（单向）
- ADHD 四件套：聚焦模式、番茄钟、全局快捷键、完成动画
- 多 Provider（Claude / OpenAI / Ollama）

**Non-Goals (v1)**
- iOS / iPad（v2 再说，macOS 先做透）
- 协同 / 分享
- 日历事件集成（只 Reminders）
- 子任务清单视图（哲学性拒绝）
- 插件系统

---

## Core User Flows

### Flow 1 · 新建大目标项目
```
⌥⌘P → 桌面出空便利贴 → 光标聚焦在"项目名"输入框
→ 输入"写一篇文献综述"
→ 若已有 1 个月目标，弹出提示："你已有 1 个月目标'做毕业设计'。新项目的定级？"
   [选择级别: 月 (替换旧的) / 周 / 日 / 取消]
→ 确认级别（例：周）→ 便利贴呈现为周级配色 + badge
→ 点"生成下一步"按钮 → LLM 生成首个动作（例："打开 Zotero，搜索 3 个关键词并导出 20 篇摘要"）
→ 便利贴 hero 区域显示这一句
→ 后台在 `~/Documents/NextStep/projects/写一篇文献综述.md` 创建文件并写入月/周/日骨架
→ 把当前下一步作为 `EKReminder` 写入 Reminders
```

### Flow 2 · 执行并流转到下一步
```
用户完成"打开 Zotero..."这个动作 → 点便利贴上的大按钮"✓ 完成并推下一步"
→ 动作被追加到 markdown 的「已完成」区段，带时间戳
→ 对应 Reminder 被勾选
→ 触发 LLM：基于「项目上下文 + 已完成动作」生成新的下一步
→ 便利贴 hero 区域平滑过渡到新动作
→ 新 Reminder 写入 Reminders
→ 若 LLM 判断本周目标已完成 → 自动推进到下一周目标
→ 若整个项目完成 → 便利贴进归档库（菜单栏可查）
```

### Flow 3 · 临时任务
```
⌥⌘N → 光标处弹出细长输入框（不是便利贴）
→ 输入"明天下午 17:30 开组会"
→ 回车 → 消失 + 轻音效 → 直接 EKReminder 创建（带时间解析）
→ 不占便利贴
→ 到点 Reminders 通知
```

### Flow 4 · 聚焦模式
```
双击任意便利贴 → 其他便利贴 60% 变暗 → 该便利贴脉冲光晕
→ 可选启动番茄钟（25 分钟）
→ ESC 退出
```

### Flow 5 · 展开视图（brainstorm 时用，非日常）
```
项目便利贴右上角 ⋯ → "展开为层级视图"
→ 月目标在中心、周目标径向展开、日目标外层
→ 连线可视
→ 完成 brainstorm → "收起为单张" → 恢复一张便利贴
```
展开视图是**临时视图**，收起后结构仍在 markdown 里，不是"爆炸后留在桌面"。

### Flow 6 · Reminders 回流
```
用户在 Reminders.app 勾选某个 NextStep 写入的 Reminder
→ NextStep 检测到，视为"完成当前下一步"
→ 触发 Flow 2 的 LLM 流转
```

---

## Feature Spec

### F1 · Project Sticky（项目便利贴）

单张便利贴 = 1 个 `NSPanel`，`.nonactivatingPanel | .utilityWindow`，`.canJoinAllSpaces + .stationary + .ignoresCycle`，`isMovableByWindowBackground = true`。

**视觉结构（hero 区最大）**：
```
┌─────────────────────────────┐
│ [周] 写文献综述      ○ ⋯   │  <- 级别 badge + 项目名 + 调色板 + 更多
├─────────────────────────────┤
│                             │
│   打开 Zotero，            │
│   给这 5 篇文章打标签        │  <- Next Action (hero text, 16pt)
│                             │
│   ┌───────────────────┐    │
│   │ ✓ 完成并推下一步  │    │  <- primary CTA
│   └───────────────────┘    │
│                             │
├─────────────────────────────┤
│ 🍅  ⌄ 展开层级              │  <- pomodoro + 展开切换
└─────────────────────────────┘
```

**展开后（点 ⌄）**：
```
│ 🍅  ⌃ 收起                  │
├─────────────────────────────┤
│ 📅 月: 6 月交初稿            │
│   📆 本周: 写引言+方法        │
│     📌 今日: 文献综述草稿     │
│ ——————————————————         │
│ 已完成：                     │
│ • 导出 20 篇摘要 (昨)        │
│ • 定 outline (上周)         │
└─────────────────────────────┘
```

- 关闭 ≠ 删除；菜单栏「隐藏的便利贴」可重开
- 完成整个项目后进「归档库」

### F2 · Next Action Generation（下一步生成）

- 触发：CTA 按钮 / ⌘↵ / 外部 Reminder 被勾选
- LLM 输入：项目名、当前层级、month/week/day 目标文本、已完成动作历史、用户设置的个人偏好（如"我是研究生"）
- LLM 输出（structured）：
  ```json
  {
    "next_action": "打开 Zotero，给这 5 篇文章打标签",
    "estimated_minutes": 15,
    "level_advance": null   // or "week" / "day" if AI thinks to promote
  }
  ```
- Prompt 原则（硬编码）：
  - 动作必须**以动词开头**
  - 必须是"现在 15 分钟内能开始"的粒度
  - 不得返回多个候选、不得列出后续步骤
  - 若检测到项目停滞 >3 天，给出"更小的启动动作"
- 实现：provider 抽象层 + claude-sonnet-4-6 / gpt-4.1-mini / ollama 本地模型

### F3 · 容量限制（1/4/3）

- 硬规则：月 ≤1、周 ≤4、日 ≤3
- 创建/升级到超限级别时弹对话框：
  ```
  你已有 1 个月目标「做毕业设计」。
  [替换]  [降级为周]  [取消]
  ```
- 菜单栏 icon 角标显示当前容量（例 `3/8`）
- 超限时不冻结功能，但视觉告警（便利贴边框加橘色警示）

### F4 · Dual Input（双入口）

**⌥⌘P**（New Project）
- 桌面中心出新空项目便利贴，光标聚焦项目名
- 用户填名 → 选级别 → 首次"生成下一步"

**⌥⌘N**（Temp Task）
- 光标处弹 ~400×40 px 薄输入框（不是便利贴）
- 输入自然语言 → 回车
- LLM 快速解析：有时间词（明天、下午 5 点）→ 设 due date；无 → 纯文本 reminder
- 直接写入 Reminders 默认列表
- 输入框淡出 + 轻音效

### F5 · Markdown File Backing

- 首次启动请求选择项目文件夹（默认 `~/Documents/NextStep/projects/`）
- 每个 project sticky ↔ 一个 `<project-name>.md`
- Markdown 结构模板：
  ```markdown
  # 写文献综述

  ## 元信息
  - level: week
  - created: 2026-04-16
  - status: active

  ## 目标层级
  ### 月目标
  6 月交初稿

  ### 本周目标
  写引言+方法

  ### 今日动作
  文献综述草稿

  ## 当前下一步
  打开 Zotero，给这 5 篇文章打标签

  ## 已完成
  - [x] 导出 20 篇摘要 — 2026-04-15
  - [x] 定 outline — 2026-04-08
  ```
- 双向同步：便利贴编辑 → 写 md；外部编辑 md 文件 → `FSEventStream` 检测 → 更新便利贴
- Markdown 是 source of truth；SwiftData 保存 UI 状态（position、color、minimize）+ 对 md 的指针

### F6 · Apple Reminders Sync

- 权限：EventKit `.fullAccess`
- **Project sticky**：
  - 每次生成新的下一步 → 在 "NextStep" 列表（自动创建）写入一个 EKReminder，标题 = next action 文本，title 末尾带隐形标识 `【NS:<uuid>】`
  - 旧的 next action Reminder 自动清除（未完成时也清，因为已被新动作替代）
  - 用户在 Reminders 勾 → 触发 Flow 2
- **Temp task**：完全 mirror，双向同步
- 循环抑制：`recentlyWrittenEKIDs: Set<String>` TTL 5s

### F7 · Focus Mode（聚焦模式）

- 双击便利贴 / F 键触发
- 全桌面 overlay 窗口（透明、ignoresMouseEvents）铺 α=0.4 黑层
- 选中便利贴 level 提升，脉冲光晕
- ESC / 再次双击退出

### F8 · Per-Project Pomodoro

- 25/5 分钟可改
- 状态持久化（ADHD 合盖继续）
- 同时只允许一个番茄钟
- 结束：NSUserNotification + 铃声 + 便利贴呼吸动画

### F9 · Global Hotkey

- Carbon `RegisterEventHotKey`（NSEvent 全局监听无法拦截）
- 默认：⌥⌘P 新项目、⌥⌘N 临时任务
- 设置中可改

### F10 · Completion Feedback

- 推下一步时便利贴 hero 文字做**卡片翻转**动画（~400ms）
- 完成整个项目时粒子动画 + 音效 + 进归档库
- 可在设置关音效

### F11 · LLM Provider

- Claude（默认 `claude-sonnet-4-6`）/ OpenAI / Ollama，BYOK，Keychain 存
- 用 structured output / tool use 强约束
- "个人偏好"字段（如"研究生、ADHD、不擅长启动"）写入 system prompt

### F12 · 存储与同步

- SwiftData 本地（macOS 15+）
- Markdown 文件 = source of truth
- iCloud 同步（CloudKit）默认关；真正的跨设备同步走 iCloud Drive 的 markdown 文件夹更稳

---

## Technical Architecture

**Stack**
- Swift 6 / SwiftUI + AppKit 互操作
- macOS 15.0+ (Sequoia)
- SwiftData（UI 状态）+ Markdown files（project 数据 source of truth）
- EventKit（Reminders）
- Carbon HotKey
- FSEventStream（监听外部 markdown 编辑）

**窗口架构**
- `StickyWindowController` — 每项目 1 NSPanel（已在 M1 实现，沿用）
- `ConnectorOverlayWindow` — 聚焦 dim / 展开视图连线
- `WindowRegistry` — 索引 & 多显示器处理（已在 M1 实现，沿用）

**数据层**
- `AppStore` — SwiftData container（已在 M0 实现）
- `MarkdownBridge` — 便利贴 ↔ md 双向同步 + FSEvent 监听
- `RemindersBridge` — EventKit，仅同步 current next action 和 temp tasks
- `LLMProvider` protocol + 3 实现

---

## Data Model（SwiftData）

```swift
enum ProjectLevel: String, Codable, CaseIterable { case month, week, day }

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var levelRaw: String            // ProjectLevel
    var currentNextAction: String
    var estimatedMinutes: Int?

    // Hierarchy targets (editable, not auto-derived)
    var monthGoal: String
    var weekGoal: String
    var dayAction: String

    // Completion history
    var completedHistoryJSON: Data  // [CompletedAction] encoded

    // Sticky UI state
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var colorIndex: Int
    var isMinimized: Bool
    var isExpanded: Bool            // hierarchy drawer open
    var isArchived: Bool            // entire project done
    var archivedAt: Date?

    // Sync
    var markdownFilePath: String?
    var currentEKReminderID: String?

    // Pomodoro
    var pomodoroStartedAt: Date?
    var pomodoroDuration: TimeInterval?
    var pomodoroPaused: Bool

    var createdAt: Date
    var modifiedAt: Date
}

struct CompletedAction: Codable {
    let action: String
    let completedAt: Date
}

@Model
final class TempTask {
    @Attribute(.unique) var id: UUID
    var text: String
    var dueDate: Date?
    var ekReminderID: String?
    var isCompleted: Bool
    var createdAt: Date
}
```

---

## Implementation Plan（里程碑）

**M0 · 脚手架** ✅ 已完成
- Xcode 项目、SwiftUI App、LSUIElement、menu bar、SwiftData stack、设置窗口骨架

**M1 · 单便利贴窗口** ✅ 已完成（需改造为 Project）
- NSPanel + SwiftUI 内容、拖拽、颜色、持久化、重启复位
- 🔧 待改造：`Note` → `Project` 模型；UI 从"title + body"改为"hero next action + collapsed hierarchy"

**M2 · Project 模型重构 + 容量限制 + 双入口（1 周）**
- 模型：Note → Project；新增 TempTask
- StickyView 重绘：hero next action + 折叠层级抽屉
- ⌥⌘P 新项目（Carbon HotKey）
- ⌥⌘N 临时任务薄输入框
- 1/4/3 容量检测 + 提示 sheet
- 菜单栏 icon 角标 `N/8`

**M3 · LLM 生成下一步（1 周）**
- `LLMProvider` protocol + Claude 实现（主路径）
- `NextActionPrompt.swift` 内置 prompt
- CTA 按钮 → 生成 → 便利贴 hero 卡片翻转动画
- Keychain key 存储 + 设置页 UI

**M4 · Markdown 文件双向同步（1 周）**
- 首次启动选项目文件夹
- Project ↔ markdown 双向写
- FSEventStream 监听外部编辑
- 冲突策略：修改时间 tie-break，保留 `.md.conflict`

**M5 · Reminders 同步（1 周）**
- EventKit `.fullAccess` 权限
- "NextStep" 列表自动创建
- 项目下一步写入 / 外部勾选回流
- Temp task 完全 mirror
- 循环抑制（TTL 5s）

**M6 · ADHD 三件套（0.5 周）**
- 聚焦模式（overlay dim）
- 项目番茄钟（含状态持久化）
- 完成动画 + 音效

**M7 · 展开视图 + OpenAI/Ollama + iCloud（1 周）**
- 项目展开为月-周-日径向视图（Flow 5）
- OpenAI / Ollama provider
- iCloud Drive 同步 markdown（而非 CloudKit）

**M8 · 打磨 + 打包（0.5 周）**
- 图标、菜单栏 icon、About、归档视图
- Developer ID 签名 + 公证
- DMG

总计 M0–M8 约 **7 周**（M0+M1 已完成，剩 ~5 周）。

---

## 关键文件（增量自当前代码）

**已有（M0+M1）：**
- `MacWeight/App/MacWeightApp.swift`、`AppDelegate.swift`、`StickyPanel.swift`、`StickyWindowController.swift`、`WindowRegistry.swift`
- `MacWeight/Models/Note.swift`（将重构）、`HierarchyLevel.swift`、`NoteColor.swift`
- `MacWeight/Store/AppStore.swift`
- `MacWeight/Views/StickyView.swift`（将重绘）、`SettingsView.swift`
- `MacWeight/MenuBar/MenuBarController.swift`

**M2 改造 / 新增：**
- `Models/Project.swift`（替换 Note）
- `Models/TempTask.swift`（新）
- `Views/StickyView.swift` 重绘
- `Hotkey/GlobalHotkey.swift`
- `Input/TempTaskInput.swift`
- `Capacity/CapacityGuard.swift`

**M3-M8 新增：**
- `LLM/LLMProvider.swift`、`ClaudeProvider.swift`、`NextActionPrompt.swift`
- `Sync/MarkdownBridge.swift`、`RemindersBridge.swift`
- `Views/ExpandedHierarchyView.swift`
- `Focus/FocusManager.swift`、`Pomodoro/PomodoroEngine.swift`、`Completion/CompletionFX.swift`
- `App/ConnectorOverlayWindow.swift`

**品牌改名：**
- Xcode target `MacWeight` → `NextStep`
- Bundle ID `com.claw.macweight` → `com.claw.nextstep`
- Display name "Mac Weight" → "NextStep"
- 目录 `Mac Weight/` 保持（历史遗留，不影响）

---

## 风险 & 缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| LLM 生成的"下一步"仍然抽象（如"开始写引言"）| 用户无法启动，产品失败 | Prompt 硬规"动词 + 具体对象"、"15 分钟可启动"；用户点"还是太大"让 LLM 再切一次 |
| Markdown 外部编辑 vs 便利贴并发冲突 | 数据错乱 | modifiedAt tie-break + FSEvent 去抖；冲突时保留 `.md.conflict` |
| 8 张容量上限让用户抵触 | 产品被嫌弃 | 软限制 + 友好提示；归档动作很轻；展开视图提供临时更多可视化 |
| 临时任务 vs 项目边界模糊 | 不知该按哪个 hotkey | 文案教学：⌥⌘N = "快速记"（1 分钟能清）；⌥⌘P = "开坑"（需多步推进） |
| EKReminder 只同步 current next action | 用户想在 Reminders 里看进度 | 历史只在 markdown；Reminders 本就不是进度工具 |
| LLM API 延迟 / 失败 | CTA 卡住 | 1.5s 后显示"生成中..."骨架；失败时手填降级 |
| SwiftData v1 + CloudKit 数据丢失 | 用户数据丢 | floor = macOS 15+；sync 走 iCloud Drive markdown 而非 CloudKit |

---

## Verification

**核心验收（手动）**
1. ⌥⌘P → 新建"写文献综述"项目，选周级 → 便利贴出现，CTA"生成下一步" → 10s 内 LLM 返回可启动动作
2. 点"完成并推下一步" → hero 文字翻转 → 新动作 → `~/Documents/NextStep/projects/写文献综述.md` 里看到已完成历史
3. 创建到第 5 个周目标时 → 容量提示弹出
4. ⌥⌘N 输入"明天 5 点开会" → Reminders.app 立即看到带正确时间的 Reminder
5. Reminders.app 里勾掉 NextStep 写的 Reminder → 便利贴自动 hero 翻转到下一步
6. 外部用 VS Code 改 `写文献综述.md` 里的月目标 → 便利贴展开视图看到更新
7. 双击便利贴进入聚焦 → 其他变暗 → 启动番茄钟 → 合盖 5 分钟打开 → 计时继续
8. 关闭所有便利贴 → 重启 app → 便利贴在原位置、原颜色、原 hero 动作恢复
9. 8 张便利贴（1+4+3）同屏，不卡、跨 Space 常驻

**开发时**
- Unit: `NextActionPrompt` schema 合规率、`CapacityGuard` 边界、`MarkdownBridge` 解析/序列化往返一致
- Integration: EventKit mock 下的双向同步 + ping-pong 抑制
- E2E: dogfood 本人一周
