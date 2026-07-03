import Foundation

/// Власний рекурсивно-спадний парсер арифметики: + - * / % ^ (…) та унарний мінус.
/// Без NSExpression — той кидає ObjC-виключення на кривому вводі й валить процес.
struct Calculator {
    static func evaluate(_ expression: String) -> Double? {
        var parser = Parser(expression)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value.isFinite ? value : nil
    }

    private struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ s: String) {
            chars = Array(s.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace })
        }

        var isAtEnd: Bool { pos >= chars.count }
        private var peek: Character? { pos < chars.count ? chars[pos] : nil }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let op = peek, op == "*" || op == "/" || op == "%" {
                pos += 1
                guard let rhs = parseUnary() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        private mutating func parseUnary() -> Double? {
            if peek == "-" { pos += 1; return parseUnary().map { -$0 } }
            if peek == "+" { pos += 1; return parseUnary() }
            return parsePower()
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePrimary() else { return nil }
            if peek == "^" {
                pos += 1
                guard let exponent = parseUnary() else { return nil } // правоасоціативно, дозволяє 2^-3
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parsePrimary() -> Double? {
            if peek == "(" {
                pos += 1
                guard let value = parseExpression(), peek == ")" else { return nil }
                pos += 1
                return value
            }
            var number = ""
            while let ch = peek, ch.isNumber || ch == "." {
                number.append(ch)
                pos += 1
            }
            return number.isEmpty ? nil : Double(number)
        }
    }
}
