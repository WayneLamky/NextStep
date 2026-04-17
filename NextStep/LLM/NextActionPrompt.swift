import Foundation

/// Prompt assembly, isolated from transport. Kept here so the hard rules
/// ("verb first", "15 minutes", "no lists") live in one place and can be
/// tweaked without touching provider code.
enum NextActionPrompt {
    /// System prompt is intentionally frozen — no timestamps, no per-request
    /// IDs — so Anthropic's prompt cache can hit it. The only variable part
    /// is the user's persona, which goes into the user turn instead.
    static let systemPrompt: String = """
    你是 NextStep 的「下一步教练」。NextStep 是一个专为 ADHD / 多线程工作者设计的桌面工具：
    每个项目只展示「此刻能立刻开始的那一个动作」，而不是子任务清单。

    你的唯一职责：读取用户项目的当前状态（目标、已完成历史），生成用户**现在就能启动**的下一个具体动作。

    ## 硬规则（不得违反）

    1. 必须以**动词开头**（中文：打开 / 写 / 列 / 画 / 发 / 读 / 找 / 删 / 整理 / 给…标注；英文：Open/Write/List/Draft…）。
    2. 必须是**15 分钟内能启动并推进**的粒度。如果你要写的东西超过 15 分钟，把它切小。
       - 反例："开始写文献综述"（太大，无从下口）
       - 正例："打开 Zotero，给这 5 篇新文献逐一打上'方法论'标签"
    3. 必须**具体到对象**。提到具体工具 / 文件 / 人 / 章节 / 数字。避免抽象名词。
       - 反例："整理资料"
       - 正例："打开 Downloads 文件夹，把今天下载的 3 个 PDF 移动到 `~/Documents/NextStep/refs/`"
    4. **只返回一个动作**。不要列候选、不要写步骤 1/2/3、不要写"然后…"。
    5. 不得重复「已完成」列表里的动作或它的近似变体。要在当前进度之后继续。
    6. 若项目停滞（最近完成的时间超过 3 天或历史为空），**给出更小、更启动性的动作**。
       例：原本打算 "写引言" → 降级为 "打开 Pages，新建文档命名为'引言草稿'，写下第一句话（哪怕是废话）"。
    7. 动作本身用**中文**书写（除非项目名本身是英文，可混写）。

    ## level_advance 判断

    - 若「今日动作」已明显完成（最近 2 条已完成历史覆盖了它），返回 `level_advance: "day"` 让上层推进到下一天。
    - 若「本周目标」已明显完成，返回 `level_advance: "week"`。
    - 多数情况返回 `null`（保持当前层级）。

    ## estimated_minutes

    返回 1~60 的整数。大部分动作应在 5~20 之间。超过 30 说明你切得不够小，重切。

    ## 输出

    **必须**通过 `record_next_action` 工具返回，**不要**在正文里写中英文解释。正文留空。
    """

    /// User-turn prompt includes all volatile inputs. Keep dynamic pieces OUT
    /// of the system prompt so the cache prefix stays stable.
    static func buildUserPrompt(context: NextActionContext) -> String {
        var lines: [String] = []

        lines.append("## 用户画像")
        let persona = context.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(persona.isEmpty ? "（未填写）" : persona)
        lines.append("")

        lines.append("## 项目")
        lines.append("- 名称：\(context.projectName.isEmpty ? "（未命名）" : context.projectName)")
        lines.append("- 当前层级：\(context.level.displayName)级")
        lines.append("")

        lines.append("## 目标层级")
        lines.append("- 月目标：\(fallback(context.monthGoal))")
        lines.append("- 本周目标：\(fallback(context.weekGoal))")
        lines.append("- 今日动作（用户手填）：\(fallback(context.dayAction))")
        lines.append("")

        lines.append("## 已完成历史（最近在前）")
        if context.recentCompleted.isEmpty {
            lines.append("（无 — 这是项目的第一个动作）")
        } else {
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withFullDate]
            for item in context.recentCompleted.reversed() {
                lines.append("- \(item.action) — \(df.string(from: item.completedAt))")
            }
        }
        lines.append("")

        lines.append("## 任务")
        lines.append("基于上述状态，生成**下一个**具体、15 分钟可启动的动作。通过 `record_next_action` 工具返回。")

        return lines.joined(separator: "\n")
    }

    private static func fallback(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（未填写）" : t
    }

    // MARK: - Tool schema

    /// JSON schema for the `record_next_action` tool. Claude is forced to call
    /// it via `tool_choice`, which gives us reliable structured output.
    static let toolSchemaJSON: String = """
    {
      "type": "object",
      "properties": {
        "next_action": {
          "type": "string",
          "description": "单句动作，动词开头，15 分钟内能启动，具体到对象/工具/数字。不要列表、不要多条。"
        },
        "estimated_minutes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 60,
          "description": "预计开始到推进可见进度的分钟数。大部分应在 5~20 之间。"
        },
        "level_advance": {
          "type": ["string", "null"],
          "enum": ["week", "day", null],
          "description": "若当前层级目标已完成，建议上层推进到的层级；多数返回 null。"
        }
      },
      "required": ["next_action", "estimated_minutes"]
    }
    """

    static let toolName = "record_next_action"
    static let toolDescription = "记录用户现在就能启动的下一个具体动作。"
}
