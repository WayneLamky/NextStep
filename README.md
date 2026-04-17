# NextStep

> 桌面上并行项目的「下一步仪表盘」。每个项目一张便利贴，只显示现在能立刻开始的那一个动作。给 ADHD / 多线程工作者：帮助启动，不制造待办。

**设计哲学** — 线性 Todo 让人窒息，纯隐藏式工具又让并行项目失去触感。NextStep 把每个项目放在桌面上作为一张便利贴，每张只显示"现在能开始的那一步"，LLM 负责把模糊目标切成具体可启动动作。

---

## 安装

### 方式 A · 直接下载 DMG（推荐给不懂代码的用户）

1. 到 [Releases](../../releases) 页，下载最新版的 `NextStep-*.dmg`
2. 双击挂载，把 NextStep 拖进 Applications
3. **首次启动前**，打开 Terminal，跑一句：

   ```bash
   xattr -cr /Applications/NextStep.app
   ```

4. 双击启动。

#### 为什么要 `xattr`？

这是个开源项目，没给 Apple 交每年 $99 的 Developer ID 费用，所以 DMG 没走公证。macOS 下载后会给它加一个"隔离标记"，直接打开会弹"无法验证开发者"。上面那句命令清掉这个标记就好了。代码本身用了 ad-hoc 签名，是完整的——只是少了 Apple 这一层背书。

**不想用命令行？** 也可以：

- 右键 NextStep.app → 选"打开"→ 弹窗点"打开"
  - macOS 15+ 上这个路径有时失效，以 `xattr` 那句为准
- 或：「系统设置 → 隐私与安全性」拉到底，试过一次后会出现"仍要打开"按钮

### 方式 B · 从源码构建

```bash
git clone https://github.com/<YOUR-HANDLE>/NextStep.git
cd NextStep
open NextStep.xcodeproj   # Xcode 16+
# ⌘R 运行
```

需要 macOS 15+ / Xcode 16+。

---

## 首次使用

1. **菜单栏** → NextStep 图标（叠起来的三张卡片）
2. **⌥⌘P** — 新建一个项目便利贴
3. **⌥⌘N** — 记一条临时任务（直接进 Reminders，不占桌面）

首次生成「下一步」前要到菜单栏 → 设置 → 模型，填一个 LLM provider 的 key：

- **Claude**（推荐，默认）：`claude-sonnet-4-6`，到 [console.anthropic.com](https://console.anthropic.com) 拿 key
- **OpenAI**：`gpt-4.1-mini` 够用
- **Ollama**（本地免费）：默认 `http://localhost:11434` + `llama3.1`，无 key

想让 AI 生成的动作更契合你：设置 → 模型 → 个人画像，填"研究生、ADHD、不擅长启动"之类的一句话。

---

## 核心功能

- 📌 **每个项目 = 一张桌面便利贴**，只显示"下一步"，不是任务清单
- 🧠 **LLM 生成下一步** — 点"完成并推下一步"，AI 基于项目上下文给出新动作
- 📂 **Markdown 是 source of truth** — 每个项目对应一个 `.md` 文件，可用 VS Code 直接编辑，FSEvent 自动回流
- ⏲️ **Apple Reminders 双向同步** — 项目的当前下一步写入 Reminders，勾选 = 推下一步；临时任务完全 mirror
- 🎯 **容量限制 1/4/3** — 月 ≤1、周 ≤4、日 ≤3，强制防止"开坑过多"
- 🫧 **聚焦模式 + 番茄钟** — 双击便利贴其他变暗；番茄钟按 wall-clock 计时，合盖再开照样走
- 🎨 **iCloud Drive 一键同步** — 把 markdown 文件夹放到 iCloud 下，多台 Mac 数据自动跟

---

## 目录结构

```
NextStep/
├── App/           # AppDelegate、窗口管理、启动流程
├── Views/         # SwiftUI 便利贴、展开视图、归档、设置
├── Models/        # SwiftData 模型 (Project, TempTask)
├── LLM/           # Provider 抽象 + Claude/OpenAI/Ollama 实现
├── Sync/          # MarkdownBridge / RemindersBridge / FSWatcher
├── Focus/         # 聚焦模式
├── Pomodoro/      # 番茄钟引擎
├── Capacity/      # 1/4/3 限流
├── Hotkey/        # ⌥⌘P / ⌥⌘N Carbon 全局热键
└── Input/         # 临时任务输入面板

scripts/
├── make-app-icon.swift         # 生成占位 App 图标
├── release-opensource.sh       # 本地打 ad-hoc 签名 DMG（开源路径）
└── notarize.sh                 # Developer ID 签名 + 公证（需要 Apple 账户）

docs/
└── VERIFICATION.md             # 全流程验证清单
```

---

## 发版（维护者）

### 自动（推荐）

```bash
git tag v0.1.0
git push origin v0.1.0
```

推 tag 会触发 `.github/workflows/release.yml`：在 GitHub 的 macOS runner 上构建、ad-hoc 签名、打 DMG、自动创建一个 GitHub Release 并上传 DMG + sha256。不需要任何 secret。

### 手动（本地）

```bash
brew install create-dmg
./scripts/release-opensource.sh
# 产物在 ./dist/NextStep-<version>.dmg
```

---

## 开发

新手入门：先过 [`docs/VERIFICATION.md`](docs/VERIFICATION.md) 了解每个功能点的实现位置。设计原则在 [项目 PRD](PRD.md)。

```bash
# 构建
xcodebuild -project NextStep.xcodeproj -scheme NextStep build

# 运行测试（如果有）
xcodebuild -project NextStep.xcodeproj -scheme NextStep test
```

---

## 贡献

这是个人项目，但 issue 和 PR 欢迎。

- 提 issue 时请说明 macOS 版本 + 复现步骤
- PR 请保持一个 commit 一件事
- 不要加"子任务清单视图"——那是哲学性拒绝，见 PRD

---

## License

[待定 —— 选个 MIT / Apache-2.0 塞到 `LICENSE` 文件里，然后在此处声明]

---

## 致谢

- 灵感：飞书机器人版 v1 NextStep
- SwiftUI + AppKit 互操作的诸多技巧来自 macOS 开源社区
