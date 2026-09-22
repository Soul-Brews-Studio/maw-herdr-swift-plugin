import Foundation

// A JSON tree with `JSON.parse` semantics, and a `JSON.stringify` writer for it.
//
// Why not JSONSerialization: measured on this machine (2026-09-22, .tmp/fable/bom.swift):
//   "\u{FEFF}codex"      -> "codex"          one leading BOM stripped from EVERY string
//   {"a":1,"a":2}         -> a = 1            first duplicate wins; JSON.parse keeps the LAST
//   [1,]                  -> [1]              trailing comma accepted; JSON.parse throws
//   1e400                 -> error            JSON.parse gives Infinity
//   \u{FEFF}{"a":1}       -> {a:1}            leading BOM on the document accepted; JSON.parse throws
// A pane whose label starts with a BOM therefore published a name one scalar
// shorter than Bun's. Every byte herdr hands this server goes through this
// parser instead, so the two servers read the same tree from the same bytes.
//
// One divergence remains and is documented rather than hidden: JSON.parse keeps
// a lone surrogate escape (`"\ud800"`) as a lone UTF-16 unit, which a Swift
// String cannot hold. It becomes U+FFFD here.

/// Insertion-ordered object, `Object.entries` order. A duplicate key keeps its
/// FIRST position and takes the LAST value, exactly as a JS object literal does.
struct JSONObject: Equatable, Sendable {
  private(set) var keys: [String] = []
  private var storage: [String: JSONValue] = [:]

  init() {}

  init(_ pairs: [(String, JSONValue)]) {
    for (key, value) in pairs { self[key] = value }
  }

  var count: Int { keys.count }
  var isEmpty: Bool { keys.isEmpty }

  subscript(key: String) -> JSONValue? {
    get { storage[key] }
    set {
      if let newValue {
        if storage[key] == nil { keys.append(key) }
        storage[key] = newValue
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  func has(_ key: String) -> Bool { storage[key] != nil }

  var entries: [(key: String, value: JSONValue)] {
    keys.map { ($0, storage[$0]!) }
  }

  static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    lhs.keys == rhs.keys && lhs.storage == rhs.storage
  }
}

indirect enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  var isNull: Bool { if case .null = self { return true }; return false }
  var string: String? { if case .string(let value) = self { return value }; return nil }
  var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
  var number: Double? { if case .number(let value) = self { return value }; return nil }
  var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
  var object: JSONObject? { if case .object(let value) = self { return value }; return nil }

  /// `value[key]` on something that may not be an object: `undefined` -> nil.
  subscript(key: String) -> JSONValue? { object?[key] }

  /// `Number.isSafeInteger(value) && value >= 0` style checks want the Int.
  var safeInteger: Int? {
    guard case .number(let value) = self, value.isFinite, value == value.rounded(),
      abs(value) <= 9_007_199_254_740_991
    else { return nil }
    return Int(value)
  }
}

struct JSONParseError: Error {}

/// `JSON.parse` over UTF-8 bytes. Invalid UTF-8 has already been replaced with
/// U+FFFD by whoever decoded the bytes into a String, which is what
/// `Buffer.toString("utf8")` does on the Bun side.
func parseJSON(_ text: String) throws -> JSONValue {
  var parser = JSONParser(bytes: Array(text.utf8))
  parser.skipWhitespace()
  let value = try parser.parseValue()
  parser.skipWhitespace()
  guard parser.atEnd else { throw JSONParseError() }
  return value
}

func parseJSON(_ data: Data) throws -> JSONValue {
  try parseJSON(String(decoding: data, as: UTF8.self))
}

private struct JSONParser {
  let bytes: [UInt8]
  var index = 0
  var depth = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  var atEnd: Bool { index >= bytes.count }

  mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

  mutating func parseValue() throws -> JSONValue {
    guard let byte = peek() else { throw JSONParseError() }
    switch byte {
    case UInt8(ascii: "{"): return try parseObject()
    case UInt8(ascii: "["): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
    default: throw JSONParseError()
    }
  }

  private mutating func expect(_ literal: String) throws {
    let expected = Array(literal.utf8)
    guard index + expected.count <= bytes.count,
      Array(bytes[index..<(index + expected.count)]) == expected
    else { throw JSONParseError() }
    index += expected.count
  }

  private mutating func parseObject() throws -> JSONValue {
    index += 1
    depth += 1
    // V8 has no fixed depth limit worth reproducing; this only keeps a hostile
    // 4 MiB of `[` from taking the stack down.
    guard depth <= 512 else { throw JSONParseError() }
    defer { depth -= 1 }
    var object = JSONObject()
    skipWhitespace()
    if peek() == UInt8(ascii: "}") {
      index += 1
      return .object(object)
    }
    while true {
      skipWhitespace()
      guard peek() == UInt8(ascii: "\"") else { throw JSONParseError() }
      let key = try parseString()
      skipWhitespace()
      guard peek() == UInt8(ascii: ":") else { throw JSONParseError() }
      index += 1
      skipWhitespace()
      object[key] = try parseValue()
      skipWhitespace()
      guard let next = peek() else { throw JSONParseError() }
      if next == UInt8(ascii: ",") {
        index += 1
        continue
      }
      if next == UInt8(ascii: "}") {
        index += 1
        return .object(object)
      }
      throw JSONParseError()
    }
  }

  private mutating func parseArray() throws -> JSONValue {
    index += 1
    depth += 1
    guard depth <= 512 else { throw JSONParseError() }
    defer { depth -= 1 }
    var items: [JSONValue] = []
    skipWhitespace()
    if peek() == UInt8(ascii: "]") {
      index += 1
      return .array(items)
    }
    while true {
      skipWhitespace()
      items.append(try parseValue())
      skipWhitespace()
      guard let next = peek() else { throw JSONParseError() }
      if next == UInt8(ascii: ",") {
        index += 1
        continue
      }
      if next == UInt8(ascii: "]") {
        index += 1
        return .array(items)
      }
      throw JSONParseError()
    }
  }

  private mutating func parseNumber() throws -> Double {
    let start = index
    if peek() == UInt8(ascii: "-") { index += 1 }
    guard let first = peek(), first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else {
      throw JSONParseError()
    }
    if first == UInt8(ascii: "0") {
      index += 1
    } else {
      while let digit = peek(), digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") { index += 1 }
    }
    if peek() == UInt8(ascii: ".") {
      index += 1
      guard let digit = peek(), digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else {
        throw JSONParseError()
      }
      while let digit = peek(), digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") { index += 1 }
    }
    if let exponent = peek(), exponent == UInt8(ascii: "e") || exponent == UInt8(ascii: "E") {
      index += 1
      if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
      guard let digit = peek(), digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else {
        throw JSONParseError()
      }
      while let digit = peek(), digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") { index += 1 }
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    // Swift parses "1e400" as +inf, which is what JSON.parse yields too.
    guard let value = Double(text) else { throw JSONParseError() }
    return value
  }

  private mutating func parseString() throws -> String {
    index += 1
    var out: [UInt8] = []
    while true {
      guard let byte = peek() else { throw JSONParseError() }
      if byte == UInt8(ascii: "\"") {
        index += 1
        return String(decoding: out, as: UTF8.self)
      }
      if byte < 0x20 { throw JSONParseError() }
      if byte != UInt8(ascii: "\\") {
        out.append(byte)
        index += 1
        continue
      }
      index += 1
      guard let escape = peek() else { throw JSONParseError() }
      index += 1
      switch escape {
      case UInt8(ascii: "\""): out.append(0x22)
      case UInt8(ascii: "\\"): out.append(0x5C)
      case UInt8(ascii: "/"): out.append(0x2F)
      case UInt8(ascii: "b"): out.append(0x08)
      case UInt8(ascii: "f"): out.append(0x0C)
      case UInt8(ascii: "n"): out.append(0x0A)
      case UInt8(ascii: "r"): out.append(0x0D)
      case UInt8(ascii: "t"): out.append(0x09)
      case UInt8(ascii: "u"):
        let unit = try parseHex4()
        var scalar: Unicode.Scalar
        if (0xD800...0xDBFF).contains(unit) {
          // A high surrogate must be followed by `\uDC00`-`\uDFFF` to form a pair.
          if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
            let saved = index
            index += 2
            let low = try parseHex4()
            if (0xDC00...0xDFFF).contains(low) {
              let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
              scalar = Unicode.Scalar(combined) ?? "\u{FFFD}"
            } else {
              index = saved
              scalar = "\u{FFFD}"
            }
          } else {
            scalar = "\u{FFFD}"
          }
        } else if (0xDC00...0xDFFF).contains(unit) {
          scalar = "\u{FFFD}"
        } else {
          scalar = Unicode.Scalar(unit) ?? "\u{FFFD}"
        }
        out.append(contentsOf: Array(String(scalar).utf8))
      default: throw JSONParseError()
      }
    }
  }

  private mutating func parseHex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw JSONParseError() }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      index += 1
      value <<= 4
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
      default: throw JSONParseError()
      }
    }
    return value
  }
}

// MARK: - JSON.stringify

/// `JSON.stringify` string escaping: quote, backslash, the five short control
/// escapes, `\u00xx` for the rest below 0x20, and everything else — including
/// `/`, DEL, U+2028 — passed through as raw UTF-8.
func jsonStringLiteral(_ text: String) -> String {
  var out = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    default:
      if scalar.value < 0x20 {
        out += String(format: "\\u%04x", Int(scalar.value))
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
  }
  return out + "\""
}

/// `Number.prototype.toString` (ECMA-262 Number::toString): the shortest
/// round-trip digits `s` with decimal exponent `n`, rendered plain when
/// -6 < n <= 21 and as `d.ddde±x` otherwise. Swift's own description switches
/// to exponent form below 1e-4 (`1e-06` for 0.000001) and pads the exponent,
/// so its digits are reused but its layout is not. Non-finite numbers are
/// `null`, as `JSON.stringify` writes them.
func jsonNumberLiteral(_ value: Double) -> String {
  guard value.isFinite else { return "null" }
  if value == 0 { return "0" }
  var text = "\(abs(value))"
  var exponent = 0
  if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
    exponent = Int(text[text.index(after: marker)...]) ?? 0
    text = String(text[text.startIndex..<marker])
  }
  var integerPart = text
  var fractionPart = ""
  if let dot = text.firstIndex(of: ".") {
    integerPart = String(text[text.startIndex..<dot])
    fractionPart = String(text[text.index(after: dot)...])
  }
  var digits = integerPart + fractionPart
  var n = integerPart.count + exponent
  while digits.hasPrefix("0") && digits.count > 1 {
    digits.removeFirst()
    n -= 1
  }
  while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
  let k = digits.count
  let out: String
  if k <= n && n <= 21 {
    out = digits + String(repeating: "0", count: n - k)
  } else if 0 < n && n <= 21 {
    out = digits.prefix(n) + "." + digits.dropFirst(n)
  } else if -6 < n && n <= 0 {
    out = "0." + String(repeating: "0", count: -n) + digits
  } else {
    let e = n - 1
    let mantissa = k == 1 ? digits : digits.prefix(1) + "." + digits.dropFirst(1)
    out = mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
  }
  return value < 0 ? "-" + out : out
}

func jsonStringify(_ value: JSONValue) -> String {
  var out = ""
  jsonRender(value, into: &out)
  return out
}

private func jsonRender(_ value: JSONValue, into out: inout String) {
  switch value {
  case .null: out += "null"
  case .bool(let flag): out += flag ? "true" : "false"
  case .number(let number): out += jsonNumberLiteral(number)
  case .string(let text): out += jsonStringLiteral(text)
  case .array(let items):
    out += "["
    for (index, item) in items.enumerated() {
      if index > 0 { out += "," }
      jsonRender(item, into: &out)
    }
    out += "]"
  case .object(let object):
    out += "{"
    var first = true
    for (key, item) in object.entries {
      if !first { out += "," }
      first = false
      out += jsonStringLiteral(key) + ":"
      jsonRender(item, into: &out)
    }
    out += "}"
  }
}

// MARK: - Bridging for the HTTP layer

/// Builds an ordered object from pairs in one expression; a nil value drops the
/// key, which is how `JSON.stringify` treats `undefined`.
func jsonObject(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var object = JSONObject()
  for (key, value) in pairs {
    if let value { object[key] = value }
  }
  return .object(object)
}

extension JSONValue {
  static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
  static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
}
