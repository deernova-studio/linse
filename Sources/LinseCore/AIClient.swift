// AI 辅助：调用视觉模型看图给初值。支持两种接口协议：Anthropic（Messages API）和 OpenAI 兼容（/chat/completions）。
// 直接发 HTTP 请求；macOS 的 API Key 保存在本地配置，iOS 仍使用钥匙串。
import Foundation
import Security

public enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case openai, anthropic

    public var defaultModel: String {
        switch self {
        case .openai: "gpt-5.5"
        case .anthropic: "claude-opus-5-5"
        }
    }
}
public enum AIEffort: String, Codable, CaseIterable, Sendable { case auto = "", low, medium, high, xhigh, max }

public struct AISettings: Codable, Equatable, Sendable {
    public var proto: AIProtocol = .openai
    public var baseUrl = ""
    public var model = AIProtocol.openai.defaultModel
    public var effort: AIEffort = .auto
    public var fast = false
    public init() {}
    enum CodingKeys: String, CodingKey { case proto = "protocol", baseUrl, model, effort, fast }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        proto = (try? c.decode(AIProtocol.self, forKey: .proto)) ?? .openai
        baseUrl = (try? c.decode(String.self, forKey: .baseUrl)) ?? ""
        let savedModel = (try? c.decode(String.self, forKey: .model)) ?? ""
        model = savedModel.isEmpty ? proto.defaultModel : savedModel
        effort = (try? c.decode(AIEffort.self, forKey: .effort)) ?? .auto
        fast = (try? c.decode(Bool.self, forKey: .fast)) ?? false
    }
}

public struct AIError: LocalizedError, Sendable {
    public let message: String, status: Int?
    public init(_ m: String, status: Int? = nil) { message = m; self.status = status }
    public var errorDescription: String? { message }

    /// 只有明确拒绝某个可选参数时才做兼容重试，网关故障不应触发重复调用。
    func rejectsParameter(_ names: [String]) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let text = message.lowercased()
        return names.contains(where: { text.contains($0) }) &&
            ["unsupported", "not supported", "unrecognized", "unknown", "unexpected", "not permitted", "not allowed", "不支持"].contains(where: { text.contains($0) })
    }
}

/// iOS 使用的 API Key 存储；macOS 使用 LocalAIConfigurationStore。
public enum AIKeychain {
    static let service = "app.linse.ai", account = "api-key"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }

    public static func load() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        if key.isEmpty { return SecItemDelete(query as CFDictionary) == errSecSuccess }
        let st = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return st == errSecSuccess
    }
}

public struct AIImages: Sendable {
    public var source: String, target: String // base64 JPEG
    public var stats: Data?                    // 两张图的实测统计（JSON）
    public init(source: String, target: String, stats: Data?) { self.source = source; self.target = target; self.stats = stats }
}

public enum AIClient {
    static let system = """
    你是专业的照片调色师，熟悉 Lightroom / Camera Raw。用户会给你两张图：第一张是"原图"，第二张是"目标风格图"。
    你的任务：判断目标图的调色风格（而不是画面内容），给出把原图调成这种风格的一组滑块值。

    注意区分"风格"和"内容"：例如目标图是黑色背景，不代表要把原图压暗；目标图是夜景，不代表白天的原图要变成夜晚。
    只迁移影调和色彩倾向：明暗反差、黑位/白位处理、冷暖、饱和度、肤色处理、阴影高光分色等。

    滑块含义（数值范围）：
    - temperature 色温 -100..100（正=暖），tint 色调 -100..100（正=洋红，负=绿）
    - exposure 曝光 -3..3 EV
    - contrast 对比度、highlights 高光、shadows 阴影、whites 白色、blacks 黑色：-100..100
    - vibrance 自然饱和度、saturation 饱和度：-100..100
    - hsl：red/orange/yellow/green/aqua/blue/purple/magenta 各有 hue（-100..100，100≈偏移 30°）、sat、lum（-100..100）
    - grading 颜色分级：shadows/midtones/highlights 各有 hue（0..360）、sat（0..100）
    - effects 质感：clarity 清晰度、dehaze 去雾、vignette 暗角（负值压暗四角）都是 -100..100；grain 颗粒 0..100、grainSize 颗粒大小 0..100。
      这几项统计量量不出来，要靠你看图判断：胶片感通常有颗粒和轻微暗角，通透感常配合轻微去雾，柔和人像清晰度为负

    工作方法（按顺序来，先诊断再动手）：
    1. 先看图并结合"实测统计"诊断两张图的差异。实测统计是对像素的精确测量，比你看图估计更可信；看图判断和统计冲突时，以统计为准，但要用看图去判断差异是"风格"还是"内容"。
       统计说明：L* 为 0-100 的明度分位；a*>0 偏洋红、<0 偏绿，b*>0 偏黄（暖）、<0 偏蓝（冷）；"中性色"是低饱和像素（白墙、白衣服、灰色）；统计已降低大面积纯色背景的权重。
    2. 按固定顺序决定滑块：白平衡 → 曝光 → 白色/黑色 → 高光/阴影 → 对比度 → 自然饱和度/饱和度 → 混色器 HSL → 颜色分级。后面的滑块只处理前面没解决的部分，不要用多个滑块互相抵消。
    3. 幅度要克制：色温一般在 ±30、色调在 ±20 以内，除非目标明显偏色；单个滑块超过 ±60 要有很强的理由。没有把握的滑块填 0。
    4. 人像：肤色优先，用混色器的红色/橙色调肤色，不要为了背景的冷暖牺牲肤色。
    5. 输出前自检：肤色是否自然、有没有造成大面积高光或暗部削波、有没有极端值、有没有把内容差异当成风格。发现问题就收敛数值。

    只输出一个 JSON 对象，不要输出其他文字，格式：
    {
      "source_scene": "原图内容一句话",
      "target_scene": "目标图内容一句话",
      "style_summary": "目标风格的特点，2-3 句",
      "content_not_style": ["目标图里属于内容、不该迁移的东西"],
      "is_portrait": true,
      "params": {
        "temperature": 0, "tint": 0, "exposure": 0, "contrast": 0, "highlights": 0, "shadows": 0, "whites": 0, "blacks": 0,
        "vibrance": 0, "saturation": 0,
        "hsl": { "orange": { "hue": 0, "sat": 0, "lum": 0 } },
        "grading": { "shadows": { "hue": 0, "sat": 0 }, "midtones": { "hue": 0, "sat": 0 }, "highlights": { "hue": 0, "sat": 0 } },
        "effects": { "clarity": 0, "dehaze": 0, "vignette": 0, "grain": 0, "grainSize": 25 }
      },
      "reasons": [ { "slider": "色温", "why": "为什么这样调" } ]
    }
    """

    // 结构化输出的 JSON Schema。数值范围写在提示词里（结构化输出不支持 minimum/maximum），返回后再限幅
    static let schema: [String: Any] = {
        let num: [String: Any] = ["type": "number"]
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": props.keys.sorted(), "properties": props]
        }
        let band = obj(["hue": num, "sat": num, "lum": num]), wheel = obj(["hue": num, "sat": num])
        return obj([
            "source_scene": ["type": "string"], "target_scene": ["type": "string"], "style_summary": ["type": "string"],
            "content_not_style": ["type": "array", "items": ["type": "string"]],
            "is_portrait": ["type": "boolean"],
            "params": obj([
                "temperature": num, "tint": num, "exposure": num, "contrast": num, "highlights": num, "shadows": num, "whites": num, "blacks": num,
                "vibrance": num, "saturation": num,
                "hsl": obj(Dictionary(uniqueKeysWithValues: HSLBand.allCases.map { ($0.key, band as Any) })),
                "grading": obj(["shadows": wheel, "midtones": wheel, "highlights": wheel]),
                "effects": obj(["clarity": num, "dehaze": num, "vignette": num, "grain": num, "grainSize": num]),
            ]),
            "reasons": ["type": "array", "items": obj(["slider": ["type": "string"], "why": ["type": "string"]])],
        ])
    }()

    /// OpenAI 兼容地址只填了域名时（如 https://api.example.com），按惯例补上 /v1
    public static func openaiBase(_ url: String) -> String {
        var raw = url.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { raw = "https://api.openai.com/v1" }
        while raw.hasSuffix("/") { raw.removeLast() }
        if let u = URL(string: raw), u.path.isEmpty || u.path == "/" { return raw + "/v1" }
        return raw
    }

    static func anthropicBase(_ url: String) -> String {
        var raw = url.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { raw = "https://api.anthropic.com" }
        while raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }

    public static func urlOK(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return true }
        guard let u = URL(string: v), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https", u.host != nil else { return false }
        return true
    }

    static func userText(_ imgs: AIImages?, _ prompt: String) -> String {
        guard let s = imgs?.stats, let t = String(data: s, encoding: .utf8) else { return prompt }
        return "\(prompt)\n\n实测统计（JSON，source=原图，target=目标图）：\n\(t)"
    }

    static func send(_ req: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var msg = String(data: data.prefix(600), encoding: .utf8) ?? ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                msg = (j["error"] as? [String: Any])?["message"] as? String ?? j["error"] as? String ?? j["message"] as? String ?? msg
            }
            let summary: String
            switch code {
            case 502, 503, 504:
                summary = "服务或上游模型暂时不可用（HTTP \(code)）。请稍后重试；持续失败时，请向服务商确认该模型和接口是否可用。"
            case 401, 403:
                summary = "接口拒绝访问（HTTP \(code)）。请检查 API Key 和模型使用权限。"
            case 429:
                summary = "请求受限或额度不足（HTTP 429）。请稍后重试，或检查服务商的账户额度。"
            default:
                summary = "接口返回 HTTP \(code)。"
            }
            let host = req.url?.host.map { "\n服务：\($0)" } ?? ""
            let detail = msg.isEmpty ? "" : "\n详情：\(msg.prefix(300))"
            throw AIError(summary + host + detail, status: code)
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError("接口返回的不是 JSON") }
        return j
    }

    static func request(_ url: String, key: String, timeout: TimeInterval, headers: [String: String], body: [String: Any]?) throws -> URLRequest {
        guard let u = URL(string: url) else { throw AIError("地址格式不对：\(url)") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    static func anthropicHeaders(_ key: String, betas: [String] = []) -> [String: String] {
        var h = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        if !betas.isEmpty { h["anthropic-beta"] = betas.joined(separator: ",") }
        return h
    }

    /// 服务端兜底（主模型拒答时由服务端换模型重试）只对支持它的模型、官方地址开启
    static func supportsFallback(_ model: String) -> Bool {
        ["claude-opus-5", "claude-fable-5", "claude-sonnet-5-5"].contains { model.hasPrefix($0) }
    }

    static func callAnthropic(_ s: AISettings, key: String, imgs: AIImages?, prompt: String, maxTokens: Int, structured: Bool, session: URLSession) async throws -> String {
        var content: [[String: Any]] = []
        if let imgs {
            content += [
                ["type": "text", "text": "原图："],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imgs.source]],
                ["type": "text", "text": "目标风格图："],
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imgs.target]],
            ]
        }
        content.append(["type": "text", "text": userText(imgs, prompt)])
        var body: [String: Any] = ["model": s.model, "max_tokens": maxTokens, "messages": [["role": "user", "content": content]]]
        if imgs != nil { body["system"] = system }
        var oc: [String: Any] = [:]
        if s.effort != .auto { oc["effort"] = s.effort.rawValue }
        if imgs != nil, structured { oc["format"] = ["type": "json_schema", "schema": schema] }
        if !oc.isEmpty { body["output_config"] = oc }
        var betas: [String] = []
        if s.fast {
            // 快速模式：beta + speed: "fast"（Opus 5.5 / 5 / 4.8，仅官方接口）
            betas.append("fast-mode-2026-02-01")
            body["speed"] = "fast"
        } else if s.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty, supportsFallback(s.model) {
            betas.append("server-side-fallback-2026-07-01")
            body["fallbacks"] = "default"
        }
        let req = try request(anthropicBase(s.baseUrl) + "/v1/messages", key: key, timeout: imgs != nil ? 180 : 30, headers: anthropicHeaders(key, betas: betas), body: body)
        let j = try await send(req, session: session)
        if j["stop_reason"] as? String == "refusal" { throw AIError("模型拒绝了这次请求") }
        return ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    static func callOpenAI(_ s: AISettings, key: String, imgs: AIImages?, prompt: String, maxTokens: Int, structured: Bool, session: URLSession) async throws -> String {
        var user: [[String: Any]] = []
        if let imgs {
            user += [
                ["type": "text", "text": "原图："],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imgs.source)"]],
                ["type": "text", "text": "目标风格图："],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imgs.target)"]],
            ]
        }
        user.append(["type": "text", "text": userText(imgs, prompt)])
        var messages: [[String: Any]] = []
        if imgs != nil { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        var body: [String: Any] = ["model": s.model, "max_completion_tokens": maxTokens, "messages": messages]
        if s.effort != .auto { body["reasoning_effort"] = s.effort.rawValue }
        if s.fast { body["service_tier"] = "priority" }
        if imgs != nil, structured {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "camera_raw_settings", "schema": schema, "strict": false]]
        }
        func submit(_ body: [String: Any]) async throws -> [String: Any] {
            let req = try request(openaiBase(s.baseUrl) + "/chat/completions", key: key, timeout: imgs != nil ? 180 : 30,
                                  headers: ["Authorization": "Bearer \(key)"], body: body)
            return try await send(req, session: session)
        }
        let j: [String: Any]
        do {
            j = try await submit(body)
        } catch let error as AIError where error.rejectsParameter(["max_completion_tokens"]) {
            // 少数旧网关仅接受 max_tokens；只在服务端明确拒绝新字段时回退一次。
            try Task.checkCancellation()
            body.removeValue(forKey: "max_completion_tokens")
            body["max_tokens"] = maxTokens
            j = try await submit(body)
        }
        guard let choice = (j["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AIError("接口未返回聊天结果。请向服务商确认当前模型支持 Chat Completions 接口。")
        }
        if choice["finish_reason"] as? String == "length" {
            throw AIError("模型已达到输出长度限制，未完成回复。请降低思考强度后重试。")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AIError("模型拒绝了这次请求。") }
        return message["content"] as? String ?? ""
    }

    static func call(_ s: AISettings, key: String, imgs: AIImages?, prompt: String, maxTokens: Int, session: URLSession) async throws -> String {
        guard !key.isEmpty else { throw AIError("还没有填写 API Key") }
        func go(_ structured: Bool) async throws -> String {
            s.proto == .openai
                ? try await callOpenAI(s, key: key, imgs: imgs, prompt: prompt, maxTokens: maxTokens, structured: structured, session: session)
                : try await callAnthropic(s, key: key, imgs: imgs, prompt: prompt, maxTokens: maxTokens, structured: structured, session: session)
        }
        do {
            return try await go(true)
        } catch let e as AIError where imgs != nil && e.rejectsParameter(["response_format", "json_schema", "output_config.format", "structured output"]) {
            // 部分网关或模型不支持结构化输出参数，去掉它再试一次，靠提示词约束格式
            try Task.checkCancellation()
            return try await go(false)
        }
    }

    /// 从接口动态获取可用模型列表
    public static func listModels(_ s: AISettings, key: String, session: URLSession = .shared) async throws -> [String] {
        guard !key.isEmpty else { throw AIError("还没有填写 API Key") }
        if s.proto == .openai {
            let j = try await send(try request(openaiBase(s.baseUrl) + "/models", key: key, timeout: 20, headers: ["Authorization": "Bearer \(key)"], body: nil), session: session)
            return ((j["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.sorted()
        }
        var ids: [String] = [], after: String?
        for _ in 0..<20 {
            var url = anthropicBase(s.baseUrl) + "/v1/models?limit=1000"
            if let after, let a = after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { url += "&after_id=\(a)" }
            let j = try await send(try request(url, key: key, timeout: 20, headers: anthropicHeaders(key), body: nil), session: session)
            ids += ((j["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            guard j["has_more"] as? Bool == true, let last = j["last_id"] as? String else { break }
            after = last
        }
        return ids
    }

    public static func test(_ s: AISettings, key: String, session: URLSession = .shared) async throws -> String {
        let t = try await call(s, key: key, imgs: nil, prompt: "只回复两个字：连通", maxTokens: 1024, session: session)
        let r = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !r.isEmpty else { throw AIError("接口已响应，但模型没有返回有效文字。请尝试降低思考强度，或向服务商确认模型是否可用。") }
        return r
    }

    /// 看图分析；取消外层 Task 会中止网络请求
    public static func analyze(_ s: AISettings, key: String, images: AIImages, session: URLSession = .shared) async throws -> AIAnalysis {
        let text = try await call(s, key: key, imgs: images, prompt: "请分析并按要求输出 JSON。", maxTokens: 16000, session: session)
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let j = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { throw AIError("模型没有返回 JSON") }
        return AIAnalysis(json: j)
    }
}
