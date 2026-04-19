import Foundation

/// System prompt + tool/schema definitions for the Q&A intake conversation.
///
/// Design philosophy: keep the prompt **frozen** so Anthropic's prompt
/// cache hits on every turn. Volatile context (attachments, existing
/// capacity counts) goes into the user-message preface on the first turn,
/// never into the system block.
enum IntakePrompt {
    // MARK: - Hard constraints surfaced to the model

    /// The five mandatory slots the model must cover before it's allowed
    /// to emit a synthesis. Ordered roughly by importance.
    static let mandatorySlots: [String] = [
        "完成时间：一次性任务 / 有明确截止日 / 开放式",
        "每天愿意花多少分钟推进",
        "完成后的\"成功状态\"一句话描述",
        "当前进度 / 起点（已有什么、还缺什么）",
        "主要障碍 / 已知卡点（你担心什么会拖住自己）",
    ]

    // MARK: - System prompt (stable)

    /// Built once and cached — no timestamps, IDs, or per-session state.
    static let systemPrompt: String = {
        var lines: [String] = []
        lines.append("""
        你是 NextStep 的「规划教练」。NextStep 是一个为 ADHD / 多线程工作者设计的桌面工具，
        原则是「帮你启动、不是帮你收纳」：每个项目只展示此刻能立刻开始的那一个动作。

        你现在的工作模式：**对话式 intake**。用户会说一件他想做的事（可能模糊，可能附带文档），
        你要通过 **结构化问题卡**（像 Claude 的 Plan 模式）问 8-12 个问题，把它拆清楚，最后输出
        一个**一键可创建**的项目或临时任务定义。

        ## 必须覆盖的槽位（合成前一个都不能缺）

        """)
        for slot in mandatorySlots {
            lines.append("- \(slot)")
        }
        lines.append("""

        上述 5 点是下限——没拿到就继续问。在此基础上可以再问 3-7 个项目相关的具体问题
        （月/周/日目标拆分、已有资源、愿意何时检查进度等）。**不要问超过 12 轮**——
        用户会累。

        ## 问题卡风格

        - 每轮最多 4 个问题。相关的合在一起问，不相关的拆开。
        - 每题都要**友好、具体**，避免抽象。
        - **能给选项就给选项**（2-5 个），用户点一下比打字快。始终允许用户自己填。
        - 选项必须**互斥、短**。不要写成 5 行长段落。
        - 用**中文**提问。
        - `progress` 字段填**当前这张卡是第几轮**（1 开始计数）。

        ## 何时合成（synthesize_plan）

        当且仅当以下都成立时，**停止提问，改为调用 `synthesize_plan`**：

        1. 上面 5 个必答槽位都有答案（明确或能合理推断）；
        2. 你能写出一个**动词开头、15 分钟内能启动**的首个具体动作（不是"开始写引言"，而是"打开 Zotero 导出 5 篇关键文献"）；
        3. 你已经问了**至少 6 轮**（更早合成通常信息不够）。

        ## 合成规则

        **判定 project vs temp_task：**
        - `temp_task` = 一步就结束（交电费、提醒去取快递、预约医生）。通常 ≤1 天、≤1 次动作。
        - `project` = 需要多步推进（写论文、学 Swift、搬家、跑一次半马）。

        **project 合成要求：**
        - `level` 在 month/week/day 里选一个：
          - 有截止日且 > 3 周 → month 级
          - 1-3 周 → week 级
          - 当天或两三天内 → day 级
        - `month_goal` / `week_goal` / `day_action`：**根据用户答案** 拆出三层目标；
          没有月级维度就写"（不适用）"，不要瞎编。
        - `seeded_next_action`：动词开头，15 分钟内能启动，具体到对象/工具/数字。
          **不要重复** 用户已经完成的事。
        - `estimated_minutes`：1-60 的整数。
        - `daily_minutes`：用户说的每天愿意花多少分钟（整数；用户没说就写 0）。
        - `deadline`：ISO `YYYY-MM-DD`，开放式项目写 null。

        **temp_task 合成要求：**
        - `text`：一句话，保留用户的原意。去掉明显的日期词（"明天下午 5 点"）—— 放进 `due_date`。
        - `due_date`：ISO `YYYY-MM-DD` 或 `YYYY-MM-DDTHH:mm`；没时间写 null。

        ## 输出约束

        **每一轮你都必须只做一件事**：要么调用 `ask_questions`（继续问），要么调用 `synthesize_plan`（合成）。
        不要在正文里写解释——所有内容都进工具参数里。

        第一轮建议：友好地开场，问 1-2 个宽泛问题打开话头（"想规划什么？" + "你希望在什么时候前完成？"）。
        """)
        return lines.joined(separator: "\n")
    }()

    // MARK: - Tool schemas (Claude Messages API)

    /// `ask_questions` — the ongoing-chat branch.
    static let askQuestionsToolName = "ask_questions"
    static let askQuestionsToolDesc = "继续问用户 1-4 个结构化问题来填满必答槽位。"

    /// `synthesize_plan` — the terminal branch.
    static let synthesizeToolName = "synthesize_plan"
    static let synthesizeToolDesc = "信息足够了，输出最终项目或临时任务定义，供 NextStep 一键创建。"

    /// Schema for the ask_questions tool input.
    static let askQuestionsSchemaJSON: String = """
    {
      "type": "object",
      "properties": {
        "preamble": {
          "type": "string",
          "description": "在问题上方显示的一行友好的上下文过渡句（可选，空字符串或省略都行）。"
        },
        "questions": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "description": "本卡内稳定的短 id（如 q1）。" },
              "text": { "type": "string", "description": "问题原文，中文，友好具体。" },
              "choices": {
                "type": "array",
                "items": { "type": "string" },
                "description": "可选答案（2-5 个，短）。无选项则为空数组。"
              },
              "allowFreeText": {
                "type": "boolean",
                "description": "是否允许用户自己输入。默认 true。"
              }
            },
            "required": ["id", "text"]
          }
        },
        "progress": {
          "type": "integer",
          "minimum": 1,
          "maximum": 20,
          "description": "本卡是第几轮（1-based）。"
        }
      },
      "required": ["questions"]
    }
    """

    /// Schema for synthesize_plan. Branches on `kind`. Note: we use
    /// `oneOf` in the strict OpenAI schema, but Claude's tool schema
    /// accepts this looser shape just fine (it validates server-side).
    static let synthesizePlanSchemaJSON: String = """
    {
      "type": "object",
      "properties": {
        "kind": {
          "type": "string",
          "enum": ["project", "temp_task"]
        },
        "project": {
          "type": ["object", "null"],
          "properties": {
            "name": { "type": "string" },
            "level": { "type": "string", "enum": ["month", "week", "day"] },
            "month_goal": { "type": "string" },
            "week_goal": { "type": "string" },
            "day_action": { "type": "string" },
            "seeded_next_action": { "type": "string" },
            "estimated_minutes": { "type": ["integer", "null"], "minimum": 1, "maximum": 60 },
            "daily_minutes": { "type": "integer", "minimum": 0 },
            "deadline": { "type": ["string", "null"], "description": "YYYY-MM-DD 或 null。" }
          },
          "required": ["name", "level", "month_goal", "week_goal", "day_action", "seeded_next_action", "daily_minutes"]
        },
        "temp_task": {
          "type": ["object", "null"],
          "properties": {
            "text": { "type": "string" },
            "due_date": { "type": ["string", "null"] }
          },
          "required": ["text"]
        }
      },
      "required": ["kind"]
    }
    """

    // MARK: - Strict schema for OpenAI / Ollama (oneOf two branches)

    /// OpenAI's json_schema strict mode needs `additionalProperties: false`
    /// on every object and every key listed in `required`. We split into
    /// two top-level branches via `oneOf` so the model picks one.
    nonisolated(unsafe) static let strictTurnSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["turn_kind", "card", "synthesis"],
        "properties": [
            "turn_kind": [
                "type": "string",
                "enum": ["card", "synthesis"],
                "description": "要么继续问（card），要么合成最终结果（synthesis）。",
            ],
            "card": [
                "type": ["object", "null"],
                "additionalProperties": false,
                "required": ["preamble", "questions", "progress"],
                "properties": [
                    "preamble": ["type": ["string", "null"]],
                    "questions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["id", "text", "choices", "allowFreeText"],
                            "properties": [
                                "id": ["type": "string"],
                                "text": ["type": "string"],
                                "choices": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                ],
                                "allowFreeText": ["type": "boolean"],
                            ],
                        ],
                    ],
                    "progress": ["type": ["integer", "null"]],
                ],
            ],
            "synthesis": [
                "type": ["object", "null"],
                "additionalProperties": false,
                "required": ["kind", "project", "temp_task"],
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["project", "temp_task"],
                    ],
                    "project": [
                        "type": ["object", "null"],
                        "additionalProperties": false,
                        "required": [
                            "name", "level",
                            "month_goal", "week_goal", "day_action",
                            "seeded_next_action", "estimated_minutes",
                            "daily_minutes", "deadline",
                        ],
                        "properties": [
                            "name": ["type": "string"],
                            "level": ["type": "string", "enum": ["month", "week", "day"]],
                            "month_goal": ["type": "string"],
                            "week_goal": ["type": "string"],
                            "day_action": ["type": "string"],
                            "seeded_next_action": ["type": "string"],
                            "estimated_minutes": ["type": ["integer", "null"]],
                            "daily_minutes": ["type": "integer"],
                            "deadline": ["type": ["string", "null"]],
                        ],
                    ],
                    "temp_task": [
                        "type": ["object", "null"],
                        "additionalProperties": false,
                        "required": ["text", "due_date"],
                        "properties": [
                            "text": ["type": "string"],
                            "due_date": ["type": ["string", "null"]],
                        ],
                    ],
                ],
            ],
        ],
    ]

    /// Build the opening user message for a session. Includes attached
    /// documents (if any) and today's date so the model can resolve
    /// relative phrases like "下个月".
    static func openingUserPrompt(topic: String, attachments: [AttachmentPayload]) -> String {
        var lines: [String] = []

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd EEEE"
        df.locale = Locale(identifier: "zh_CN")
        lines.append("今天是 \(df.string(from: .now))。")
        lines.append("")

        if !attachments.isEmpty {
            lines.append("我附带了 \(attachments.count) 个参考文档：")
            for a in attachments {
                let size = a.content.count
                lines.append("""
                <attachment filename="\(a.filename)" chars="\(size)">
                \(a.content)
                </attachment>
                """)
            }
            lines.append("")
        }

        lines.append("我想规划的事：")
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmed.isEmpty ? "（我还没说清楚，你先问我几个问题吧）" : trimmed)
        lines.append("")
        lines.append("请开始问问题。")

        return lines.joined(separator: "\n")
    }
}

/// Plain attachment payload — filename + extracted text. Defined here
/// rather than in AttachmentIngest because the prompt helper needs it
/// and we want IntakePrompt compilable without the ingest layer.
struct AttachmentPayload: Sendable, Equatable, Hashable {
    let filename: String
    /// Already-extracted plain text, already length-capped.
    let content: String
}
