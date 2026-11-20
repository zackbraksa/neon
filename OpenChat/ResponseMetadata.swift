import Foundation

struct ResponseMetadata: Decodable, Equatable {
    var responseModel: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var costUSD: Double?
    init(responseModel: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, costUSD: Double? = nil) {
        let model = responseModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.responseModel = model.flatMap { !$0.isEmpty && $0.utf16.count <= 200 ? $0 : nil }
        func token(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 && $0 <= 9_007_199_254_740_991 ? $0 : nil } }
        self.inputTokens = token(inputTokens); self.outputTokens = token(outputTokens); self.totalTokens = token(totalTokens)
        self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    private enum Keys: String, CodingKey { case responseModel, inputTokens, outputTokens, totalTokens, costUSD, model, usage, prompt_tokens, completion_tokens, total_tokens, cost }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        self.init(responseModel: try? values.decode(String.self, forKey: .responseModel),
                  inputTokens: try? values.decode(Int.self, forKey: .inputTokens), outputTokens: try? values.decode(Int.self, forKey: .outputTokens),
                  totalTokens: try? values.decode(Int.self, forKey: .totalTokens), costUSD: try? values.decode(Double.self, forKey: .costUSD))
    }
    static func provider(_ data: Data) -> ResponseMetadata {
        struct Provider: Decodable {
            let metadata: ResponseMetadata
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: Keys.self)
                let usage = try? values.nestedContainer(keyedBy: Keys.self, forKey: .usage)
                metadata = ResponseMetadata(responseModel: try? values.decode(String.self, forKey: .model),
                    inputTokens: try? usage?.decode(Int.self, forKey: .prompt_tokens), outputTokens: try? usage?.decode(Int.self, forKey: .completion_tokens),
                    totalTokens: try? usage?.decode(Int.self, forKey: .total_tokens), costUSD: try? usage?.decode(Double.self, forKey: .cost))
            }
        }
        return (try? JSONDecoder().decode(Provider.self, from: data).metadata) ?? ResponseMetadata()
    }
    var hasValues: Bool { responseModel != nil || inputTokens != nil || outputTokens != nil || totalTokens != nil || costUSD != nil }
    func merging(_ value: ResponseMetadata) -> ResponseMetadata {
        ResponseMetadata(responseModel: value.responseModel ?? responseModel, inputTokens: value.inputTokens ?? inputTokens,
                         outputTokens: value.outputTokens ?? outputTokens, totalTokens: value.totalTokens ?? totalTokens, costUSD: value.costUSD ?? costUSD)
    }
    var caption: String? {
        var parts: [String] = []
        if let totalTokens { parts.append("\(totalTokens.formatted()) tokens") }
        else {
            if let inputTokens { parts.append("\(inputTokens.formatted()) input tokens") }
            if let outputTokens { parts.append("\(outputTokens.formatted()) output tokens") }
        }
        if let costUSD {
            if costUSD == 0 { parts.append("$0.00") }
            else if costUSD < 0.00000001 { parts.append("<$0.00000001") }
            else {
                let digits = costUSD < 0.01 ? 8 : 4
                var amount = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, costUSD)
                while amount.last == "0", amount.count - (amount.firstIndex(of: ".").map { amount.distance(from: amount.startIndex, to: $0) } ?? amount.count) > 3 { amount.removeLast() }
                parts.append("$" + amount)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var breakdown: String {
        if totalTokens == nil { return caption.map { $0 + (costUSD == nil ? "" : " USD") } ?? "" }
        var parts: [String] = []
        if let inputTokens { parts.append("\(inputTokens.formatted()) input tokens") }
        if let outputTokens { parts.append("\(outputTokens.formatted()) output tokens") }
        if let caption { parts.append(caption + (costUSD == nil ? "" : " USD")) }
        return parts.joined(separator: ", ")
    }
}
