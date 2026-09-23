import Foundation

/// Turns tokens into a program.
///
/// Recursive descent with precedence climbing. The error messages are the part
/// that took the most care: a parser that says "expected `end`" on line 40 when
/// the missing `end` belongs to an `if` on line 12 is technically correct and
/// useless to a child. So a missing `end` names the statement that opened the
/// block and the line it opened on.
public struct ScriptParser {

    /// Nesting deeper than this is refused while parsing, so a pathological
    /// script cannot overflow the parser's own stack — which, unlike the
    /// interpreter's, has no step budget to catch it.
    public static let maximumNesting = 64

    private let tokens: [ScriptToken]
    private var position = 0
    private var depth = 0

    private init(tokens: [ScriptToken]) {
        self.tokens = tokens
    }

    /// Parses a whole script.
    ///
    /// - Parameter file: its index in a bundle of `.absc` files, if it is
    ///   one; errors then say which file. See `ScriptLocation`.
    public static func parse(_ source: String, file: Int? = nil) throws -> ScriptProgram {
        var parser = ScriptParser(tokens: try ScriptLexer.tokens(from: source, file: file))
        let statements = try parser.block(until: [], opener: nil)

        var handlers: [String: [ScriptHandler]] = [:]
        for statement in statements {
            guard case let .handler(event, parameters, body) = statement.kind else { continue }
            if let existing = handlers[event]?.first {
                throw ScriptError(
                    line: statement.line,
                    kind: .syntax,
                    message: L("There is already an “on {}” on line {}. Put both parts in one.", event,
                               ScriptLocation.line(existing.line))
                )
            }
            handlers[event] = [ScriptHandler(event: event, parameters: parameters, body: body, line: statement.line)]
        }

        return ScriptProgram(statements: statements, handlers: handlers)
    }

    // MARK: Token access

    private var current: ScriptToken { tokens[position] }
    private var line: Int { current.line }

    private mutating func advance() -> ScriptToken {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private func check(_ keyword: Keyword) -> Bool {
        if case .keyword(keyword) = current.kind { return true }
        return false
    }

    private func check(_ symbol: Symbol) -> Bool {
        if case .symbol(symbol) = current.kind { return true }
        return false
    }

    private mutating func match(_ keyword: Keyword) -> Bool {
        guard check(keyword) else { return false }
        _ = advance()
        return true
    }

    private mutating func match(_ symbol: Symbol) -> Bool {
        guard check(symbol) else { return false }
        _ = advance()
        return true
    }

    private mutating func expect(_ keyword: Keyword, _ message: @autoclosure () -> String) throws {
        guard match(keyword) else { throw ScriptError(line: line, kind: .syntax, message: message()) }
    }

    /// `then` or `do` after a condition — with the one mistake worth naming:
    /// `if hp = 0 then`, where `==` was meant.
    private mutating func expectAfterCondition(_ keyword: Keyword, _ message: @autoclosure () -> String) throws {
        if check(.equal) {
            throw ScriptError(line: line, kind: .syntax, message: L("To compare two things, use “==”, not “=”."))
        }
        try expect(keyword, message())
    }

    private mutating func expect(_ symbol: Symbol, _ message: @autoclosure () -> String) throws {
        guard match(symbol) else { throw ScriptError(line: line, kind: .syntax, message: message()) }
    }

    private mutating func identifier(_ message: @autoclosure () -> String) throws -> String {
        if case let .identifier(name) = current.kind {
            _ = advance()
            return name
        }
        // A keyword where a name should be is the common case — `let end = 3`
        // — and deserves a clearer message than "expected a name".
        if case let .keyword(keyword) = current.kind {
            throw ScriptError(line: line, kind: .syntax,
                              message: L("“{}” is a reserved word and cannot be used as a name.", keyword.rawValue))
        }
        throw ScriptError(line: line, kind: .syntax, message: message())
    }

    private mutating func nested<T>(_ body: (inout ScriptParser) throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        guard depth <= ScriptParser.maximumNesting else {
            throw ScriptError(line: line, kind: .limit, message: L("This is nested too deeply."))
        }
        return try body(&self)
    }

    // MARK: Blocks

    /// Statements until one of `terminators` (not consumed).
    ///
    /// `opener` is what began the block and where, so that reaching the end of
    /// the file can say *which* `end` is missing.
    private mutating func block(until terminators: [Keyword], opener: (word: String, line: Int)?) throws -> [ScriptStmt] {
        var statements: [ScriptStmt] = []
        while true {
            if case .end = current.kind {
                if let opener {
                    throw ScriptError(line: opener.line, kind: .syntax,
                                      message: L("The “{}” on this line is never closed with “end”.", opener.word))
                }
                return statements
            }
            if terminators.contains(where: check) { return statements }
            statements.append(try statement())
        }
    }

    // MARK: Statements

    private mutating func statement() throws -> ScriptStmt {
        let startLine = line
        return try nested { parser in
            if parser.match(.let) { return try parser.declaration(line: startLine) }
            if parser.match(.if) { return try parser.ifStatement(line: startLine) }
            if parser.match(.while) { return try parser.whileStatement(line: startLine) }
            if parser.match(.for) { return try parser.forStatement(line: startLine) }
            if parser.match(.func) { return try parser.functionStatement(line: startLine) }
            if parser.match(.on) { return try parser.handlerStatement(line: startLine) }
            if parser.match(.return) { return try parser.returnStatement(line: startLine) }
            if parser.match(.break) { return ScriptStmt(.breakLoop, line: startLine) }
            if parser.match(.continue) { return ScriptStmt(.continueLoop, line: startLine) }

            // Stray block words are the usual sign of a missing or extra line
            // above; say so plainly.
            for word in [Keyword.end, .else, .elif, .then, .do] where parser.check(word) {
                throw ScriptError(line: startLine, kind: .syntax,
                                  message: L("There is an extra “{}” here, or something above it is missing.", word.rawValue))
            }

            return try parser.expressionOrAssignment(line: startLine)
        }
    }

    private mutating func declaration(line: Int) throws -> ScriptStmt {
        let name = try identifier(L("“let” needs a name after it."))
        var value: ScriptExpr?
        if match(.equal) { value = try expression() }
        return ScriptStmt(.declare(name: name, value: value), line: line)
    }

    private mutating func ifStatement(line: Int) throws -> ScriptStmt {
        var branches: [ScriptBranch] = []
        var otherwise: [ScriptStmt]?

        var condition = try expression()
        try expectAfterCondition(.then, L("“if” needs “then” after its condition."))
        var body = try block(until: [.elif, .else, .end], opener: ("if", line))
        branches.append(ScriptBranch(condition: condition, body: body))

        while match(.elif) {
            let elifLine = self.line
            condition = try expression()
            try expectAfterCondition(.then, L("“elif” needs “then” after its condition."))
            body = try block(until: [.elif, .else, .end], opener: ("elif", elifLine))
            branches.append(ScriptBranch(condition: condition, body: body))
        }

        if match(.else) {
            otherwise = try block(until: [.end], opener: ("else", self.line))
        }
        try expect(.end, L("The “if” on line {} is never closed with “end”.", ScriptLocation.line(line)))
        return ScriptStmt(.ifChain(branches: branches, otherwise: otherwise), line: line)
    }

    private mutating func whileStatement(line: Int) throws -> ScriptStmt {
        let condition = try expression()
        try expectAfterCondition(.do, L("“while” needs “do” after its condition."))
        let body = try block(until: [.end], opener: ("while", line))
        try expect(.end, L("The “while” on line {} is never closed with “end”.", ScriptLocation.line(line)))
        return ScriptStmt(.whileLoop(condition: condition, body: body), line: line)
    }

    private mutating func forStatement(line: Int) throws -> ScriptStmt {
        let variable = try identifier(L("“for” needs a name, as in “for i in 1 to 10 do”."))
        try expect(.in, L("“for” needs “in”, as in “for i in 1 to 10 do”."))
        let first = try expression()

        if match(.to) {
            let last = try expression()
            let step = match(.step) ? try expression() : nil
            try expect(.do, L("“for” needs “do” before its body."))
            let body = try block(until: [.end], opener: ("for", line))
            try expect(.end, L("The “for” on line {} is never closed with “end”.", ScriptLocation.line(line)))
            return ScriptStmt(.forRange(variable: variable, from: first, to: last, step: step, body: body), line: line)
        }

        try expect(.do, L("“for” needs “do” before its body."))
        let body = try block(until: [.end], opener: ("for", line))
        try expect(.end, L("The “for” on line {} is never closed with “end”.", ScriptLocation.line(line)))
        return ScriptStmt(.forEach(variable: variable, sequence: first, body: body), line: line)
    }

    private mutating func parameters() throws -> [String] {
        try expect(.leftParen, L("A function needs “(” after its name, even with nothing inside."))
        var names: [String] = []
        if !check(.rightParen) {
            repeat {
                let name = try identifier(L("Expected a parameter name."))
                if names.contains(name) {
                    throw ScriptError(line: line, kind: .syntax, message: L("“{}” is listed twice.", name))
                }
                names.append(name)
            } while match(.comma)
        }
        try expect(.rightParen, L("Expected “)” after the parameters."))
        return names
    }

    private mutating func functionStatement(line: Int) throws -> ScriptStmt {
        let name = try identifier(L("“func” needs a name after it."))
        let params = try parameters()
        let body = try block(until: [.end], opener: ("func", line))
        try expect(.end, L("The “func” on line {} is never closed with “end”.", ScriptLocation.line(line)))
        return ScriptStmt(.function(name: name, parameters: params, body: body), line: line)
    }

    private mutating func handlerStatement(line: Int) throws -> ScriptStmt {
        guard depth == 1 else {
            // A handler inside a function or loop would be registered or not
            // depending on whether that code ran — a trap with no upside.
            throw ScriptError(line: line, kind: .syntax, message: L("“on” can only be used at the top of a script."))
        }
        let event = try identifier(L("“on” needs an event name, as in “on start()”."))
        let params = try parameters()
        let body = try block(until: [.end], opener: ("on", line))
        try expect(.end, L("The “on” on line {} is never closed with “end”.", ScriptLocation.line(line)))
        return ScriptStmt(.handler(event: event, parameters: params, body: body), line: line)
    }

    private mutating func returnStatement(line: Int) throws -> ScriptStmt {
        // A bare `return` is followed by a block word or the end of input.
        var endsHere = check(.end) || check(.else) || check(.elif)
        if case .end = current.kind { endsHere = true }
        return ScriptStmt(.returnValue(endsHere ? nil : try expression()), line: line)
    }

    private mutating func expressionOrAssignment(line: Int) throws -> ScriptStmt {
        let target = try expression()
        if match(.equal) {
            switch target.kind {
            case .variable, .member, .index:
                let value = try expression()
                return ScriptStmt(.assign(target: target, value: value), line: line)
            default:
                throw ScriptError(line: line, kind: .syntax, message: L("The left side of “=” has to be a name."))
            }
        }
        // A bare expression is only worth writing if it does something.
        guard case .call = target.kind else {
            throw ScriptError(line: line, kind: .syntax,
                              message: L("This line does nothing. Did you mean to use “=” or call something?"))
        }
        return ScriptStmt(.expression(target), line: line)
    }

    // MARK: Expressions

    private mutating func expression() throws -> ScriptExpr {
        try nested { try $0.or() }
    }

    private mutating func or() throws -> ScriptExpr {
        var left = try and()
        while check(.or) {
            let at = line; _ = advance()
            left = ScriptExpr(.logical(isAnd: false, left, try and()), line: at)
        }
        return left
    }

    private mutating func and() throws -> ScriptExpr {
        var left = try not()
        while check(.and) {
            let at = line; _ = advance()
            left = ScriptExpr(.logical(isAnd: true, left, try not()), line: at)
        }
        return left
    }

    private mutating func not() throws -> ScriptExpr {
        if check(.not) {
            let at = line; _ = advance()
            return ScriptExpr(.unary(.not, try nested { try $0.not() }), line: at)
        }
        return try comparison()
    }

    private mutating func comparison() throws -> ScriptExpr {
        var left = try concatenation()
        let operators: [(Symbol, BinaryOperator)] = [
            (.equalEqual, .equal), (.bangEqual, .notEqual), (.lessEqual, .lessEqual),
            (.greaterEqual, .greaterEqual), (.less, .less), (.greater, .greater)
        ]
        while let (symbol, op) = operators.first(where: { check($0.0) }) {
            _ = symbol
            let at = line; _ = advance()
            left = ScriptExpr(.binary(op, left, try concatenation()), line: at)
        }
        return left
    }

    private mutating func concatenation() throws -> ScriptExpr {
        let left = try additive()
        if check(.dotDot) {
            let at = line; _ = advance()
            // Right-associative, as in Lua; it makes no difference to the
            // result and keeps long joins from nesting deeply on the left.
            return ScriptExpr(.binary(.concatenate, left, try nested { try $0.concatenation() }), line: at)
        }
        return left
    }

    private mutating func additive() throws -> ScriptExpr {
        var left = try multiplicative()
        while check(.plus) || check(.minus) {
            let op: BinaryOperator = check(.plus) ? .add : .subtract
            let at = line; _ = advance()
            left = ScriptExpr(.binary(op, left, try multiplicative()), line: at)
        }
        return left
    }

    private mutating func multiplicative() throws -> ScriptExpr {
        var left = try unary()
        while check(.star) || check(.slash) || check(.percent) {
            let op: BinaryOperator = check(.star) ? .multiply : check(.slash) ? .divide : .remainder
            let at = line; _ = advance()
            left = ScriptExpr(.binary(op, left, try unary()), line: at)
        }
        return left
    }

    private mutating func unary() throws -> ScriptExpr {
        if check(.minus) {
            let at = line; _ = advance()
            return ScriptExpr(.unary(.negate, try nested { try $0.unary() }), line: at)
        }
        return try postfix()
    }

    private mutating func postfix() throws -> ScriptExpr {
        var expression = try primary()
        while true {
            let at = line
            if match(.leftParen) {
                var arguments: [ScriptExpr] = []
                if !check(.rightParen) {
                    repeat { arguments.append(try self.expression()) } while match(.comma)
                }
                try expect(.rightParen, L("Expected “)” to close the call."))
                expression = ScriptExpr(.call(expression, arguments), line: at)
            } else if match(.dot) {
                let name = try identifier(L("Expected a name after “.”."))
                expression = ScriptExpr(.member(expression, name), line: at)
            } else if match(.leftBracket) {
                let index = try self.expression()
                try expect(.rightBracket, L("Expected “]”."))
                expression = ScriptExpr(.index(expression, index), line: at)
            } else {
                return expression
            }
        }
    }

    private mutating func primary() throws -> ScriptExpr {
        let at = line
        let token = advance()

        switch token.kind {
        case let .number(value): return ScriptExpr(.number(value), line: at)
        case let .string(value): return ScriptExpr(.string(value), line: at)
        case let .identifier(name): return ScriptExpr(.variable(name), line: at)
        case .keyword(.true): return ScriptExpr(.bool(true), line: at)
        case .keyword(.false): return ScriptExpr(.bool(false), line: at)
        case .keyword(.nil): return ScriptExpr(.null, line: at)

        case .keyword(.func):
            // An anonymous function, for `after(2, func() … end)`.
            let params = try parameters()
            let body = try block(until: [.end], opener: ("func", at))
            try expect(.end, L("The “func” on line {} is never closed with “end”.", ScriptLocation.line(at)))
            return ScriptExpr(.function(parameters: params, body: body), line: at)

        case .symbol(.leftParen):
            let inner = try expression()
            try expect(.rightParen, L("Expected “)”."))
            return inner

        case .symbol(.leftBracket):
            var items: [ScriptExpr] = []
            if !check(.rightBracket) {
                repeat {
                    if check(.rightBracket) { break }    // allow a trailing comma
                    items.append(try expression())
                } while match(.comma)
            }
            try expect(.rightBracket, L("Expected “]” to close the list."))
            return ScriptExpr(.list(items), line: at)

        case .symbol(.leftBrace):
            var entries: [(key: String, value: ScriptExpr)] = []
            if !check(.rightBrace) {
                repeat {
                    if check(.rightBrace) { break }
                    let key: String
                    if case let .string(text) = current.kind {
                        _ = advance(); key = text
                    } else {
                        key = try identifier(L("Expected a name inside “{ }”."))
                    }
                    try expect(.colon, L("Expected “:” after “{}”.", key))
                    entries.append((key, try expression()))
                } while match(.comma)
            }
            try expect(.rightBrace, L("Expected “}” to close the map."))
            return ScriptExpr(.map(entries), line: at)

        case .end:
            throw ScriptError(line: at, kind: .syntax, message: L("The script ends in the middle of something."))

        case let .keyword(keyword):
            throw ScriptError(line: at, kind: .syntax, message: L("“{}” cannot be used here.", keyword.rawValue))

        case let .symbol(symbol):
            if symbol == .equal {
                throw ScriptError(line: at, kind: .syntax, message: L("To compare two things, use “==”, not “=”."))
            }
            throw ScriptError(line: at, kind: .syntax, message: L("“{}” cannot be used here.", symbol.rawValue))
        }
    }
}
