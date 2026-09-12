// JSON Pointer (RFC 6901) —— 解析、转义与取值。
//
// 这一层是 schema `$ref` 解析和「实例错误定位」的共同基础设施：
//   * `$ref: "#/$defs/foo"` 需要按指针在文档里定位子 schema；
//   * 校验失败时要报出实例位置，例如 `/items/0/name`。
//
// 两个容易出错的细节，这里按 RFC 严格处理：
//   1. 转义必须「从左到右」扫描。`~01` 代表字面量 `~1`，而不是 `/`；
//      如果先整体替换 `~1` 再替换 `~0` 就会得到错误结果。
//   2. 数组下标只接受 `0` 或 [1-9][0-9]*，不接受前导零；`-` 表示
//      「末尾之后的位置」，在读取场景下永远取不到值。

///|
/// JSON Pointer 解析失败。
pub(all) suberror PointerError {
  /// 非空指针必须以 `/` 开头。
  NotStartingWithSlash(String)
  /// `~` 后面只能跟 `0` 或 `1`。
  InvalidEscape(String)
} derive(Eq, @debug.Debug)

///|
pub impl Show for PointerError with fn output(self, logger) {
  match self {
    NotStartingWithSlash(p) => {
      logger.write_string("JSON Pointer must be empty or start with '/': ")
      logger.write_string(p)
    }
    InvalidEscape(p) => {
      logger.write_string(
        "invalid '~' escape in JSON Pointer (only '~0' and '~1' are allowed): ",
      )
      logger.write_string(p)
    }
  }
}

///|
/// 反转义单个 pointer 段：`~1` -> `/`，`~0` -> `~`。
///
/// 逐字符扫描而非字符串替换，保证 `~01` 正确解析为字面量 `~1`。
fn unescape_token(raw : StringView) -> String raise PointerError {
  let buf = StringBuilder(size_hint=raw.length())
  let mut tilde = false
  for ch in raw.iter() {
    if tilde {
      tilde = false
      // 注意：这里比较的是转义序列里的「数字」，不是它解析出来的字符。
      if ch == '0' {
        buf.write_char('~')
      } else if ch == '1' {
        buf.write_char('/')
      } else {
        raise InvalidEscape(raw.to_owned())
      }
    } else if ch == '~' {
      tilde = true
    } else {
      buf.write_char(ch)
    }
  }
  if tilde {
    // 以孤立的 '~' 结尾
    raise InvalidEscape(raw.to_owned())
  }
  buf.to_string()
}

///|
/// 转义单个 pointer 段：`~` -> `~0`，`/` -> `~1`。
pub fn escape_token(token : String) -> String {
  let buf = StringBuilder(size_hint=token.length())
  for ch in token.iter() {
    match ch {
      '~' => buf.write_string("~0")
      '/' => buf.write_string("~1")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// 解析 JSON Pointer 为段数组（已反转义）。
///
/// * `""`      -> `[]`（指向整个文档）
/// * `"/"`     -> `[""]`（指向键为空的成员）
/// * `"/a/0/b"` -> `["a", "0", "b"]`
pub fn parse(pointer : String) -> Array[String] raise PointerError {
  let tokens : Array[String] = []
  if pointer.length() == 0 {
    return tokens
  }
  let segments : Array[StringView] = []
  for seg in pointer.split("/") {
    segments.push(seg)
  }
  // 以 '/' 开头时，`split` 的第一个元素必然是空串。
  if segments.length() == 0 || segments[0].length() != 0 {
    raise NotStartingWithSlash(pointer)
  }
  for i = 1; i < segments.length(); i = i + 1 {
    tokens.push(unescape_token(segments[i]))
  }
  tokens
}

///|
/// 把段数组还原成规范的 JSON Pointer 字符串。
pub fn format(tokens : Array[String]) -> String {
  let buf = StringBuilder()
  for token in tokens {
    buf.write_char('/')
    buf.write_string(escape_token(token))
  }
  buf.to_string()
}

///|
/// 解析数组下标：`0` 或 `[1-9][0-9]*`。其他形式（含 `-`、前导零、负数）返回 `None`。
pub fn parse_index(token : String) -> Int? {
  let n = token.length()
  if n == 0 {
    return None
  }
  let units = token.code_units()
  let mut i = 0
  // `-` 是「数组末尾之后」的保留标记，读取时不可达。
  if units[0].to_int() == 0x2D {
    return None
  }
  let mut value = 0
  while i < n {
    let u = units[i].to_int()
    if u < 0x30 || u > 0x39 {
      return None
    }
    // 前导零不合法，但 "0" 本身合法。
    if i == 0 && u == 0x30 && n > 1 {
      return None
    }
    let digit = u - 0x30
    // 防止 Int 溢出导致下标回绕。
    if value > (2147483647 - digit) / 10 {
      return None
    }
    value = value * 10 + digit
    i = i + 1
  }
  Some(value)
}

///|
/// 按段数组在 JSON 文档里取值。
pub fn get_by_tokens(root : Json, tokens : Array[String]) -> Json? {
  let mut current = root
  for token in tokens {
    let next = match current {
      Object(obj) => obj.get(token)
      Array(arr) =>
        match parse_index(token) {
          Some(index) =>
            if index >= 0 && index < arr.length() {
              Some(arr[index])
            } else {
              None
            }
          None => None
        }
      _ => None
    }
    match next {
      Some(value) => current = value
      None => return None
    }
  }
  Some(current)
}

///|
/// 按 JSON Pointer 字符串在 JSON 文档里取值。
pub fn get(root : Json, pointer : String) -> Json? raise PointerError {
  get_by_tokens(root, parse(pointer))
}

///|
/// 判断字符串是否是语法合法的 JSON Pointer。
pub fn is_valid(pointer : String) -> Bool {
  try {
    ignore(parse(pointer))
    true
  } catch {
    _ => false
  }
}

// --- 测试辅助 -------------------------------------------------------------
// `expr is Pat` 只用于 `if`/`guard` 的条件位置，不能当作 Bool 表达式，
// 所以断言里统一通过下面两个 helper 把 Option 判空。

///|
fn[A] opt_is_none(o : A?) -> Bool {
  match o {
    None => true
    Some(_) => false
  }
}

///|
fn json_as_string(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
test "parse: 根指针与空键" {
  assert_true(parse("").length() == 0, msg="empty pointer is the root")
  let root_key = parse("/")
  assert_true(root_key.length() == 1, msg="'/' is one empty token")
  assert_true(root_key[0] == "", msg="'/' refers to the empty key")
}

///|
test "parse: 常规路径" {
  let t = parse("/a/0/b")
  assert_true(t.length() == 3)
  assert_true(t[0] == "a")
  assert_true(t[1] == "0")
  assert_true(t[2] == "b")
}

///|
test "parse: ~01 必须解析为字面量 ~1" {
  let t = parse("/~01")
  assert_true(t[0] == "~1", msg="~01 must unescape to literal ~1, not /")
  let t2 = parse("/~1")
  assert_true(t2[0] == "/")
  let t3 = parse("/~0")
  assert_true(t3[0] == "~")
  let t4 = parse("/a~1b~0c")
  assert_true(t4[0] == "a/b~c")
}

///|
test "parse: 非法指针" {
  assert_false(is_valid("a/b"), msg="missing leading slash")
  assert_false(is_valid("/~2"), msg="~2 is not a valid escape")
  assert_false(is_valid("/~"), msg="dangling tilde")
  assert_true(is_valid("/~0~1"), msg="adjacent valid escapes")
}

///|
test "format: 与 parse 互逆" {
  let t : Array[String] = ["a/b", "~", "", "0"]
  assert_true(format(t) == "/a~1b/~0//0")
  let round = parse(format(t))
  assert_true(round.length() == 4)
  assert_true(round[0] == "a/b")
  assert_true(round[1] == "~")
  assert_true(round[2] == "")
}

///|
test "parse_index: 只接受规范下标" {
  assert_true(parse_index("0") == Some(0))
  assert_true(parse_index("10") == Some(10))
  assert_true(opt_is_none(parse_index("01")), msg="leading zero is rejected")
  assert_true(opt_is_none(parse_index("-")), msg="'-' is not readable")
  assert_true(opt_is_none(parse_index("-1")), msg="negative is rejected")
  assert_true(opt_is_none(parse_index("")))
  assert_true(opt_is_none(parse_index("a")))
}

///|
test "get: 在文档里定位" {
  let doc : Json = {
    "store": {
      "book": [{ "title": "A" }, { "title": "B" }],
      "bicycle": { "color": "red" },
    },
    "": "empty-key-value",
  }
  assert_true(json_as_string(get(doc, "/store/bicycle/color")) == "red")
  assert_true(json_as_string(get(doc, "/store/book/1/title")) == "B")
  assert_true(json_as_string(get(doc, "/")) == "empty-key-value")
  assert_true(
    opt_is_none(get(doc, "/store/book/2/title")),
    msg="index out of range",
  )
  assert_true(opt_is_none(get(doc, "/store/book/-")), msg="'-' is not readable")
  assert_true(opt_is_none(get(doc, "/nope")))
  assert_true(
    opt_is_none(get(doc, "/store/book/01")),
    msg="leading zero rejected",
  )
}
