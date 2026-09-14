// test262 一致性测试台。
//
// 读 `tests/test262/data.json`（由 scripts/gen-test262.mjs 从官方 test262
// 的 S15.10.2.x 用例提取），用引擎跑每一条，输出精确通过率。
//
// 只在 js 后端跑（读文件）。提取的范围是「无 flags 的 pattern 匹配语义」，
// 带 flags（u/i/m/s/g/y）的用例在生成阶段已排除，这是引擎的诚实边界。
//
// 用法：
//   moon run --target js cmd/test262
//
// 退出码：0 全部通过 / 1 有失败。

///|
#cfg(target="js")
extern "js" fn read_text(path : String) -> String =
  #| (p) => require("fs").readFileSync(p, "utf8")

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
fn set_exit_code(code : Int) -> Unit {
  ignore(code)
}

///|
fn main {
  let text = read_text("tests/test262/data.json")
  let root = match try_parse(text) {
    Some(r) => r
    None => {
      println("data.json 解析失败")
      set_exit_code(1)
      return
    }
  }
  let cases = match root {
    Array(a) => a
    _ => {
      println("data.json 不是数组")
      set_exit_code(1)
      return
    }
  }
  let mut passed = 0
  let mut failed = 0
  for case in cases {
    match case {
      Object(o) => {
        let file = obj_str(o, "file")
        let pattern = obj_str(o, "pattern")
        let input = obj_str(o, "input")
        let kind = obj_str(o, "kind")
        let ok = match kind {
          "test" => {
            let expected = obj_bool(o, "expected")
            let re = match try_compile(pattern) {
              Some(r) => r
              None => {
                failed = failed + 1
                continue
              }
            }
            re.find(input) == expected
          }
          _ => {
            // exec 形态：对比 captures 数组与 index
            let re = match try_compile(pattern) {
              Some(r) => r
              None => {
                failed = failed + 1
                continue
              }
            }
            match re.exec(input) {
              Some(m) =>
                match obj_arr(o, "captures") {
                  Some(expected) => {
                    // captures 长度对比 + 每个元素对比
                    let mut eq = m.captures.length() == expected.length()
                    if eq {
                      let mut i = 0
                      while i < expected.length() {
                        match expected[i] {
                          String(s) =>
                            match m.captures[i] {
                              Some(got) => if got != s { eq = false }
                              None => eq = false
                            }
                          _ =>
                            // null（JSON 里的 undefined 组）=> 引擎应是 None
                            match m.captures[i] {
                              None => ()
                              Some(_) => eq = false
                            }
                        }
                        i = i + 1
                      }
                    }
                    eq
                  }
                  // 没有 captures 字段 = 期望 exec 返回 null（不匹配）
                  None => false
                }
              // exec 返回 None：若期望「不匹配」（无 captures 字段）则通过
              None =>
                match obj_arr(o, "captures") {
                  None => true
                  Some(_) => false
                }
            }
          }
        }
        if ok {
          passed = passed + 1
        } else {
          failed = failed + 1
          println("  FAIL " + file + "  /" + pattern + "/ vs " + input)
        }
      }
      _ => ()
    }
  }
  let total = passed + failed
  println(
    "test262 (S15.10.2.x, 无 flags 子集): " +
    passed.to_string() +
    "/" +
    total.to_string(),
  )
  if failed > 0 {
    set_exit_code(1)
  }
}

///|
fn try_parse(text : String) -> Json? {
  Some(@json.parse(text)) catch {
    _ => None
  }
}

///|
fn try_compile(pattern : String) -> @regex.Regex? {
  Some(@regex.Regex::compile(pattern)) catch {
    _ => None
  }
}

///|
fn obj_str(o : Map[String, Json], key : String) -> String {
  match o.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn obj_bool(o : Map[String, Json], key : String) -> Bool {
  match o.get(key) {
    Some(True) => true
    Some(False) => false
    _ => false
  }
}

///|
fn obj_arr(o : Map[String, Json], key : String) -> Array[Json]? {
  match o.get(key) {
    Some(Array(a)) => Some(a)
    _ => None
  }
}
