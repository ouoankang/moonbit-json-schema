// moonbit-json-schema 的命令行入口。
//
// 为什么 CLI 只在 js 后端跑：它要读文件，而 wasm 目标没有文件系统。
// 库本体（src/）不依赖任何平台能力，在 wasm 上通过全部单元测试；
// 需要 IO 的只有这个 cmd/ 下的可执行程序。
//
// 用法：
//   moon run --target js cmd/main -- validate <schema> <instance>...
//   moon run --target js cmd/main -- lint <schema>...
//   moon run --target js cmd/main -- metaschema
//
// 退出码：
//   0  全部通过
//   1  有校验/检查不通过
//   2  命令行用法错误
//   3  文件读不到或 JSON 解析失败

// ---------------------------------------------------------------------------
// 平台 FFI
// ---------------------------------------------------------------------------

#cfg(target="js")
extern "js" fn program_args() -> FixedArray[String] =
  #| () => process.argv.slice(2)

#cfg(target="js")
extern "js" fn file_exists(path : String) -> Bool =
  #| (p) => { try { return require("fs").statSync(p).isFile(); } catch (e) { return false; } }

#cfg(target="js")
extern "js" fn read_text(path : String) -> String =
  #| (p) => require("fs").readFileSync(p, "utf8")

#cfg(target="js")
extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (c) => { process.exitCode = c }

// 非 js 后端给空实现，这样 `moon check` 在任何目标上都不会因为缺 FFI 而失败。
#cfg(not(target="js"))
fn program_args() -> FixedArray[String] {
  []
}

#cfg(not(target="js"))
fn file_exists(path : String) -> Bool {
  ignore(path)
  false
}

#cfg(not(target="js"))
fn read_text(path : String) -> String {
  ignore(path)
  ""
}

#cfg(not(target="js"))
fn set_exit_code(code : Int) -> Unit {
  ignore(code)
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

///|
/// 退出码。
const EXIT_FAILED : Int = 1

///|
const EXIT_USAGE : Int = 2

///|
const EXIT_IO : Int = 3

///|
fn args_array() -> Array[String] {
  let out : Array[String] = []
  for a in program_args() {
    out.push(a)
  }
  out
}

///|
/// 把列宽补齐到 `width`（按字符数，不按显示宽度——这里只用 ASCII 文件名）。
fn pad_right(s : String, width : Int) -> String {
  let mut out = s
  while out.length() < width {
    out = out + " "
  }
  out
}

///|
/// 读一个文件并解析成 JSON。失败时打印原因并返回 `None`。
fn load_json(path : String) -> Json? {
  if !file_exists(path) {
    println("  读不到文件: " + path)
    return None
  }
  let text = read_text(path)
  let parsed = try {
    Some(@json.parse(text))
  } catch {
    e => {
      println("  JSON 解析失败: " + path)
      println("    " + e.to_string())
      None
    }
  }
  parsed
}

///|
fn usage() -> Unit {
  println("moonbit-json-schema —— JSON Schema draft 2020-12 校验器")
  println("")
  println("用法:")
  println("  validate <schema.json> <instance.json>...   用 schema 校验实例")
  println("  lint     <schema.json>...                   检查 schema 自身是否合法")
  println("  metaschema                                  导出内置的官方元 schema")
  println("")
  println("选项:")
  println("  --quiet    只输出结论，不列出每条错误")
  println("")
  println("退出码: 0 通过 / 1 不通过 / 2 用法错误 / 3 读文件或解析失败")
  println("")
  println("示例:")
  println("  moon run --target js cmd/main -- validate examples/person.schema.json examples/person.ok.json")
}

///|
/// 打印一条错误的明细。`indent` 用于对齐。
fn print_error(e : @schema.ValidationError, quiet : Bool) -> Unit {
  if quiet {
    return
  }
  let at = if e.instance_path == "" { "/" } else { e.instance_path }
  // 列宽 30 是照着「最长的实例路径也放得下」定的；超长时宁可让它顶开
  // 关键字那一列，也不要两个字段粘成一个词。
  println(
    "        " +
    pad_right(at, 30) +
    pad_right(e.keyword, 20) +
    e.message,
  )
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

///|
/// `validate <schema> <instance>...`
fn cmd_validate(rest : Array[String], quiet : Bool) -> Unit {
  if rest.length() < 2 {
    println("validate 需要至少一个 schema 和一个实例文件。")
    println("")
    usage()
    set_exit_code(EXIT_USAGE)
    return
  }
  let schema_path = rest[0]
  let schema_node = match load_json(schema_path) {
    Some(n) => n
    None => {
      set_exit_code(EXIT_IO)
      return
    }
  }
  // 预置官方元 schema：这样 schema 里 `$ref` 到
  // `https://json-schema.org/draft/2020-12/schema` 也能解析。
  let compiled = @schema.Schema::of_with_documents(
    schema_node,
    @metaschema.metaschema_documents(),
  )
  println("schema : " + schema_path)
  let mut failed = 0
  for i = 1; i < rest.length(); i = i + 1 {
    let instance_path = rest[i]
    let instance = match load_json(instance_path) {
      Some(n) => n
      None => {
        set_exit_code(EXIT_IO)
        return
      }
    }
    let errors = compiled.validate(instance)
    if errors.length() == 0 {
      println("  " + pad_right(instance_path, 34) + "通过")
    } else {
      failed = failed + 1
      println(
        "  " +
        pad_right(instance_path, 34) +
        "不通过（" +
        errors.length().to_string() +
        " 处）",
      )
      for e in errors {
        print_error(e, quiet)
      }
    }
  }
  if failed > 0 {
    println("")
    println("结果: 有 " + failed.to_string() + " 个实例不通过。")
    set_exit_code(EXIT_FAILED)
  }
}

// ---------------------------------------------------------------------------
// lint
// ---------------------------------------------------------------------------

///|
/// `lint <schema>...` —— 用官方 2020-12 元 schema 检查 schema 自身。
///
/// 这一项之所以重要：`{"type":"sting"}` 这类笔误在**校验实例**时永远不会
/// 报错（那个关键字只是没人认识而已），只有拿元 schema 校验一遍才会暴露。
/// 它挡的不是「数据不对」，而是「规则本身写错了」。
fn cmd_lint(rest : Array[String], quiet : Bool) -> Unit {
  if rest.length() == 0 {
    println("lint 需要至少一个 schema 文件。")
    println("")
    usage()
    set_exit_code(EXIT_USAGE)
    return
  }
  let docs = @metaschema.metaschema_documents()
  let meta_node = match find_metaschema(docs) {
    Some(m) => m
    None => {
      println("内部错误: 内置元 schema 不完整，找不到根元 schema。")
      set_exit_code(EXIT_IO)
      return
    }
  }
  let compiled = @schema.Schema::of_with_documents(meta_node, docs)
  let mut bad = 0
  for path in rest {
    let node = match load_json(path) {
      Some(n) => n
      None => {
        set_exit_code(EXIT_IO)
        return
      }
    }
    let errors = compiled.validate(node)
    if errors.length() == 0 {
      println("  " + pad_right(path, 40) + "合法")
    } else {
      bad = bad + 1
      println(
        "  " +
        pad_right(path, 40) +
        "不符合元 schema（" +
        errors.length().to_string() +
        " 处）",
      )
      for e in errors {
        print_error(e, quiet)
      }
    }
  }
  if bad > 0 {
    println("")
    println("结果: 有 " + bad.to_string() + " 份 schema 不符合元 schema。")
    set_exit_code(EXIT_FAILED)
  }
}

///|
/// 从元 schema 文档列表里取出根元 schema。
///
/// 取不到说明生成物和 `metaschema_uri()` 不同步——这是内部错误，
/// 交给调用方报出来，而不是悄悄退回一个「什么都接受」的空 schema。
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
// metaschema
// ---------------------------------------------------------------------------

///|
/// `metaschema` —— 导出内置的官方元 schema 原文，方便比对或落地成文件。
fn cmd_metaschema() -> Unit {
  for entry in @metaschema.metaschema_text_pairs() {
    println("================================================================")
    println("URI: " + entry.0)
    println("================================================================")
    println(entry.1)
    println("")
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

///|
fn main {
  let args = args_array()
  if args.length() == 0 {
    usage()
    set_exit_code(EXIT_USAGE)
    return
  }
  let command = args[0]
  let rest : Array[String] = []
  let mut quiet = false
  for i = 1; i < args.length(); i = i + 1 {
    if args[i] == "--quiet" {
      quiet = true
    } else {
      rest.push(args[i])
    }
  }
  match command {
    "validate" => cmd_validate(rest, quiet)
    "lint" => cmd_lint(rest, quiet)
    "metaschema" => cmd_metaschema()
    "help" | "--help" | "-h" => usage()
    // 老习惯：不带子命令时，把第一个参数当 schema、其余当实例。
    _ => {
      println("未知子命令: " + command)
      println("")
      usage()
      set_exit_code(EXIT_USAGE)
    }
  }
}
