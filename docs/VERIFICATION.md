# NextStep · 全流程验证清单

> 用法：每次回归或发版前，对照本文从 §1 走到 §3 打一遍勾。
> 代码路径给出的是"这条验收点背后的实现在哪里"，方便当某一项失败时直接回到源头。

最后一次 code audit：2026-04-17（M8 polish 完成）

---

## §1 · PRD 9 条端到端验收（用户视角）

这 9 条来自 PRD → Verification → 核心验收，是发版前的"绿灯门"。

### [ ] 1. 新建项目 → CTA 10 秒内返回一个可启动动作

**操作**
1. ⌥⌘P，等便利贴出现
2. 项目名填 "写文献综述"，层级选周
3. 点 hero 区下方的"生成下一步"

**期望**
- 便利贴立刻出现在桌面中心偏右
- 生成期间显示"生成中…"骨架
- 10 秒内 hero 区显示一个**动词开头**的具体动作
- 动作长度不超过一行 × ~20 汉字

**代码路径**
- 快捷键：`NextStep/App/AppDelegate.swift:59-66` (registerHotkeys) + `NextStep/Hotkey/GlobalHotkey.swift`
- 便利贴生成：`WindowRegistry.createProject(level:)` → `StickyWindowController`
- LLM 调用：`NextStep/Views/StickyView.swift:385-423` (generateNextAction)
- Prompt 硬规则：`NextStep/LLM/NextActionPrompt.swift`

**可能失败**
- API key 缺失 → Settings → 模型 填
- 生成"开始写..."之类的抽象动作 → prompt 没保住，需要调 NextActionPrompt.swift
- 10 秒以上 → 网络或 provider baseURL 配错

---

### [ ] 2. "完成并推下一步" → markdown 里看到已完成历史

**操作**
1. 便利贴出现后，点 hero 区下方的"✓ 完成并推下一步"
2. 等 1–2 秒看 hero 翻转到新动作
3. 打开 `~/Documents/NextStep/projects/写文献综述.md`（或你在设置里选的文件夹）

**期望**
- hero 文字做一次 3D 卡片翻转（~400ms）
- 伴随 Tink 音效（若 `soundEnabled = true`）
- 新动作的风格和第一条类似但内容不同
- md 文件「已完成」段追加一行 `- [x] <旧动作> — YYYY-MM-DD`
- 「当前下一步」段内容更新为新动作

**代码路径**
- 翻转：`StickyView.swift:30,233-234` (heroFlipID + .transition(.heroFlip))
- 翻转 transition 定义：`Completion/CompletionFX.swift:56`
- 完成 → 追加已完成：`StickyView.swift:373-382` (complete)
- Project 的已完成数组：`Models/Project.swift:85-97` (completedHistory)
- markdown 序列化：`Sync/MarkdownParser.swift:49` (已完成 section)
- 触发写文件：`MarkdownBridge.shared.syncSoon(projectID:)`

---

### [ ] 3. 创建到第 5 个周目标 → 容量提示弹出

**操作**
1. 连续 ⌥⌘P 4 次，每次都选周级（到第 4 个不应触发提示）
2. 第 5 次 ⌥⌘P，选周级

**期望**
- 弹出 alert：`已达到周级目标上限 (4/4)`
- 说明文案解释 月≤1 / 周≤4 / 日≤3 的限制哲学
- 按钮：「好」、以及 "改为月级" / "改为日级"（如果那个级别还有空位）
- 点"改为日级" → 直接新建一个日级便利贴

**代码路径**
- 容量检查：`Capacity/CapacityGuard.swift` → `AppDelegate.handleNewProject:81-90`
- Alert UI：`AppDelegate.presentOverLimitSheet:92-123`
- 菜单栏角标：`MenuBar/MenuBarController.swift:44-54` (refreshStatusItem)

---

### [ ] 4. ⌥⌘N 自然语言 → Reminders.app 出带时间的 reminder

**操作**
1. ⌥⌘N
2. 输入"明天下午 5 点开组会" 回车
3. 打开 Reminders.app → 看 "NextStep · 同步" 列表

**期望**
- 输入框淡出 + 轻音效
- 不出便利贴
- Reminders 里立刻看到标题为"开组会"（含隐形 `【NSt:xxxxxxxx】` 标记），due date = 明天 17:00
- 时间解析用 `NSDataDetector`，失败时就做无 due date 的 reminder

**代码路径**
- 入口：`AppDelegate.handleNewTempTask:127-129` → `TempTaskInputController.shared.present()`
- 输入面板：`Input/TempTaskInput.swift:8-138`
- 时间解析：`TempTaskInput.swift:95-138` (NSDataDetector .date)
- 写入 Reminders：`Sync/RemindersBridge.swift:260-310` (upsertTempTask)
- 列表隔离："NextStep · 同步" 列表，按 calendarIdentifier 持久化
- 隐形标记：`NSt:<8char>`（`RemindersBridge.swift:413`）

**已知脆弱点**
- 沙盒关闭 + TCC 还没授权时，首次会弹系统权限；不授权则静默失败
- Settings → Reminders 有授权状态指示器可查

---

### [ ] 5. 在 Reminders 勾选 → 便利贴自动翻到下一步

**操作**
1. 完成 §1.2 留一张项目便利贴在桌面
2. 打开 Reminders.app
3. 找到那条项目对应的 reminder（标题末尾 `【NS:xxxxxxxx】`）
4. 勾选它

**期望**
- 5 秒内便利贴 hero 翻转到新动作（不是翻转后又翻回来）
- markdown「已完成」段追加一条
- 新 reminder 写回 Reminders，原来那条被替换

**代码路径**
- 回流轮询：`RemindersBridge.swift:343-385` (reconcile loop + snapshot diff)
- Echo 抑制：`recentlyTouched` dict，5s TTL（防止自己写的 reminder 又被当成用户勾选）
- 回调 → 便利贴：`AppDelegate.swift:40-51` (onProjectReminderCompleted → Notification)
- 便利贴接收：`StickyView.swift:79` (.onReceive(.nextStepRemindersCompleted) → complete())

**常见调试**
- 便利贴没反应 → 用 Console.app 搜 "RemindersBridge"；多半是 recentlyTouched 误杀
- reminder 标题被用户改过 → 找不到 projectID，回流失效（设计如此）

---

### [ ] 6. 外部编辑 md → 展开视图看到更新

**操作**
1. 有一张项目便利贴在桌面
2. 打开 VS Code，编辑 `~/Documents/NextStep/projects/<项目>.md`
3. 把 "## 本周目标" 下的文字改成一段新内容，保存
4. 回到便利贴，点 ⋯ → "展开为层级视图"

**期望**
- 展开视图里"周"节点显示新文字
- 若便利贴里本来就打开了展开视图，2 秒内自动刷新（FSEvent 去抖）
- 不会产生 `.md.conflict` 文件（因为便利贴那边没并发编辑）

**代码路径**
- FSEvent 监听：`Sync/FSWatcher.swift` + `Sync/MarkdownBridge.swift:52-65`
- 外部改动处理：`MarkdownBridge.swift:139-190` (handleExternalChange)
- 冲突策略：`MarkdownBridge.swift:184` (保留 .md.conflict)
- 展开视图：`Views/ExpandedHierarchyView.swift` + `App/ExpandedHierarchyWindow.swift`
- 展开入口：`StickyView.swift` moreMenu → ExpandedHierarchyRegistry.shared.open

**已知限制**
- md 的"当前下一步"被外部改后会立刻覆盖便利贴 hero
- 解析器认 `## 月目标` / `## 本周目标` / `## 今日动作`；改了 heading 名称就匹配不上

---

### [ ] 7. 双击进入聚焦 → 启番茄钟 → 合盖 5 分钟打开 → 计时继续

**操作**
1. 桌面至少两张项目便利贴
2. 双击其中一张
3. 另一张应该变暗（α≈0.6）
4. 在聚焦的那张点 🍅 图标启动番茄钟
5. 合上 MacBook 盖子 5 分钟，打开
6. 观察番茄钟剩余时间

**期望**
- 双击 → 其他便利贴变暗，聚焦的那张有呼吸光晕
- ESC / 再次双击 → 退出聚焦
- 番茄钟默认 25 分钟，按 wall-clock 计算（不是 Timer 计数），所以合盖 5 分钟打开后还剩 ~20 分钟而不是 ~25 分钟
- 若在 app 运行期间超时 → 通知中心弹提醒，便利贴呼吸一下

**代码路径**
- 聚焦管理：`Focus/FocusManager.swift:17` (shared, toggle)
- 聚焦 overlay：`FocusManager.swift:141` (dim panel with canJoinAllSpaces)
- 双击触发：`StickyView.swift:74,174`
- 番茄钟引擎：`Pomodoro/PomodoroEngine.swift` (全部)
- Wall-clock 计时的关键：状态写入 `Project.pomodoroStartedAt: Date?` + `pomodoroDuration`，UI 每秒用 `Date.now.timeIntervalSince(startedAt)` 算剩余
- 启动时接管：`AppDelegate.swift:37` → `PomodoroEngine.resumeActiveAfterLaunch:38-55`

---

### [ ] 8. 重启 app → 便利贴恢复原位、原色、原 hero

**操作**
1. 桌面有 2–3 张项目便利贴在不同位置、不同颜色
2. 记下每张的位置（用尺子或肉眼记）和当前下一步的前几个字
3. ⌘Q 退出 NextStep
4. 从应用程序重新打开

**期望**
- 便利贴全部回到原位（容差 < 5 像素）
- 颜色完全一致
- hero 区"下一个动作"文字和退出前完全一样
- markdown 文件没有被重新初始化
- 菜单栏角标 `N/8` 数字正确

**代码路径**
- 持久化：SwiftData `@Model Project`（位置、颜色、hero text 都在）
- 复位：`AppDelegate.swift:24` (WindowRegistry.shared.restoreAll) → `WindowRegistry.swift:22`
- Store：`NextStep/Store/AppStore.swift`

**已知脆弱点**
- 屏幕布局变化（外接屏拔了）→ 便利贴可能出现在屏幕外；目前没有自动矫正

---

### [ ] 9. 8 张满配同屏 (1 月 + 4 周 + 3 日)

**操作**
1. 新建直到 1 月 + 4 周 + 3 日共 8 张便利贴
2. 试拖拽移动、触发多个番茄钟（应该只允许一个）
3. Control + ↑ 或 Mission Control 进入 Spaces，切到另一 Space
4. 再切回来

**期望**
- 桌面不卡，FPS 不掉
- 8 张都跨 Space 常驻（collectionBehavior = `.canJoinAllSpaces + .stationary`）
- 同时只能跑一个番茄钟（点第 2 个时，上一个被替换）
- 菜单栏角标显示 `8/8`

**代码路径**
- 跨 Space：`StickyWindowController.swift:38` (collectionBehavior)
- 单番茄钟：`PomodoroEngine.start` 里 active 检查
- 容量到上限：此时再 ⌥⌘P 任何级别都会弹容量提示

---

## §2 · 按里程碑的功能点检查（开发者视角）

每点都应该能在当前 commit 下绿灯。失败时直接去对应文件排查。

### M0 — 脚手架 ✅
- [ ] App 启动不崩溃（`MacWeightApp.swift` / `AppDelegate.swift`）
- [ ] 菜单栏出 square.stack.3d.up icon + `N/8` 角标
- [ ] LSUIElement = YES（不占 Dock）
- [ ] SwiftData container 初始化无异常（`AppStore.swift`）
- [ ] Settings 窗口能打开且内容不空（`SettingsView.swift`）

### M1 — 单便利贴窗口 ✅
- [ ] 便利贴是 NSPanel，不抢前台焦点
- [ ] 可拖拽、可改颜色（调色板按钮）
- [ ] 关闭 ≠ 删除（菜单栏"打开隐藏的项目"能重开）
- [ ] 便利贴位置写入 SwiftData 实时生效

### M2 — Project 模型 + 双入口 + 容量限制 ✅
- [ ] ⌥⌘P / ⌥⌘N 两个 Carbon hotkey 都能触发
- [ ] StickyView hero 区域显示 `currentNextAction`
- [ ] 展开抽屉显示月/周/日三层目标 + 已完成历史
- [ ] 1/4/3 容量硬约束（`Capacity/CapacityGuard.swift`）
- [ ] 超限提示给出降级选项

### M3 — LLM 下一步 ✅
- [ ] Claude provider 跑通（`ClaudeProvider.swift`）
- [ ] Prompt 强约束：动词开头 / 15 分钟可启动 / 单一动作（`NextActionPrompt.swift`）
- [ ] CTA 翻转动画 400ms 平滑
- [ ] Keychain 存 API key，重启后不丢
- [ ] Settings → 模型 tab 能配 baseURL / model / 画像

### M4 — Markdown 双向同步 ✅
- [ ] Settings → 同步 能选文件夹（security-scoped bookmark）
- [ ] 新建项目 → 立刻写 md 文件
- [ ] 编辑便利贴 → 1 秒内写回 md（debounced）
- [ ] 外部编辑 md → FSEvent 触发便利贴刷新
- [ ] 冲突时保留 `.md.conflict`

### M5 — Reminders 同步 ✅
- [ ] 首次运行拉权限（EventKit fullAccess）
- [ ] "NextStep · 同步" 列表自动创建（避开用户可能已有的 "NextStep"）
- [ ] 项目下一步写入 reminder（带 `【NS:...】` 标签）
- [ ] 临时任务完全双向 mirror（带 dueDate）
- [ ] Echo 抑制：自己写的 reminder 在 5 秒内不会被回流当用户勾选

### M6 — ADHD 三件套 ✅
- [ ] 聚焦模式：双击 / ⌘F / 菜单项进出
- [ ] 聚焦的便利贴有脉冲光晕
- [ ] 番茄钟 wall-clock，不靠 in-process Timer
- [ ] 合盖再开，剩余时间按实际流逝算
- [ ] 同时只允许一个 active 番茄钟
- [ ] 完成时有 Tink / Glass 音效（Settings 可关）

### M7 — 展开视图 + 多 provider + iCloud ✅
- [ ] ⋯ → "展开为层级视图" 打开 radial window
- [ ] 月/周/日三层纵向布局 + dashed 连线
- [ ] 底部横向滚动"绿叶" chips = 已完成历史
- [ ] Settings 能切 Claude / OpenAI / Ollama
- [ ] 切 provider 无需重启（`LLMProviderResolver.current()` 每次 read UserDefaults）
- [ ] OpenAI 用 json_schema strict
- [ ] Ollama 用 `format: <schema>`，默认 `http://localhost:11434`
- [ ] Settings → 同步 有"使用 iCloud Drive 默认位置"按钮（仅当 iCloud 可用）
- [ ] 当前文件夹在 iCloud 下时显示 ☁️ 徽标

### M8 — 打磨 🟡
- [x] 归档库窗口：菜单栏 → "归档库…"
  - 代码：`Views/ArchiveView.swift` + `App/ArchiveWindow.swift`
- [x] About 窗口：菜单栏 → "关于 NextStep"
  - 代码：`App/AboutWindow.swift`（用 `NSApp.orderFrontStandardAboutPanel`）
- [x] 菜单栏补齐入口（`MenuBar/MenuBarController.swift` 63-149）
- [x] 占位 App 图标（`scripts/make-app-icon.swift` 生成 10 个 PNG）
- [ ] ⏳ 正式设计稿 icon（等设计）
- [ ] ⏳ 菜单栏专属 icon（当前复用 SF Symbol `square.stack.3d.up`）
- [ ] ⏳ Developer ID 签名 + 公证（脚本已备：`scripts/notarize.sh`）
- [ ] ⏳ DMG 打包（脚本已备：`scripts/notarize.sh`）

---

## §3 · 发版前自测流程

按顺序走一遍：

1. **Code path check** — 过一遍 §2 所有里程碑的 checkbox（只看代码，不跑）
2. **Clean build** — Product → Clean Build Folder，然后 Run。不应有 warning 爬出来
3. **Cold dogfood** — 删掉 `~/Library/Containers/com.claw.nextstep/`（如果沙盒开启）或 `~/Library/Application Support/NextStep/`，以干净状态走完 §1 的 9 条
4. **降级 provider** — 切到 Ollama（本地 `llama3.1`），再走一遍 §1.1 + §1.2。验证多 provider 没破
5. **Reminders 权限回归** — 到 System Settings → Privacy → Reminders 里关掉 NextStep 的授权，再进 Settings → 同步 → Reminders 重新授权
6. **归档库回归** — 从便利贴归档一个项目 → 归档库列出 → 点"恢复" → 便利贴重开 + markdown 续接 → 再归档 → 点"永久删除" → md 文件消失
7. **签名** — 跑 `scripts/notarize.sh`（需要填 DEVELOPER_ID / TEAM_ID / notarytool profile）
8. **Gatekeeper 干净机检测** — 拿生成的 DMG 到一台从未跑过 NextStep 的 Mac 上挂载，双击启动，不应出现"未验证的开发者"警告

---

## §4 · 已知 issue / 日后补

- 沙盒：暂关（TCC + ad-hoc 签名不兼容日历访问）。拿到 Developer ID 后：
  ```bash
  plutil -replace com.apple.security.app-sandbox -bool true \
    NextStep/Resources/NextStep.entitlements
  ```
  然后重新评估 iCloud Drive 路径访问、FSEvent 监听
- 多显示器：便利贴坐标系在主显示器坐标。副屏拔掉后，该屏幕上的便利贴会跑到屏外，目前没 reclaim 逻辑
- App 图标：占位的 SF Symbols 衍生图。拿到正式 1024×1024 设计稿后覆盖 `icon_512x512@2x.png` 其他可从 1024 downscale
- 菜单栏图标：复用 `square.stack.3d.up`，没有独立识别度。设计稿到手时单独给一个单色 template image
