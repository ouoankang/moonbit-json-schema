// 浏览器入口：把校验器编译成一份自包含 JS，挂到 globalThis 上供网页调用。
//
// 这里刻意不写任何校验逻辑——正确的实现只有一份，就在 src/schema 里。
// 本文件只做「字符串进 → JSON 字符串出」的转接，于是网页上得到的结果，
// 和 CLI、和官方一致性套件跑出来的结论天然一致，不存在「demo 一套、
// 正式版另一套」的风险。

// ---------------------------------------------------------------------------
// 平台 FFI
// ---------------------------------------------------------------------------

///|
#cfg(target="js")
extern "js" fn register_api(
  validate : (String, String) -> String,
  lint : (String) -> String,
  metaschema_list : () -> String,
) -> Unit =
  #| (validate, lint, metaschemaList) => {
  #|   globalThis.MoonbitJsonSchema = { validate, lint, metaschemaList };
  #| }

// 非 js 后端给空实现，这样 `moon check` 在任何目标上都不会因为缺 FFI 而失败。

///|
#cfg(not(target="js"))
fn register_api(
  validate : (String, String) -> String,
  lint : (String) -> String,
  metaschema_list : () -> String,
) -> Unit {
  ignore(validate)
  ignore(lint)
  ignore(metaschema_list)
}

// ---------------------------------------------------------------------------
// JSON 输出拼装
// ---------------------------------------------------------------------------

///|
/// 一个十六进制半字节对应的字符。
fn hex_digit(n : Int) -> String {
  match n {
    0 => "0"
    1 => "1"
    2 => "2"
    3 => "3"
    4 => "4"
    5 => "5"
    6 => "6"
    7 => "7"
    8 => "8"
    9 => "9"
    10 => "a"
    11 => "b"
    12 => "c"
    13 => "d"
    14 => "e"
    _ => "f"
  }
}

///|
/// 把字符码位写成 `\uXXXX`。
fn hex4(code : Int) -> String {
  "\\u" +
  hex_digit((code >> 12) & 0xF) +
  hex_digit((code >> 8) & 0xF) +
  hex_digit((code >> 4) & 0xF) +
  hex_digit(code & 0xF)
}

///|
/// 把字符串转义成能安全放进 JSON 字符串字面量的形式。
///
/// 必须自己做这一步：错误信息里会出现用户输入的属性名，里面可能带引号或
/// 换行。直接拼进 JSON 会生成语法错误的响应，让页面把「校验失败」误报成
/// 「服务器炸了」。
///
/// 按 UTF-16 码元遍历，而不是按 `Char` 遍历。原因是 JSON 的 `\uXXXX`
/// 转义本来就是以码元为单位的，落单的代理项也只有这样才能原样表达出来
/// （`Char` 只能表示合法的 Unicode 标量值）。代理项一律走 `\uXXXX`，
/// 一个合法的代理对会被写成两个转义，解码回来仍是同一个字符，无损。
fn json_escape(s : String) -> String {
  let units = s.code_units()
  let n = units.length()
  let buf = StringBuilder(size_hint=s.length())
  let mut i = 0
  while i < n {
    let unit = units[i].to_int()
    if unit == 0x22 {
      // "
      buf.write_string("\\\"")
    } else if unit == 0x5C {
      // \
      buf.write_string("\\\\")
    } else if unit == 0x08 {
      buf.write_string("\\b")
    } else if unit == 0x0C {
      buf.write_string("\\f")
    } else if unit == 0x0A {
      buf.write_string("\\n")
    } else if unit == 0x0D {
      buf.write_string("\\r")
    } else if unit == 0x09 {
      buf.write_string("\\t")
    } else if unit < 0x20 || (unit >= 0xD800 && unit <= 0xDFFF) {
      // 控制字符与代理项：JSON 只接受 \uXXXX 形式
      buf.write_string(hex4(unit))
    } else {
      buf.write_char(unit.unsafe_to_char())
    }
    i = i + 1
  }
  buf.to_string()
}

///|
/// 一个只有 `message` 的错误响应。
fn error_response(message : String) -> String {
  "{\"status\":\"error\",\"message\":\"" + json_escape(message) + "\"}"
}

///|
/// 把错误列表拼成 JSON 数组。
fn errors_json(errors : Array[@schema.ValidationError]) -> String {
  let mut out = "["
  let mut i = 0
  while i < errors.length() {
    if i > 0 {
      out = out + ","
    }
    let e = errors[i]
    out = out +
      "{\"instancePath\":\"" +
      json_escape(e.instance_path) +
      "\",\"keyword\":\"" +
      json_escape(e.keyword) +
      "\",\"schemaPath\":\"" +
      json_escape(e.schema_path) +
      "\",\"message\":\"" +
      json_escape(e.message) +
      "\"}"
    i = i + 1
  }
  out + "]"
}

///|
/// 校验结果的统一信封。
fn outcome(status : String, errors : Array[@schema.ValidationError]) -> String {
  "{\"status\":\"" +
  status +
  "\",\"count\":" +
  errors.length().to_string() +
  ",\"errors\":" +
  errors_json(errors) +
  "}"
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

///|
/// 解析一段 JSON 文本，失败时把原因当普通数据返回而不是抛异常——
/// 「输入不是合法 JSON」和「校验不通过」在页面上要显示成完全不同的东西，
/// 不能混成一个错误码。
fn parse_json(text : String) -> Result[Json, String] {
  Ok(@json.parse(text)) catch {
    e => Err(e.to_string())
  }
}

///|
/// 内置的 9 份官方元 schema，只在加载时解析一次。
///
/// 每次都重新解析会在页面上造成几百毫秒的卡顿（约 100 KB JSON），
/// 而这份文档集合是只读的，缓存起来没有任何正确性代价。
let meta_docs : Array[(String, Json)] = @metaschema.metaschema_documents()

///|
/// 从元 schema 文档列表里取出根元 schema。
///
/// 取不到说明生成物和 `metaschema_uri()` 不同步——这是内部错误，
/// 要显式报出来，而不是悄悄退回一个「什么都接受」的空 schema。
fn find_metaschema(docs : Array[(String, Json)]) -> Json? {
  let want = @metaschema.metaschema_uri()
  for entry in docs {
    if entry.0 == want {
      return Some(entry.1)
    }
  }
  None
}

// ---------------------------------------------------------------------------
// 对外暴露的三个动作
// ---------------------------------------------------------------------------

///|
/// `validate(schemaText, instanceText)` —— 用 schema 校验实例。
fn do_validate(schema_text : String, instance_text : String) -> String {
  let schema_node = match parse_json(schema_text) {
    Ok(n) => n
    Err(msg) => return error_response("schema 不是合法 JSON：" + msg)
  }
  let instance = match parse_json(instance_text) {
    Ok(n) => n
    Err(msg) => return error_response("实例不是合法 JSON：" + msg)
  }
  // 预置官方元 schema，这样 schema 里 `$ref` 到
  // `https://json-schema.org/draft/2020-12/schema` 也能解析。
  let compiled = @schema.Schema::of_with_documents(schema_node, meta_docs)
  let errors = compiled.validate(instance)
  if errors.length() == 0 {
    outcome("ok", errors)
  } else {
    outcome("invalid", errors)
  }
}

///|
/// `lint(schemaText)` —— 用官方 2020-12 元 schema 检查 schema 自身。
///
/// 这一项是刻意放进 demo 的：`{"type":"sting"}` 这类笔误在**校验实例**时
/// 永远不会报错（那个关键字只是没人认识而已），只有拿元 schema 校验一遍
/// 才会暴露。它挡的不是「数据不对」，而是「规则本身写错了」。
fn do_lint(schema_text : String) -> String {
  let node = match parse_json(schema_text) {
    Ok(n) => n
    Err(msg) => return error_response("不是合法 JSON：" + msg)
  }
  let meta_node = match find_metaschema(meta_docs) {
    Some(m) => m
    None =>
      return error_response(
        "内部错误：内置元 schema 不完整，找不到根元 schema",
      )
  }
  let compiled = @schema.Schema::of_with_documents(meta_node, meta_docs)
  let errors = compiled.validate(node)
  if errors.length() == 0 {
    outcome("ok", errors)
  } else {
    outcome("invalid", errors)
  }
}

///|
/// `metaschemaList()` —— 列出内置元 schema，供页面展示「装了哪些」。
fn do_metaschema_list() -> String {
  let pairs = @metaschema.metaschema_text_pairs()
  let mut out = "{\"status\":\"ok\",\"count\":" +
    pairs.length().to_string() +
    ",\"items\":["
  let mut i = 0
  while i < pairs.length() {
    if i > 0 {
      out = out + ","
    }
    let (uri, text) = pairs[i]
    out = out +
      "{\"uri\":\"" +
      json_escape(uri) +
      "\",\"chars\":" +
      text.length().to_string() +
      "}"
    i = i + 1
  }
  out + "]}"
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

///|
fn main {
  register_api(do_validate, do_lint, do_metaschema_list)
}
