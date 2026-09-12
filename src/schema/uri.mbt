// RFC 3986 的 URI 分解与相对引用解析。
//
// 为什么需要这一整层：JSON Schema 的 `$ref` 不是「字符串匹配」，而是
// 「URI 引用解析」。`$id` 会改变后续子 schema 的 base URI，`$ref` 必须
// 先按 RFC 3986 §5.2 解析成绝对 URI，再按 URI + fragment 定位资源。
// 「把 $ref 直接当 key 去查表」在嵌套 $id、URN、相对路径这几类用例上
// 一定会给出错误答案，测试套件里专门有 "naive replacement of $ref with
// its destination is not correct" 这样的用例来抓这种实现。
//
// 实现只覆盖解析所需的部分：不做 scheme 特化，不解析 authority 内部，
// 不做 normalization 之外的处理。

///|
/// RFC 3986 §3 的五段分解。`None` 表示该组件在原文中未出现。
struct UriParts {
  scheme : String?
  authority : String?
  path : String
  query : String?
  fragment : String?
} derive(Eq, @debug.Debug)

///|
/// 在 `[from, until)` 范围内查找字符 `code`（UTF-16 码元值），
/// 找不到时返回 `until`。
fn index_of_code(s : String, code : Int, from : Int, until : Int) -> Int {
  let n = if until > s.length() { s.length() } else { until }
  let units = s.code_units()
  let mut i = from
  while i < n {
    if units[i].to_int() == code {
      return i
    }
    i = i + 1
  }
  n
}

///|
/// 按 UTF-16 码元下标切片（`end <= start` 时返回空串）。
fn slice(s : String, start : Int, end : Int) -> String {
  guard end > start else { return "" }
  s[start:end].to_owned()
}

///|
fn is_alpha_code(c : Int) -> Bool {
  (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}

///|
fn is_digit_code(c : Int) -> Bool {
  c >= 0x30 && c <= 0x39
}

///|
/// 校验 `s[0:colon]` 是否构成合法 scheme。
fn is_scheme(s : String, colon : Int) -> Bool {
  guard colon > 0 else { return false }
  let units = s.code_units()
  guard is_alpha_code(units[0].to_int()) else { return false }
  let mut i = 1
  while i < colon {
    let c = units[i].to_int()
    let ok = is_alpha_code(c) ||
      is_digit_code(c) ||
      c == 0x2B || // '+'
      c == 0x2D || // '-'
      c == 0x2E // '.'
    if !ok {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn parse_uri(uri : String) -> UriParts {
  let n = uri.length()
  let hash = index_of_code(uri, 0x23, 0, n) // '#'
  let (body_end, fragment) = if hash < n {
    (hash, Some(slice(uri, hash + 1, n)))
  } else {
    (n, None)
  }
  let qmark = index_of_code(uri, 0x3F, 0, body_end) // '?'
  let (path_end, query) = if qmark < body_end {
    (qmark, Some(slice(uri, qmark + 1, body_end)))
  } else {
    (body_end, None)
  }
  let colon = index_of_code(uri, 0x3A, 0, path_end) // ':'
  let (scheme, after_scheme) = if colon < path_end && is_scheme(uri, colon) {
    (Some(slice(uri, 0, colon)), colon + 1)
  } else {
    (None, 0)
  }
  // authority 仅在 "//" 开头时存在
  let has_authority = after_scheme + 1 < path_end &&
    uri.unsafe_get(after_scheme).to_int() == 0x2F &&
    uri.unsafe_get(after_scheme + 1).to_int() == 0x2F
  let (authority, path_start) = if has_authority {
    let slash = index_of_code(uri, 0x2F, after_scheme + 2, path_end)
    (Some(slice(uri, after_scheme + 2, slash)), slash)
  } else {
    (None, after_scheme)
  }
  let path = slice(uri, path_start, path_end)
  { scheme, authority, path, query, fragment, }
}

///|
fn recompose(u : UriParts) -> String {
  let buf = StringBuilder()
  match u.scheme {
    Some(s) => {
      buf.write_string(s)
      buf.write_char(':')
    }
    None => ()
  }
  match u.authority {
    Some(a) => {
      buf.write_string("//")
      buf.write_string(a)
    }
    None => ()
  }
  buf.write_string(u.path)
  match u.query {
    Some(q) => {
      buf.write_char('?')
      buf.write_string(q)
    }
    None => ()
  }
  match u.fragment {
    Some(f) => {
      buf.write_char('#')
      buf.write_string(f)
    }
    None => ()
  }
  buf.to_string()
}

///|
/// RFC 3986 §5.2.4 remove_dot_segments。
///
/// 用「按 `/` 切分 + 栈」实现：`.` 丢弃，`..` 弹出一段。结尾是 `.` 或 `..`
/// 时要保留一个尾斜杠（`a/b/..` 解析结果是 `a/` 而不是 `a`），这一点如果漏了，
/// 后续把相对路径拼到 base 上就会少一层目录。
fn remove_dot_segments(path : String) -> String {
  let absolute = path.length() > 0 && path.unsafe_get(0).to_int() == 0x2F
  let trailing_slash = path.length() > 0 &&
    path.unsafe_get(path.length() - 1).to_int() == 0x2F
  let segments : Array[String] = []
  let mut ends_with_dots = false
  for seg in path.split("/") {
    let s = seg.to_owned()
    if s == "" {
      // 连续的 '/' 折叠；但要记住这不改变「以点结尾」的状态
    } else if s == "." {
      ends_with_dots = true
    } else if s == ".." {
      if segments.length() > 0 {
        ignore(segments.pop())
      }
      ends_with_dots = true
    } else {
      segments.push(s)
      ends_with_dots = false
    }
  }
  let buf = StringBuilder()
  if absolute {
    buf.write_char('/')
  }
  let mut first = true
  for s in segments {
    if !first {
      buf.write_char('/')
    }
    first = false
    buf.write_string(s)
  }
  if (trailing_slash || ends_with_dots) && (segments.length() > 0 || absolute) {
    buf.write_char('/')
  }
  buf.to_string()
}

///|
/// RFC 3986 §5.3 merge：把相对路径拼到 base 的目录部分之后。
fn merge_paths(base : UriParts, ref_path : String) -> String {
  match base.authority {
    Some(_) =>
      if base.path == "" {
        "/" + ref_path
      } else {
        slice(base.path, 0, last_slash(base.path) + 1) + ref_path
      }
    None => slice(base.path, 0, last_slash(base.path) + 1) + ref_path
  }
}

///|
/// 返回最后一个 `/` 的下标；不存在时返回 -1。
fn last_slash(path : String) -> Int {
  let mut i = path.length() - 1
  while i >= 0 {
    if path.unsafe_get(i).to_int() == 0x2F {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// RFC 3986 §5.2.2（strict）相对引用解析。
pub fn resolve(base_uri : String, reference : String) -> String {
  let b = parse_uri(base_uri)
  let r = parse_uri(reference)
  let target = match r.scheme {
    Some(_) =>
      {
        scheme: r.scheme,
        authority: r.authority,
        path: remove_dot_segments(r.path),
        query: r.query,
        fragment: r.fragment,
      }
    None =>
      match r.authority {
        Some(_) =>
          {
            scheme: b.scheme,
            authority: r.authority,
            path: remove_dot_segments(r.path),
            query: r.query,
            fragment: r.fragment,
          }
        None =>
          if r.path == "" {
            {
              scheme: b.scheme,
              authority: b.authority,
              path: b.path,
              query: match r.query {
                Some(_) => r.query
                None => b.query
              },
              fragment: r.fragment,
            }
          } else if r.path.length() > 0 && r.path.unsafe_get(0).to_int() == 0x2F {
            {
              scheme: b.scheme,
              authority: b.authority,
              path: remove_dot_segments(r.path),
              query: r.query,
              fragment: r.fragment,
            }
          } else {
            {
              scheme: b.scheme,
              authority: b.authority,
              path: remove_dot_segments(merge_paths(b, r.path)),
              query: r.query,
              fragment: r.fragment,
            }
          }
      }
  }
  recompose(target)
}

///|
/// 把 URI 拆成「不含 fragment 的部分」和「已百分号解码的 fragment」。
pub fn split_fragment(uri : String) -> (String, String) {
  let n = uri.length()
  let hash = index_of_code(uri, 0x23, 0, n)
  if hash >= n {
    (uri, "")
  } else {
    (slice(uri, 0, hash), percent_decode(slice(uri, hash + 1, n)))
  }
}

///|
fn hex_value(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    -1
  }
}

///|
/// 读取从 `start` 开始、连续的 `%XX` 字节序列。
fn read_escape_run(units : ArrayView[UInt16], start : Int) -> Array[Int] {
  let bytes : Array[Int] = []
  let n = units.length()
  let mut i = start
  while i + 2 < n && units[i].to_int() == 0x25 {
    let hi = hex_value(units[i + 1].to_int())
    let lo = hex_value(units[i + 2].to_int())
    guard hi >= 0 && lo >= 0 else { break }
    bytes.push(hi * 16 + lo)
    i = i + 3
  }
  bytes
}

///|
/// 把 UTF-8 字节序列写成字符；非法字节按 U+FFFD 处理。
fn write_utf8(buf : StringBuilder, bytes : Array[Int]) -> Unit {
  let mut i = 0
  let n = bytes.length()
  while i < n {
    let b0 = bytes[i]
    if b0 < 0x80 {
      buf.write_char(b0.unsafe_to_char())
      i = i + 1
    } else if b0 >= 0xC0 && b0 < 0xE0 && i + 1 < n {
      let cp = (b0 - 0xC0) * 0x40 + (bytes[i + 1] - 0x80)
      buf.write_char(cp.unsafe_to_char())
      i = i + 2
    } else if b0 >= 0xE0 && b0 < 0xF0 && i + 2 < n {
      let cp = (b0 - 0xE0) * 0x1000 +
        (bytes[i + 1] - 0x80) * 0x40 +
        (bytes[i + 2] - 0x80)
      buf.write_char(cp.unsafe_to_char())
      i = i + 3
    } else if b0 >= 0xF0 && b0 < 0xF8 && i + 3 < n {
      let cp = (b0 - 0xF0) * 0x40000 +
        (bytes[i + 1] - 0x80) * 0x1000 +
        (bytes[i + 2] - 0x80) * 0x40 +
        (bytes[i + 3] - 0x80)
      buf.write_char(cp.unsafe_to_char())
      i = i + 4
    } else {
      buf.write_char('\u{FFFD}')
      i = i + 1
    }
  }
}

///|
/// 百分号解码。非 ASCII 转义按 UTF-8 解码，非法序列退化为 U+FFFD。
pub fn percent_decode(s : String) -> String {
  let units = s.code_units()
  let n = units.length()
  let buf = StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < n {
    if units[i].to_int() == 0x25 {
      let bytes = read_escape_run(units, i)
      if bytes.length() == 0 {
        buf.write_char('%')
        i = i + 1
      } else {
        write_utf8(buf, bytes)
        i = i + bytes.length() * 3
      }
    } else {
      match units[i].to_char() {
        Some(c) => buf.write_char(c)
        None => buf.write_char('\u{FFFD}')
      }
      i = i + 1
    }
  }
  buf.to_string()
}

///|
test "resolve: 片段与相对路径" {
  let base = "http://example.com/a/b/c.json"
  assert_true(
    resolve(base, "#/$defs/x") == "http://example.com/a/b/c.json#/$defs/x",
  )
  assert_true(resolve(base, "") == "http://example.com/a/b/c.json")
  assert_true(resolve(base, "d.json") == "http://example.com/a/b/d.json")
  assert_true(resolve(base, "./d.json") == "http://example.com/a/b/d.json")
  assert_true(resolve(base, "../d.json") == "http://example.com/a/d.json")
  assert_true(resolve(base, "/d.json") == "http://example.com/d.json")
  assert_true(resolve(base, "http://other/x") == "http://other/x")
}

///|
test "resolve: dot segment 边界" {
  assert_true(remove_dot_segments("a/b/..") == "a/")
  assert_true(remove_dot_segments("/a/./b/") == "/a/b/")
  assert_true(remove_dot_segments("/a/b/../c") == "/a/c")
  assert_true(remove_dot_segments("/../a") == "/a")
}

///|
test "resolve: URN 作为 base" {
  let urn = "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed"
  // 测试套件里 URN 只用这两种引用形式，都必须原样保留 URN 主体。
  assert_true(resolve(urn, "#/$defs/bar") == urn + "#/$defs/bar")
  assert_true(resolve(urn, "#foo") == urn + "#foo")
  assert_true(resolve(urn, urn + "#/$defs/bar") == urn + "#/$defs/bar")
  // URN 的 path 是「不透明」的（不以 '/' 开头），没有目录概念。
  // RFC 3986 本身未定义对 URN 做相对路径解析（见 RFC 8141 §3），
  // 这里记录实现的确定行为：不把 "uuid:..." 当目录去拼。
  assert_true(resolve(urn, "other") == "urn:other")
}

///|
test "split_fragment 与百分号解码" {
  let (u, f) = split_fragment("http://x/y#/a~1b")
  assert_true(u == "http://x/y")
  assert_true(f == "/a~1b")
  let (_, f2) = split_fragment("#/$defs/foo%22bar")
  assert_true(f2 == "/$defs/foo\"bar")
  assert_true(percent_decode("%E2%82%AC") == "\u{20AC}")
  assert_true(percent_decode("a%20b") == "a b")
  assert_true(percent_decode("100%") == "100%")
}
