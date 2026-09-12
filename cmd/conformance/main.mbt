// 官方一致性测试套件（JSON-Schema-Test-Suite）的跑分器。
//
// 这个程序只在 js 后端跑：它通过 JS FFI 直接读测试文件。测试数据随仓库
// 一起版本化（tests/JSON-Schema-Test-Suite），所以结果可复现——
// 不依赖网络，也不依赖你机器上有没有 clone 过官方仓库。
//
// 用法：
//   moon run --target js cmd/conformance
//
// 可选环境变量：
//   JSTS_ONLY=<substr>   只跑文件名里含该子串的用例（调试单个特性时用）
//   JSTS_VERBOSE=1       失败时逐条打印实际/期望

// ---------------------------------------------------------------------------
// JS FFI：文件系统
//
// 非 js 后端给出空实现，这样 `moon check` / `moon test` 在 wasm 上也能过。
// 走 FFI 而不是引入依赖，是因为这个程序本来就是「拿 Node 当宿主」的测试工具，
// 没必要为此把库本体拖上平台相关的实现。
// ---------------------------------------------------------------------------

///|
#cfg(target="js")
extern "js" fn read_text(path : String) -> String =
  #| (p) => require("fs").readFileSync(p, "utf8")

///|
#cfg(target="js")
extern "js" fn list_names(path : String) -> FixedArray[String] =
  #| (p) => require("fs").readdirSync(p)

///|
#cfg(target="js")
extern "js" fn is_dir(path : String) -> Bool =
  #| (p) => { try { return require("fs").statSync(p).isDirectory(); } catch (e) { return false; } }

///|
#cfg(target="js")
extern "js" fn env_var(name : String) -> String =
  #| (n) => process.env[n] || ""

///|
#cfg(target="js")
extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (c) => { process.exitCode = c }

///|
#cfg(not(target="js"))
fn read_text(path : String) -> String {
  ignore(path)
  ""
}

///|
#cfg(not(target="js"))
fn list_names(path : String) -> FixedArray[String] {
  ignore(path)
  []
}

///|
#cfg(not(target="js"))
fn is_dir(path : String) -> Bool {
  ignore(path)
  false
}

///|
#cfg(not(target="js"))
fn env_var(name : String) -> String {
  ignore(name)
  ""
}

///|
#cfg(not(target="js"))
fn set_exit_code(code : Int) -> Unit {
  ignore(code)
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

///|
const SUITE_ROOT : String = "tests/JSON-Schema-Test-Suite"

///|
/// 远程文档的挂载点。官方套件约定 `remotes/` 目录挂在
/// `http://localhost:1234/` 下，`refRemote.json` 里的引用就指向这里。
const REMOTE_BASE : String = "http://localhost:1234/"

///|
fn try_parse(text : String) -> Json? {
  Some(@json.parse(text)) catch {
    _ => None
  }
}

///|
fn field_str(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// 目录下的名字，转成可变的 `Array`。
fn dir_names(path : String) -> Array[String] {
  let out : Array[String] = []
  for name in list_names(path) {
    out.push(name)
  }
  out
}

///|
fn pad_right(s : String, width : Int) -> String {
  let mut out = s
  while out.length() < width {
    out = out + " "
  }
  out
}

///|
/// 就地插入排序。文件名数量很小，没必要为它引入泛型比较器。
fn sort_strings(a : Array[String]) -> Unit {
  let n = a.length()
  for i = 1; i < n; i = i + 1 {
    let key = a[i]
    let mut j = i - 1
    while j >= 0 && a[j] > key {
      a[j + 1] = a[j]
      j = j - 1
    }
    a[j + 1] = key
  }
}

// ---------------------------------------------------------------------------
// 计分
// ---------------------------------------------------------------------------

///|
struct Tally {
  mut total : Int
  mut passed : Int
  failures : Array[String]
}

///|
fn Tally::new() -> Tally {
  { total: 0, passed: 0, failures: [], }
}

///|
fn Tally::failed(self : Tally) -> Int {
  self.total - self.passed
}

///|
fn Tally::record(self : Tally, ok : Bool, label : String) -> Unit {
  self.total = self.total + 1
  if ok {
    self.passed = self.passed + 1
  } else {
    self.failures.push(label)
  }
}

///|
fn Tally::merge(self : Tally, other : Tally) -> Unit {
  self.total = self.total + other.total
  self.passed = self.passed + other.passed
  for f in other.failures {
    self.failures.push(f)
  }
}

///|
/// 百分比，一位小数。用整数运算，避免浮点打印出 `98.19999999`。
fn percent(passed : Int, total : Int) -> String {
  if total == 0 {
    return "n/a"
  }
  let tenths = passed * 1000 / total
  (tenths / 10).to_string() + "." + (tenths % 10).to_string() + "%"
}

// ---------------------------------------------------------------------------
// 远程文档
// ---------------------------------------------------------------------------

///|
/// 递归收集 `remotes/` 下的文档，映射成 `http://localhost:1234/<相对路径>`。
fn collect_remotes(
  dir : String,
  prefix : String,
  acc : Array[(String, Json)],
) -> Unit {
  for name in dir_names(dir) {
    let full = dir + "/" + name
    if is_dir(full) {
      collect_remotes(full, prefix + name + "/", acc)
    } else if name.has_suffix(".json") {
      match try_parse(read_text(full)) {
        Some(node) => acc.push((REMOTE_BASE + prefix + name, node))
        None => println("  ! 远程文档解析失败: " + full)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 跑一个文件
// ---------------------------------------------------------------------------

///|
/// 跑一个测试文件里的所有用例，返回本文件的计分。
///
/// schema 按 group 编译一次、复用到该 group 的全部用例上——既省时间，
/// 也更接近真实用法（一份 schema 校验多个实例）。
fn run_file(
  path : String,
  label : String,
  remotes : Array[(String, Json)],
  verbose : Bool,
) -> Tally {
  let t = Tally::new()
  let doc = match try_parse(read_text(path)) {
    Some(d) => d
    None => {
      println("  ! 解析失败: " + path)
      return t
    }
  }
  let groups = match doc {
    Array(gs) => gs
    _ => return t
  }
  for group in groups {
    match group {
      // 缺 `schema` 或缺 `tests` 的 group 在官方套件里不存在，直接跳过。
      Object(g) =>
        match g.get("schema") {
          Some(schema_node) =>
            match g.get("tests") {
              Some(Array(cases)) => {
                let description = field_str(g, "description")
                let compiled = @schema.Schema::of_with_documents(
                  schema_node, remotes,
                )
                for case in cases {
                  match case {
                    Object(c) =>
                      match c.get("data") {
                        Some(data) => {
                          let expected = match c.get("valid") {
                            Some(True) => true
                            Some(False) => false
                            _ => true
                          }
                          let actual = compiled.validate(data).length() == 0
                          let ok = actual == expected
                          let case_desc = field_str(c, "description")
                          if !ok && verbose {
                            println(
                              "    x " +
                              label +
                              " :: " +
                              description +
                              " :: " +
                              case_desc +
                              "  (期望 " +
                              expected.to_string() +
                              ", 实际 " +
                              actual.to_string() +
                              ")",
                            )
                          }
                          t.record(
                            ok,
                            label + " :: " + description + " :: " + case_desc,
                          )
                        }
                        None => ()
                      }
                    _ => ()
                  }
                }
              }
              _ => ()
            }
          None => ()
        }
      _ => ()
    }
  }
  t
}

///|
/// 目录下的 `.json` 文件名（排序后）。
fn json_files(dir : String) -> Array[String] {
  let names : Array[String] = []
  if is_dir(dir) {
    for name in dir_names(dir) {
      if name.has_suffix(".json") && !is_dir(dir + "/" + name) {
        names.push(name)
      }
    }
  }
  sort_strings(names)
  names
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

///|
fn main {
  let only = env_var("JSTS_ONLY")
  let verbose = env_var("JSTS_VERBOSE") != ""

  println("JSON-Schema-Test-Suite / draft2020-12")
  println("  套件目录      : " + SUITE_ROOT)
  if only != "" {
    println("  文件名过滤    : " + only)
  }

  let remotes : Array[(String, Json)] = []
  collect_remotes(SUITE_ROOT + "/remotes", "", remotes)
  // 官方元 schema **不在**套件的 remotes/ 里——套件的约定是实现自己提供它。
  // ref.json / defs.json 里有 `$ref: "https://json-schema.org/draft/2020-12/schema"`
  // 的用例（「用元 schema 校验 schema」），没有这几份文档就只能算作无法解析。
  let meta_docs = @metaschema.metaschema_documents()
  for entry in meta_docs {
    remotes.push(entry)
  }
  println(
    "  远程文档      : " +
    (remotes.length() - meta_docs.length()).to_string() +
    " 份远程 + " +
    meta_docs.length().to_string() +
    " 份官方元 schema",
  )
  println("")

  // ---- 必测部分 -----------------------------------------------------------
  println("== 必测 ==")
  let required = Tally::new()
  for name in json_files(SUITE_ROOT + "/draft2020-12") {
    if only == "" || name.contains(only) {
      let one = run_file(
        SUITE_ROOT + "/draft2020-12/" + name,
        name,
        remotes,
        verbose,
      )
      let mark = if one.failed() == 0 { "ok  " } else { "FAIL" }
      println(
        "  " +
        mark +
        "  " +
        pad_right(name, 32) +
        one.passed.to_string() +
        "/" +
        one.total.to_string(),
      )
      required.merge(one)
    }
  }
  println("")
  println(
    "  必测合计: " +
    required.passed.to_string() +
    "/" +
    required.total.to_string() +
    "  " +
    percent(required.passed, required.total),
  )

  // ---- 可选部分 -----------------------------------------------------------
  let optional = Tally::new()
  let optional_dir = SUITE_ROOT + "/draft2020-12/optional"
  if is_dir(optional_dir) {
    println("")
    println("== 可选（optional/，规范上允许不实现）==")
    for name in json_files(optional_dir) {
      if only == "" || name.contains(only) {
        let one = run_file(
          optional_dir + "/" + name,
          "optional/" + name,
          remotes,
          verbose,
        )
        optional.merge(one)
        if one.failed() > 0 {
          println(
            "  FAIL  " +
            pad_right(name, 30) +
            one.passed.to_string() +
            "/" +
            one.total.to_string(),
          )
        }
      }
    }
    let format_dir = optional_dir + "/format"
    for name in json_files(format_dir) {
      if only == "" || name.contains(only) {
        let one = run_file(
          format_dir + "/" + name,
          "optional/format/" + name,
          remotes,
          verbose,
        )
        optional.merge(one)
        if one.failed() > 0 {
          println(
            "  FAIL  " +
            pad_right("format/" + name, 30) +
            one.passed.to_string() +
            "/" +
            one.total.to_string(),
          )
        }
      }
    }
    println("")
    println(
      "  可选合计: " +
      optional.passed.to_string() +
      "/" +
      optional.total.to_string() +
      "  " +
      percent(optional.passed, optional.total),
    )
  }

  // ---- 失败样例 -----------------------------------------------------------
  let shown = if verbose { 300 } else { 30 }
  let all : Array[String] = []
  for f in required.failures {
    all.push(f)
  }
  for f in optional.failures {
    all.push(f)
  }
  if all.length() > 0 {
    println("")
    println("== 失败样例（最多 " + shown.to_string() + " 条）==")
    let n = if all.length() < shown { all.length() } else { shown }
    for i = 0; i < n; i = i + 1 {
      println("  " + all[i])
    }
  }

  set_exit_code(if required.failed() == 0 { 0 } else { 1 })
}
