import Foundation

struct CalcResult {
    let title: String
    let detail: String
    let copy: String
    let tag: String
    let value: Double?

    init(title: String, detail: String, copy: String, tag: String, value: Double? = nil) {
        self.title = title; self.detail = detail; self.copy = copy; self.tag = tag
        self.value = value ?? Double(copy)
    }

    func remember() { if let value, value.isFinite { Calc.ans = value } }
}

// Everything that can be answered by computing rather than searching:
// arithmetic, percentages, unit / currency / base conversion, date maths, world time.
enum Calc {
    static var ans: Double?

    static func answer(_ raw: String) -> CalcResult? {
        var q = raw.lowercased().trimmingCharacters(in: .whitespaces)
        q = q.replacingOccurrences(of: "^(what is|what's|whats|calculate|calc|compute|how much is|convert|=)\\s+", with: "", options: .regularExpression)
        q = q.replacingOccurrences(of: "[?=\\s]+$", with: "", options: .regularExpression)
        guard !q.isEmpty else { return nil }
        return worldTime(q) ?? dateMath(q) ?? baseConvert(q) ?? convert(q) ?? arithmetic(q)
    }

    // capture groups of a whole-string match
    static func rx(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    static func sub(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    // MARK: formatting

    static func plain(_ v: Double, sig: Int = 12) -> String {
        if v.isNaN { return "undefined" }
        if v.isInfinite { return v < 0 ? "-∞" : "∞" }
        let a = abs(v)
        if a != 0, a >= 1e15 || a < 1e-7 { return String(format: "%.\(min(sig, 8))g", v) }
        let r = Double(String(format: "%.\(sig)g", v)) ?? v
        if r == r.rounded() { return String(format: "%.0f", r) }
        var s = String(format: "%.10f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func pretty(_ v: Double, sig: Int = 12) -> String {
        let p = plain(v, sig: sig)
        guard !p.contains("e"), !p.contains("∞"), p != "undefined" else { return p }
        let parts = p.split(separator: ".", maxSplits: 1)
        var whole = String(parts[0]), sign = ""
        if whole.hasPrefix("-") { sign = "-"; whole.removeFirst() }
        var grouped = ""
        for (i, c) in whole.reversed().enumerated() {
            if i > 0, i % 3 == 0 { grouped.append(",") }
            grouped.append(c)
        }
        return sign + String(grouped.reversed()) + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func show(_ expr: String) -> String {
        sub(sub(expr.replacingOccurrences(of: "*", with: " × ").replacingOccurrences(of: "/", with: " ÷ "), "\\s+", " "), " \\^", "^")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: arithmetic

    // natural phrasing -> operators
    static func words(_ q: String) -> String {
        var s = q
        // Commas inside function calls separate arguments, even before three digits.
        let chars = Array(s)
        var calls: [Bool] = [], normalized = ""
        for (i, c) in chars.enumerated() {
            if c == "(" {
                let prefix = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                calls.append(calls.last == true || rx(prefix, "[a-z][a-z0-9]*$") != nil)
            }
            let grouped = c == "," && calls.last != true && i > 0 && chars[i - 1].isNumber &&
                i + 3 < chars.count && chars[(i + 1)...(i + 3)].allSatisfy(\.isNumber) &&
                (i + 4 == chars.count || !chars[i + 4].isNumber)
            if !grouped { normalized.append(c) }
            if c == ")", !calls.isEmpty { calls.removeLast() }
        }
        s = normalized
        s = sub(s, "[$€£¥]", "")
        for (a, b) in [("×", "*"), ("÷", "/"), ("−", "-"), ("–", "-"), ("**", "^"), ("√", "sqrt "), ("π", "pi")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        let phrases: [(String, String)] = [
            ("\\b(to|raised to) the power( of)?\\b", "^"), ("\\b(multiplied by|times)\\b", "*"), ("\\b(divided by|over)\\b", "/"),
            ("\\bplus\\b", "+"), ("\\bminus\\b", "-"), ("\\bsquared\\b", "^2"), ("\\bcubed\\b", "^3"),
            ("\\b(the )?square root( of)?\\b", "sqrt "), ("\\b(the )?cube root( of)?\\b", "cbrt "),
            ("\\bhalf( of)?\\b", "0.5*"), ("\\ba third of\\b", "(1/3)*"), ("\\ba quarter of\\b", "0.25*"),
            ("\\bpercent(age)?\\b", "%"), ("\\bmodulo\\b", "mod"),
            ("(?<=\\d)\\s*thousand\\b", "k"), ("(?<=\\d)\\s*million\\b", "m"), ("(?<=\\d)\\s*billion\\b", "b"),
            ("(?<=[\\d)])\\s*x\\s*(?=[\\d(.])", "*"),
        ]
        for (p, r) in phrases { s = sub(s, p, r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func evaluate(_ expr: String) -> (Double, Bool, Bool)? { // value, isPercent, significant
        var p = Parser(expr)
        guard let v = p.run() else { return nil }
        return (v.pct ? v.v / 100 : v.v, false, p.ops > 0)
    }

    static func number(_ expr: String) -> Double? { evaluate(words(expr))?.0 }

    static func arithmetic(_ q: String) -> CalcResult? {
        func out(_ v: Double, _ shown: String, suffix: String = "") -> CalcResult {
            CalcResult(title: pretty(v) + suffix, detail: shown, copy: plain(v), tag: "Calculator", value: v)
        }
        if let m = rx(q, "^(.+?)\\s+(?:is|as|are)\\s+(?:what|a)\\s+(?:percent|percentage|%)\\s+of\\s+(.+)$"),
           let a = number(m[1]), let b = number(m[2]), b != 0 {
            return out(a / b * 100, "\(m[1]) ÷ \(m[2])", suffix: "%")
        }
        if let m = rx(q, "^(.+?)\\s*(?:%|percent)\\s*off(?:\\s+of)?\\s+(.+)$"), let p = number(m[1]), let b = number(m[2]) {
            return out(b * (1 - p / 100), "\(m[2]) less \(plain(p))% · you save \(pretty(b * p / 100))")
        }
        if let m = rx(q, "^(.+?)\\s*(?:%|percent)\\s*(tip|tax|vat|gst|interest)\\s+on\\s+(.+)$"), let p = number(m[1]), let b = number(m[3]) {
            return out(b * p / 100, "\(m[2]) on \(m[3]) · total \(pretty(b * (1 + p / 100)))")
        }
        if let m = rx(q, "^(?:percent(?:age)? )?(?:change|increase|decrease) from\\s+(.+?)\\s+to\\s+(.+)$"),
           let a = number(m[1]), let b = number(m[2]), a != 0 {
            let d = (b - a) / abs(a) * 100
            return out(d, "from \(m[1]) to \(m[2])", suffix: "%")
        }

        let expr = words(q)
        if ["pi", "tau", "phi", "ans"].contains(expr), let r = evaluate(expr) { return out(r.0, expr) }
        if let r = evaluate(expr), r.2 { return out(r.0, show(expr)) }

        // still typing: drop a dangling operator and close open brackets
        var fixed = sub(expr, "[-+*/^(,.\\s]+$", "")
        let open = fixed.filter { $0 == "(" }.count - fixed.filter { $0 == ")" }.count
        if open > 0 { fixed += String(repeating: ")", count: open) }
        if fixed != expr, !fixed.isEmpty, let r = evaluate(fixed), r.2 { return out(r.0, show(fixed)) }
        return nil
    }

    struct Value {
        var v: Double
        var pct = false
        var n: Double { pct ? v / 100 : v }
    }

    struct Parser {
        enum Tok: Equatable { case num(Double), id(String), op(Character) }
        var toks: [Tok] = []
        var i = 0
        var ops = 0
        var ok = true

        init(_ text: String) {
            let c = Array(text)
            var k = 0
            while k < c.count {
                let ch = c[k]
                if ch == " " { k += 1; continue }
                if ch.isNumber || (ch == "." && k + 1 < c.count && c[k + 1].isNumber) {
                    if ch == "0", k + 1 < c.count, c[k + 1] == "x" || c[k + 1] == "b" {
                        let radix = c[k + 1] == "x" ? 16 : 2
                        var j = k + 2
                        while j < c.count, c[j].isHexDigit { j += 1 }
                        if j > k + 2, let v = UInt64(String(c[(k + 2)..<j]), radix: radix) {
                            toks.append(.num(Double(v))); ops += 1; k = j; continue
                        }
                    }
                    var j = k
                    while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }
                    if j + 1 < c.count, c[j] == "e", c[j + 1].isNumber || ((c[j + 1] == "-" || c[j + 1] == "+") && j + 2 < c.count && c[j + 2].isNumber) {
                        j += 2
                        while j < c.count, c[j].isNumber { j += 1 }
                    }
                    guard var v = Double(String(c[k..<j])) else { ok = false; return }
                    // 5k, 2m, 3b
                    if j < c.count, let mult = ["k": 1e3, "m": 1e6, "b": 1e9][c[j]], j + 1 == c.count || !c[j + 1].isLetter {
                        v *= mult; j += 1; ops += 1
                    }
                    toks.append(.num(v)); k = j
                } else if ch.isLetter {
                    var j = k
                    while j < c.count, c[j].isLetter || c[j].isNumber { j += 1 }
                    toks.append(.id(String(c[k..<j]))); k = j
                } else if "+-*/^(),!%".contains(ch) {
                    toks.append(.op(ch)); k += 1
                } else { ok = false; return }
            }
        }

        var peek: Tok? { i < toks.count ? toks[i] : nil }
        func isOp(_ c: Character) -> Bool { peek == .op(c) }

        func startsPrimary(_ t: Tok?) -> Bool {
            switch t {
            case .num?: return true
            case .id(let s)?: return s != "of" && s != "mod"
            case .op(let c)?: return c == "("
            default: return false
            }
        }

        mutating func run() -> Value? {
            guard ok, !toks.isEmpty, let v = expr(), i == toks.count, v.v.isFinite || v.v.isInfinite else { return nil }
            return v
        }

        mutating func expr() -> Value? {
            guard var l = term() else { return nil }
            while let t = peek, t == .op("+") || t == .op("-") {
                i += 1; ops += 1
                guard let r = term() else { return nil }
                let sign: Double = t == .op("+") ? 1 : -1
                // 80 + 15% means 15% of 80 more
                if r.pct, !l.pct { l = Value(v: l.v * (1 + sign * r.v / 100)) } else if r.pct, l.pct { l = Value(v: l.v + sign * r.v, pct: true) } else {
                    l = Value(v: l.n + sign * r.n)
                }
            }
            return l
        }

        mutating func term() -> Value? {
            guard var l = unary() else { return nil }
            while let t = peek {
                if t == .op("*") || t == .op("/") {
                    i += 1; ops += 1
                    guard let r = unary() else { return nil }
                    l = Value(v: t == .op("*") ? l.n * r.n : l.n / r.n)
                } else if t == .op("%") || t == .id("mod") {
                    i += 1; ops += 1
                    guard let r = unary() else { return nil }
                    l = Value(v: l.n.truncatingRemainder(dividingBy: r.n))
                } else if t == .id("of") {
                    i += 1; ops += 1
                    guard let r = unary() else { return nil }
                    l = Value(v: l.n * r.n)
                } else if case .id = t, startsPrimary(t) {
                    ops += 1
                    guard let r = unary() else { return nil }
                    l = Value(v: l.n * r.n) // 2pi, 30 deg
                } else if t == .op("(") {
                    ops += 1
                    guard let r = unary() else { return nil }
                    l = Value(v: l.n * r.n) // 3(4+5)
                } else { break }
            }
            return l
        }

        mutating func unary() -> Value? {
            if isOp("-") { i += 1; return unary().map { Value(v: -$0.v, pct: $0.pct) } }
            if isOp("+") { i += 1; return unary() }
            guard let b = postfix() else { return nil }
            if isOp("^") {
                i += 1; ops += 1
                guard let e = unary() else { return nil }
                return Value(v: pow(b.n, e.n))
            }
            return b
        }

        mutating func postfix() -> Value? {
            guard var v = primary() else { return nil }
            while true {
                if isOp("!") {
                    i += 1; ops += 1
                    guard v.n >= 0, v.n <= 170 else { return nil }
                    let g = tgamma(v.n + 1)
                    v = Value(v: v.n == v.n.rounded() ? g.rounded() : g)
                } else if isOp("%"), !startsPrimary(i + 1 < toks.count ? toks[i + 1] : nil) {
                    i += 1; ops += 1
                    v = Value(v: v.n, pct: true)
                } else { break }
            }
            return v
        }

        mutating func args() -> [Double]? {
            if isOp("(") {
                i += 1
                var out: [Double] = []
                while true {
                    guard let v = expr() else { return nil }
                    out.append(v.n)
                    if isOp(",") { i += 1; continue }
                    guard isOp(")") else { return nil }
                    i += 1
                    return out
                }
            }
            return unary().map { [$0.n] } // sqrt 16
        }

        mutating func primary() -> Value? {
            guard let t = peek else { return nil }
            i += 1
            switch t {
            case .num(let v): return Value(v: v)
            case .op("("):
                guard let v = expr(), isOp(")") else { return nil }
                i += 1
                return v
            case .id(let name):
                switch name {
                case "pi": return Value(v: .pi)
                case "e": return Value(v: M_E)
                case "tau": return Value(v: 2 * .pi)
                case "phi": return Value(v: (1 + 5.0.squareRoot()) / 2)
                case "ans": return Calc.ans.map { Value(v: $0) }
                case "deg", "degrees", "degree": return Value(v: .pi / 180)
                default: break
                }
                guard let f = Calc.functions[name] else { return nil }
                ops += 1
                guard let a = args(), let r = f(a) else { return nil }
                return Value(v: r)
            default: return nil
            }
        }
    }

    static func one(_ f: @escaping (Double) -> Double) -> ([Double]) -> Double? { { $0.count == 1 ? f($0[0]) : nil } }

    static func gcd(_ a: Double, _ b: Double) -> Double {
        var (x, y) = (abs(a), abs(b))
        while y >= 1 { (x, y) = (y, x.truncatingRemainder(dividingBy: y)) }
        return x
    }

    static func choose(_ n: Double, _ k: Double) -> Double {
        guard n.isFinite, k.isFinite, n >= 0, k >= 0, k <= n, n == n.rounded(), k == k.rounded() else { return .nan }
        let count = min(k, n - k)
        // Central coefficients above this range exceed Double's finite range.
        guard count < 1024 else { return .infinity }
        var value = 1.0
        if count > 0 {
            for i in 1...Int(count) {
                value *= (n - count + Double(i)) / Double(i)
                if !value.isFinite { return value }
            }
        }
        return value.rounded()
    }

    static func permutations(_ n: Double, _ k: Double) -> Double {
        guard n.isFinite, k.isFinite, n >= 0, k >= 0, k <= n, n == n.rounded(), k == k.rounded() else { return .nan }
        guard k <= 170 else { return .infinity }
        var value = 1.0
        for i in 0..<Int(k) { value *= n - Double(i) }
        return value.rounded()
    }

    static let functions: [String: ([Double]) -> Double?] = [
        "sqrt": one { $0.squareRoot() }, "cbrt": one(cbrt), "abs": one(abs), "exp": one(exp),
        "sin": one(sin), "cos": one(cos), "tan": one(tan), "asin": one(asin), "acos": one(acos), "atan": one(atan),
        "sinh": one(sinh), "cosh": one(cosh), "tanh": one(tanh),
        "ln": one(log), "log2": one(log2), "log10": one(log10),
        "log": { $0.count == 2 ? log($0[0]) / log($0[1]) : ($0.count == 1 ? log10($0[0]) : nil) },
        "round": { $0.count == 2 ? ($0[0] * pow(10, $0[1])).rounded() / pow(10, $0[1]) : ($0.count == 1 ? $0[0].rounded() : nil) },
        "floor": one { $0.rounded(.down) }, "ceil": one { $0.rounded(.up) },
        "fact": one { tgamma($0 + 1) }, "rad": one { $0 * .pi / 180 },
        "min": { $0.min() }, "max": { $0.max() }, "sum": { $0.reduce(0, +) },
        "avg": { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) }, "mean": { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) },
        "atan2": { $0.count == 2 ? atan2($0[0], $0[1]) : nil }, "pow": { $0.count == 2 ? pow($0[0], $0[1]) : nil },
        "hypot": { $0.count == 2 ? hypot($0[0], $0[1]) : nil }, "root": { $0.count == 2 ? pow($0[0], 1 / $0[1]) : nil },
        "gcd": { $0.count == 2 ? gcd($0[0], $0[1]) : nil },
        "lcm": { $0.count == 2 && gcd($0[0], $0[1]) != 0 ? abs($0[0] * $0[1]) / gcd($0[0], $0[1]) : nil },
        "ncr": { $0.count == 2 ? choose($0[0], $0[1]) : nil }, "choose": { $0.count == 2 ? choose($0[0], $0[1]) : nil },
        "npr": { $0.count == 2 ? permutations($0[0], $0[1]) : nil },
    ]

    // MARK: number bases

    static func baseConvert(_ q: String) -> CalcResult? {
        guard let m = rx(q, "^(.+?)\\s+(?:to|in|as)\\s+(hex|hexadecimal|binary|bin|octal|oct|decimal|dec)$") else { return nil }
        let src = m[1].trimmingCharacters(in: .whitespaces)
        let target = m[2]
        var v: Double?
        if target.hasPrefix("dec") {
            // a bare token is binary if it is only 0s and 1s, hex if it has hex letters
            if src.hasPrefix("0x") { v = UInt64(src.dropFirst(2), radix: 16).map { Double($0) } } else if src.hasPrefix("0b") {
                v = UInt64(src.dropFirst(2), radix: 2).map { Double($0) }
            } else if rx(src, "^[01]{4,}$") != nil { v = UInt64(src, radix: 2).map { Double($0) } } else if rx(src, "^[0-9a-f]*[a-f][0-9a-f]*$") != nil {
                v = UInt64(src, radix: 16).map { Double($0) }
            }
        } else { v = number(src) }
        guard let v, v >= 0, v < 9e15, v == v.rounded() else { return nil }
        let n = UInt64(v)
        let out: String
        switch target.prefix(3) {
        case "hex": out = "0x" + String(n, radix: 16).uppercased()
        case "bin": out = "0b" + String(n, radix: 2)
        case "oct": out = "0o" + String(n, radix: 8)
        default: out = String(n)
        }
        return CalcResult(title: out, detail: "\(m[1]) in \(target) · dec \(n) · hex \(String(n, radix: 16).uppercased()) · bin \(String(n, radix: 2))",
                          copy: out, tag: "Convert", value: Double(n))
    }

    // MARK: units

    struct Unit {
        let dim: String
        let factor: Double
    }

    static let units: [String: Unit] = {
        var t: [String: Unit] = [:]
        func add(_ dim: String, _ factor: Double, _ names: String) {
            for n in names.split(separator: " ") { t[String(n)] = Unit(dim: dim, factor: factor) }
        }
        add("length", 0.001, "mm millimeter millimetre"); add("length", 0.01, "cm centimeter centimetre")
        add("length", 1, "m meter metre"); add("length", 1000, "km kilometer kilometre klick")
        add("length", 0.0254, "in inch inche \""); add("length", 0.3048, "ft foot feet '")
        add("length", 0.9144, "yd yard"); add("length", 1609.344, "mi mile"); add("length", 1852, "nmi nauticalmile")
        add("length", 1e-6, "um µm micron micrometer"); add("length", 1e-9, "nm nanometer")
        add("length", 9.4607e15, "ly lightyear"); add("length", 1.495978707e11, "au")
        add("mass", 1e-6, "mg milligram"); add("mass", 0.001, "g gram gm"); add("mass", 1, "kg kilogram kilo")
        add("mass", 1000, "t tonne metricton"); add("mass", 907.18474, "ton uston"); add("mass", 0.028349523125, "oz ounce")
        add("mass", 0.45359237, "lb lbs pound"); add("mass", 6.35029318, "st stone")
        add("volume", 0.001, "ml milliliter millilitre cc"); add("volume", 1, "l liter litre"); add("volume", 0.01, "cl"); add("volume", 0.1, "dl")
        add("volume", 0.00492892159375, "tsp teaspoon"); add("volume", 0.01478676478125, "tbsp tablespoon")
        add("volume", 0.0295735295625, "floz fluidounce"); add("volume", 0.2365882365, "cup"); add("volume", 0.473176473, "pt pint")
        add("volume", 0.946352946, "qt quart"); add("volume", 3.785411784, "gal gallon"); add("volume", 1000, "m3 m³ cubicmeter")
        add("time", 0.001, "ms millisecond"); add("time", 1, "s sec second"); add("time", 60, "min minute")
        add("time", 3600, "h hr hour"); add("time", 86400, "d day"); add("time", 604800, "wk week")
        add("time", 2629746, "month mo"); add("time", 31556952, "yr year"); add("time", 315569520, "decade"); add("time", 3155695200, "century")
        add("data", 0.125, "bit"); add("data", 1, "b byte"); add("data", 1e3, "kb kilobyte"); add("data", 1e6, "mb megabyte")
        add("data", 1e9, "gb gigabyte"); add("data", 1e12, "tb terabyte"); add("data", 1e15, "pb petabyte")
        add("data", 1024, "kib kibibyte"); add("data", 1_048_576, "mib mebibyte"); add("data", 1_073_741_824, "gib gibibyte")
        add("data", 1_099_511_627_776, "tib tebibyte"); add("data", 125, "kbit"); add("data", 125_000, "mbit"); add("data", 125_000_000, "gbit")
        add("speed", 1, "m/s mps"); add("speed", 0.44704, "mph mi/h"); add("speed", 1 / 3.6, "kph kmh km/h kmph")
        add("speed", 0.514444, "knot kn kt"); add("speed", 0.3048, "ft/s fps"); add("speed", 299_792_458, "c0 lightspeed")
        add("area", 1, "m2 m² sqm squaremeter squaremetre"); add("area", 0.09290304, "ft2 ft² sqft squarefoot squarefeet")
        add("area", 4046.8564224, "acre"); add("area", 10000, "ha hectare"); add("area", 1e6, "km2 km² sqkm squarekilometer")
        add("area", 2_589_988.110336, "mi2 sqmi squaremile"); add("area", 0.0001, "cm2 cm² sqcm"); add("area", 0.00064516, "in2 sqin squareinch")
        add("energy", 1, "j joule"); add("energy", 1000, "kj kilojoule"); add("energy", 4.184, "cal calorie")
        add("energy", 4184, "kcal kilocalorie"); add("energy", 3600, "wh"); add("energy", 3.6e6, "kwh"); add("energy", 1055.06, "btu")
        add("energy", 1.602176634e-19, "ev")
        add("pressure", 1, "pa pascal"); add("pressure", 1000, "kpa"); add("pressure", 1e5, "bar"); add("pressure", 6894.757, "psi")
        add("pressure", 101_325, "atm atmosphere"); add("pressure", 133.322, "mmhg torr")
        add("power", 1, "w watt"); add("power", 1000, "kw kilowatt"); add("power", 745.699872, "hp horsepower"); add("power", 1e6, "mw megawatt")
        add("angle", 1, "rad radian"); add("angle", .pi / 180, "deg degree °"); add("angle", 2 * .pi, "turn rev revolution")
        add("temp", 1, "c celsius centigrade °c"); add("temp", 2, "f fahrenheit °f"); add("temp", 3, "k kelvin")
        return t
    }()

    static func unit(_ s: String) -> Unit? {
        var k = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        k = k.replacingOccurrences(of: "^(degrees?|deg)(?=[cf]|celsius|fahrenheit)", with: "", options: .regularExpression)
        if let u = units[k] { return u }
        if k.hasSuffix("s"), k.count > 2, let u = units[String(k.dropLast())] { return u }
        return nil
    }

    static func toKelvin(_ v: Double, _ u: Unit) -> Double { u.factor == 1 ? v + 273.15 : (u.factor == 2 ? (v - 32) * 5 / 9 + 273.15 : v) }
    static func fromKelvin(_ k: Double, _ u: Unit) -> Double { u.factor == 1 ? k - 273.15 : (u.factor == 2 ? (k - 273.15) * 9 / 5 + 32 : k) }

    // "5 km" -> (5, unit) for the longest unit-name suffix whose prefix is a number or expression
    static func quantity(_ left: String, dim: String?) -> (Double, Unit)? {
        let c = Array(left)
        for i in 0..<c.count {
            let suffix = String(c[i...]).trimmingCharacters(in: .whitespaces)
            guard let u = unit(suffix), dim == nil || u.dim == dim else { continue }
            let prefix = String(c[..<i]).trimmingCharacters(in: .whitespaces)
            if prefix.isEmpty || ["a", "an", "one"].contains(prefix) { return (1, u) }
            if let last = prefix.last, last.isLetter, !"kmb".contains(last) { continue }
            if let v = number(prefix) { return (v, u) }
        }
        return nil
    }

    static func convert(_ q: String) -> CalcResult? {
        var left = "", right = ""
        if let m = rx(q, "^how many\\s+(.+?)\\s+(?:are\\s+|is\\s+)?(?:there\\s+)?in\\s+(.+)$") {
            (left, right) = (m[2], m[1])
        } else if let re = try? NSRegularExpression(pattern: "(?<=\\s)(to|in|into|as)(?=\\s)"),
                  let m = re.matches(in: q, range: NSRange(q.startIndex..., in: q)).last, let r = Range(m.range, in: q) {
            (left, right) = (String(q[..<r.lowerBound]), String(q[r.upperBound...]))
        } else { return nil }
        left = left.trimmingCharacters(in: .whitespaces)
        right = right.trimmingCharacters(in: .whitespaces)

        if let to = unit(right) {
            var base: Double?
            if let (v, from) = quantity(left, dim: to.dim) {
                base = to.dim == "temp" ? toKelvin(v, from) : v * from.factor
            } else if to.dim != "temp" {
                // compound: 5 ft 3 in, 1 h 30 min
                var sum = 0.0, covered = 0
                let re = try! NSRegularExpression(pattern: "([0-9.]+)\\s*([a-z'\"]+)")
                for m in re.matches(in: left, range: NSRange(left.startIndex..., in: left)) {
                    guard let a = Range(m.range(at: 1), in: left), let b = Range(m.range(at: 2), in: left),
                          let v = Double(left[a]), let u = unit(String(left[b])), u.dim == to.dim else { return nil }
                    sum += v * u.factor
                    covered += left[a].count + left[b].count
                }
                if covered > 0, covered == left.filter({ $0 != " " }).count { base = sum }
            }
            if let base {
                let v = to.dim == "temp" ? fromKelvin(base, to) : base / to.factor
                let name = to.dim == "temp" ? ["°C", "°F", "K"][Int(to.factor) - 1] : right
                return CalcResult(title: "\(pretty(v, sig: 6)) \(name)", detail: "\(left) = \(plain(v, sig: 10)) \(name)",
                                  copy: plain(v, sig: 10), tag: "Convert", value: v)
            }
        }
        return currency(left, right)
    }

    // MARK: currency

    static let currencyNames: [String: String] = [
        "$": "USD", "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD", "usd": "USD",
        "€": "EUR", "euro": "EUR", "euros": "EUR", "£": "GBP", "pound": "GBP", "pounds": "GBP", "quid": "GBP", "sterling": "GBP",
        "¥": "JPY", "yen": "JPY", "yuan": "CNY", "rmb": "CNY", "renminbi": "CNY", "rupee": "INR", "rupees": "INR",
        "won": "KRW", "franc": "CHF", "francs": "CHF", "peso": "MXN", "pesos": "MXN", "ringgit": "MYR", "baht": "THB",
        "rupiah": "IDR", "dong": "VND", "real": "BRL", "reais": "BRL", "rand": "ZAR", "krona": "SEK", "shekel": "ILS",
        "sing dollar": "SGD", "singapore dollar": "SGD", "singapore dollars": "SGD", "aussie dollar": "AUD", "australian dollars": "AUD",
        "canadian dollar": "CAD", "canadian dollars": "CAD", "hong kong dollars": "HKD", "nz dollars": "NZD",
        "bitcoin": "BTC", "btc": "BTC",
    ]
    static let isoCodes = Set(Locale.commonISOCurrencyCodes)

    static func currencyCode(_ s: String) -> String? {
        let k = s.trimmingCharacters(in: .whitespaces)
        if let c = currencyNames[k] { return c }
        return k.count == 3 && isoCodes.contains(k.uppercased()) ? k.uppercased() : nil
    }

    static func currency(_ left: String, _ right: String) -> CalcResult? {
        guard let to = currencyCode(right) else { return nil }
        var from: String?, amount: Double?
        if let f = left.first, let c = currencyNames[String(f)], "$€£¥".contains(f) {
            from = c
            amount = number(String(left.dropFirst()))
        } else {
            let c = Array(left)
            for i in 0..<c.count {
                guard let code = currencyCode(String(c[i...])) else { continue }
                let prefix = String(c[..<i]).trimmingCharacters(in: .whitespaces)
                if let last = prefix.last, last.isLetter, !"kmb".contains(last) { continue }
                from = code
                amount = prefix.isEmpty ? 1 : number(prefix)
                break
            }
        }
        guard let from, let amount else { return nil }
        guard let (rates, date) = Rates.current() else {
            return CalcResult(title: "Fetching exchange rates…", detail: "\(from) → \(to)", copy: "", tag: "Convert")
        }
        guard let a = rates[from], let b = rates[to], a > 0 else { return nil }
        let v = amount / a * b
        let places = abs(v) >= 1 ? 2 : 4
        let shown = pretty((v * pow(10, Double(places))).rounded() / pow(10, Double(places)))
        return CalcResult(title: "\(shown) \(to)", detail: "\(pretty(amount)) \(from) · 1 \(from) = \(plain(b / a, sig: 6)) \(to) · rates \(date)",
                          copy: plain(v, sig: 8), tag: "Convert", value: v)
    }

    // MARK: dates

    static let holidays: [String: String] = [
        "christmas": "december 25", "xmas": "december 25", "christmas eve": "december 24", "new year": "january 1", "new years": "january 1",
        "new year's": "january 1", "new years eve": "december 31", "halloween": "october 31", "valentines": "february 14",
        "valentine's day": "february 14", "valentines day": "february 14",
    ]

    static func parseDate(_ text: String, preferFuture: Bool) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var s = text.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "^(the|my) ", with: "", options: .regularExpression)
        switch s {
        case "today", "now": return today
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        s = holidays[s] ?? s
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.range.length == (s as NSString).length,
              var d = m.date else { return nil }
        d = cal.startOfDay(for: d)
        let hasYear = s.range(of: "\\d{4}", options: .regularExpression) != nil
        if preferFuture, !hasYear, d < today { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
        return d
    }

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()

    static func dateMath(_ q: String) -> CalcResult? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let comps: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year]

        if let m = rx(q, "^(?:how many |how long |number of )?(day|week|month|year)s?\\s+(until|till|til|to|before|since|from|after)\\s+(.+)$") {
            let past = ["since", "from", "after"].contains(m[2])
            guard let d = parseDate(m[3], preferFuture: !past) else { return nil }
            let (a, b) = d >= today ? (today, d) : (d, today)
            let days = cal.dateComponents([.day], from: a, to: b).day ?? 0
            let n: String
            switch m[1] {
            case "week": n = plain(Double(days) / 7, sig: 3) + " weeks"
            case "month":
                let c = cal.dateComponents([.month, .day], from: a, to: b)
                n = "\(c.month ?? 0) months, \(c.day ?? 0) days"
            case "year":
                let c = cal.dateComponents([.year, .month], from: a, to: b)
                n = "\(c.year ?? 0) years, \(c.month ?? 0) months"
            default: n = "\(pretty(Double(days))) day\(days == 1 ? "" : "s")"
            }
            return CalcResult(title: n, detail: "\(d >= today ? "until" : "since") \(longDate.string(from: d)) · \(pretty(Double(days))) days",
                              copy: String(days), tag: "Date")
        }

        var base = today, delta: Int?, comp = Calendar.Component.day, label = ""
        if let m = rx(q, "^(in\\s+)?(\\d+)\\s*(day|week|month|year)s?(?:\\s+(from now|from today|ago|later|before today|time))?$"),
           !m[1].isEmpty || !m[4].isEmpty, let n = Int(m[2]) {
            let back = m[4] == "ago" || m[4] == "before today"
            (delta, comp) = (back ? -n : n, comps[m[3]]!)
            label = "\(n) \(m[3])\(n == 1 ? "" : "s") \(back ? "ago" : "from today")"
        } else if let m = rx(q, "^(.+?)\\s*(\\+|-|plus|minus)\\s*(\\d+)\\s*(day|week|month|year)s?$"),
                  let d = parseDate(m[1], preferFuture: false), let n = Int(m[3]) {
            let back = m[2] == "-" || m[2] == "minus"
            (base, delta, comp) = (d, back ? -n : n, comps[m[4]]!)
            label = "\(n) \(m[4])\(n == 1 ? "" : "s") \(back ? "before" : "after") \(m[1])"
        } else if let m = rx(q, "^(?:what )?day (?:of the week )?(?:is|was|will)\\s+(?:be\\s+)?(.+)$"), let d = parseDate(m[1], preferFuture: false) {
            (base, delta, label) = (d, 0, m[1])
        }
        guard let delta, let d = cal.date(byAdding: comp, value: delta, to: base) else { return nil }
        let days = cal.dateComponents([.day], from: today, to: d).day ?? 0
        let rel = days == 0 ? "today" : (days > 0 ? "in \(days) days" : "\(-days) days ago")
        return CalcResult(title: longDate.string(from: d), detail: "\(label) · \(rel)", copy: longDate.string(from: d), tag: "Date")
    }

    // MARK: world time

    static let zones: [String: String] = {
        var t: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            if let city = id.split(separator: "/").last { t[city.lowercased().replacingOccurrences(of: "_", with: " ")] = id }
        }
        let alias = ["nyc": "America/New_York", "new york city": "America/New_York", "boston": "America/New_York", "washington": "America/New_York",
                     "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles", "seattle": "America/Los_Angeles",
                     "california": "America/Los_Angeles", "texas": "America/Chicago", "uk": "Europe/London", "england": "Europe/London",
                     "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
                     "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "korea": "Asia/Seoul",
                     "germany": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid", "italy": "Europe/Rome",
                     "australia": "Australia/Sydney", "new zealand": "Pacific/Auckland", "hawaii": "Pacific/Honolulu",
                     "brazil": "America/Sao_Paulo", "utc": "UTC", "gmt": "GMT"]
        for (k, v) in alias { t[k] = v }
        return t
    }()

    static func worldTime(_ q: String) -> CalcResult? {
        var place: String?
        if let m = rx(q, "^(?:what(?:'s| is) the |what |the |current |local )?time(?: is it)?(?: right now)? (?:in|at)\\s+(.+)$") { place = m[1] } else if let m = rx(q, "^(.+?)\\s+time(?: now)?$") { place = m[1] }
        guard let p = place?.trimmingCharacters(in: .whitespaces),
              let tz = zones[p].flatMap(TimeZone.init(identifier:)) ?? (p.count <= 4 ? TimeZone(abbreviation: p.uppercased()) : nil) else { return nil }
        let now = Date()
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "h:mm a"
        let time = f.string(from: now)
        f.dateFormat = "EEE d MMM"
        let diff = Double(tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        let rel = diff == 0 ? "same time as you" : "\(plain(abs(diff))) h \(diff > 0 ? "ahead of" : "behind") you"
        return CalcResult(title: time, detail: "\(p.capitalized) · \(f.string(from: now)) · \(rel)", copy: time, tag: "Time")
    }
}

// Daily exchange rates, cached on disk; the only network request SemBar makes.
enum Rates {
    private static let lock = NSLock()
    private static var rates: [String: Double]?
    private static var date = ""
    private static var fetched = Date.distantPast
    private static var fetching = false
    private static let file = Paths.support + "/rates.json"
    static var onUpdate: (() -> Void)?

    static func current() -> ([String: Double], String)? {
        lock.lock()
        defer { lock.unlock() }
        if rates == nil, let d = FileManager.default.contents(atPath: file) { parse(d) }
        if Date().timeIntervalSince(fetched) > 12 * 3600 { fetch() }
        return rates.map { ($0, date) }
    }

    private static func parse(_ d: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = j["rates"] as? [String: Double] else { return }
        rates = r
        let t = (j["time_last_update_unix"] as? Double) ?? Date().timeIntervalSince1970
        fetched = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        date = f.string(from: fetched)
    }

    private static func fetch() {
        guard !fetching, let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        fetching = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            lock.lock()
            fetching = false
            if let data, (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["rates"] != nil {
                parse(data)
                fetched = Date() // the feed updates daily; don't refetch until tomorrow
                try? data.write(to: URL(fileURLWithPath: file))
            } else { fetched = Date().addingTimeInterval(-11.5 * 3600) } // retry in half an hour
            lock.unlock()
            DispatchQueue.main.async { onUpdate?() }
        }.resume()
    }
}
