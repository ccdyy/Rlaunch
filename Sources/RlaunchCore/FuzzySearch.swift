import Foundation

/// 模糊搜索：大小写不敏感子串匹配优先，失败时用编辑距离 ≤ maxDistance 兜底。
public enum FuzzySearch {

    /// 编辑距离（Levenshtein），带长度上限优化。
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let maxDist = max(aChars.count, bChars.count)
        if aChars.count == 0 { return bChars.count }
        if bChars.count == 0 { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            // 提前终止：整行都超过上限则不可能更优
            if curr.min()! > maxDist { return maxDist + 1 }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }

    /// 判断 name 是否匹配 query。子串命中即 true；否则编辑距离兜底。
    public static func matches(name: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let nameLower = name.lowercased()
        let queryLower = q.lowercased()
        if nameLower.contains(queryLower) { return true }

        // 词首字母缩写匹配，例如 "st" -> "Safari Technology Preview"
        let initials = name.split(separator: " ").compactMap { $0.first?.lowercased() }.joined()
        if initials.contains(queryLower) { return true }

        let maxDistance: Int
        switch q.count {
        case 1: maxDistance = 0
        case 2...4: maxDistance = 1
        default: maxDistance = 2
        }
        // 长度差已超过容错上限时不可能匹配，直接跳过编辑距离计算
        // （搜索时每敲一个键都会对所有应用跑一遍匹配，这个短路很关键）
        if abs(nameLower.count - queryLower.count) > maxDistance { return false }
        return levenshtein(nameLower, queryLower) <= maxDistance
    }
}
