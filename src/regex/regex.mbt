// 一个 ECMA-262 正则引擎（自研，无外部依赖）。
//
// 为什么自己写：JSON Schema 的 `pattern` / `patternProperties` 规定用
// ECMA-262 正则，而 MoonBit 核心库的 `core/string` 正则走的是 lexmatch
// 语义——没有 `\d`/`\w`/`\s`，`.` 会吃掉换行，字符类是 ASCII 区间。
// 这些差异在真实 schema 里会直接导致误判，所以这里按 ECMA-262 重新实现。
//
// 实现要点：
//
//   * **按码点匹配**。输入先转成「码点数组」，所以 `^🐲*$` 里的 🐲 是
//     一个元素而不是两个代理项，顺带绕开了 UTF-16 代理项配对的问题。
//   * **回溯 + 延续传递（CPS）**。用一个 `(下一位置) -> 是否成功` 的延续
//     来表达「剩下的部分」，量词、分支、前后瞻都靠它自然组合。
//     代价是没有线性时间保证——但 ECMA-262 本来就要求回溯语义
//     （反向引用离不开它），所以这个取舍是必须的。
//   * **失败时不留痕迹**。捕获组在延续返回 false 时回滚，否则分支回溯
//     会把上一次尝试的捕获结果带出来，反向引用就错了。
//   * `\p{...}` 需要 Unicode 一般类别数据，见同目录 `unicode_categories.mbt`
//     （由 `scripts/gen-unicode-categories.mjs` 生成）。


///|
/// 正则语法错误。`Regex::compile` 在模式不合法时抛出。
pub(all) suberror RegexError {
  /// 说明信息，含出错位置（按码点计数）。
  SyntaxError(String)
} derive(Eq, @debug.Debug)

///|
pub impl Show for RegexError with fn output(self, logger) {
  match self {
    SyntaxError(message) =>
      logger.write_string("invalid regular expression: " + message)
  }
}

///|
/// 反向引用的目标。
///
/// `\1` 直接给编号；`\k<name>` 给名字，真正解析推到匹配时做——这样
/// 「先引用后定义」的写法也能工作，不需要在 AST 上再做一趟改写。
priv enum RefTarget {
  ByIndex(Int)
  ByName(String)
}

///|
/// AST 节点。
///
/// 字符一律用**码点**（`Int`）表示，不用 `Char` 或 `UInt16`：这样字符类
/// 区间、转义、`\p{...}` 的判定全部落在同一套整数比较上。
priv enum Node {
  Lit(Int)
  AnyChar
  Class(CharClass)
  Seq(Array[Node])
  Alt(Array[Node])
  /// 量词：`(子式, 最少次数, 最多次数(-1 表示无穷), 是否贪婪)`
  Repeat(Node, Int, Int, Bool)
  /// 捕获组，带编号。
  Group(Int, Node)
  NonCapture(Node)
  /// 前后瞻：`(子式, 是否后瞻, 是否取反)`
  Look(Node, Bool, Bool)
  Backref(RefTarget)
  StartAnchor
  EndAnchor
  /// `\b`(true) / `\B`(false)
  WordBoundary(Bool)
  /// `\p{名}` / `\P{名}`
  Prop(String, Bool)
}

///|
priv struct CharClass {
  negated : Bool
  items : Array[ClassItem]
}

///|
priv enum ClassItem {
  /// 单个字符
  CSingle(Int)
  /// 闭区间 `[lo, hi]`
  CRange(Int, Int)
  /// `\d \D \w \W \s \S`，记原始转义字母
  CBuiltin(Int)
  /// 类内的 `\p{...}` / `\P{...}`
  CProp(String, Bool)
}

// ---------------------------------------------------------------------------
// Unicode 一般类别
// ---------------------------------------------------------------------------

///|
/// 码点 -> 一般类别下标。区间表覆盖整个码点空间，二分查找必定命中。
fn category_of(cp : Int) -> Int {
  let runs = unicode_runs
  let mut lo = 0
  let mut hi = runs.length() - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    let entry = runs[mid]
    let start = entry.0
    let stop = entry.1
    if cp < start {
      hi = mid - 1
    } else if cp > stop {
      lo = mid + 1
    } else {
      return entry.2
    }
  }
  cat_Cn
}

///|
/// 码点所属一般类别的**名字**（`"Lu"`、`"Nd"`……）。
///
/// 给调试和错误信息用。同时它也让 `unicode_category_names` 那张名字表
/// 在库构建里真的有读者，而不是一条仅供测试引用的死数据。
pub fn category_name_of(cp : Int) -> String {
  unicode_category_names[category_of(cp)]
}

///|
/// 属性名 -> 允许的类别下标集合。**空数组**表示这是个不认识的属性名
/// （没有哪个属性真的对应空集合，所以拿它当哨兵是安全的）。
///
/// 同时接受短名（`L`）和长名（`Letter`），以及几个历史别名
/// （`digit`、`punct`、`cntrl`）——`digit` 是实现之间流传最广的那个，
/// 官方测试套件里有专门用例。
///
/// 注意 `digit` 只对应 `Nd`（十进制数字），不是 `N`（数字全体）：
/// 用例要求 `\p{digit}` 匹配孟加拉数字但 `\d` 只匹配 ASCII。
fn property_categories(name : String) -> Array[Int] {
  match name {
    "L" | "Letter" => [cat_Lu, cat_Ll, cat_Lt, cat_Lm, cat_Lo]
    "Lu" | "Uppercase_Letter" => [cat_Lu]
    "Ll" | "Lowercase_Letter" => [cat_Ll]
    "Lt" | "Titlecase_Letter" => [cat_Lt]
    "Lm" | "Modifier_Letter" => [cat_Lm]
    "Lo" | "Other_Letter" => [cat_Lo]
    "M" | "Mark" | "Combining_Mark" => [cat_Mn, cat_Mc, cat_Me]
    "Mn" | "Nonspacing_Mark" => [cat_Mn]
    "Mc" | "Spacing_Mark" => [cat_Mc]
    "Me" | "Enclosing_Mark" => [cat_Me]
    "N" | "Number" => [cat_Nd, cat_Nl, cat_No]
    "Nd" | "Decimal_Number" | "digit" => [cat_Nd]
    "Nl" | "Letter_Number" => [cat_Nl]
    "No" | "Other_Number" => [cat_No]
    "P" | "Punctuation" | "punct" => [
      cat_Pc, cat_Pd, cat_Ps, cat_Pe, cat_Pi, cat_Pf, cat_Po,
    ]
    "Pc" | "Connector_Punctuation" => [cat_Pc]
    "Pd" | "Dash_Punctuation" => [cat_Pd]
    "Ps" | "Open_Punctuation" => [cat_Ps]
    "Pe" | "Close_Punctuation" => [cat_Pe]
    "Pi" | "Initial_Punctuation" => [cat_Pi]
    "Pf" | "Final_Punctuation" => [cat_Pf]
    "Po" | "Other_Punctuation" => [cat_Po]
    "S" | "Symbol" => [cat_Sm, cat_Sc, cat_Sk, cat_So]
    "Sm" | "Math_Symbol" => [cat_Sm]
    "Sc" | "Currency_Symbol" => [cat_Sc]
    "Sk" | "Modifier_Symbol" => [cat_Sk]
    "So" | "Other_Symbol" => [cat_So]
    "Z" | "Separator" => [cat_Zs, cat_Zl, cat_Zp]
    "Zs" | "Space_Separator" => [cat_Zs]
    "Zl" | "Line_Separator" => [cat_Zl]
    "Zp" | "Paragraph_Separator" => [cat_Zp]
    "C" | "Other" => [cat_Cc, cat_Cf, cat_Cs, cat_Co, cat_Cn]
    "Cc" | "Control" | "cntrl" => [cat_Cc]
    "Cf" | "Format" => [cat_Cf]
    "Cs" | "Surrogate" => [cat_Cs]
    "Co" | "Private_Use" => [cat_Co]
    "Cn" | "Unassigned" => [cat_Cn]
    _ => []
  }
}

///|
/// `\p{name}` 是否匹配码点 `cp`。
fn prop_matches(name : String, cp : Int) -> Bool {
  match name {
    // `Any` 和 `ASCII` 不是一般类别，是 ECMAScript 额外给的二元属性。
    "Any" => true
    "ASCII" => cp <= 0x7F
    _ => {
      let cat = category_of(cp)
      let allowed = property_categories(name)
      for c in allowed {
        if c == cat {
          return true
        }
      }
      false
    }
  }
}

///|
/// 属性名是否被支持。未知属性名按 ECMAScript 的规定是**语法错误**。
fn is_known_property(name : String) -> Bool {
  match name {
    "Any" | "ASCII" => true
    _ => property_categories(name).length() > 0
  }
}

// ---------------------------------------------------------------------------
// 字符谓词
// ---------------------------------------------------------------------------

///|
/// 行终止符。ECMA-262 里 `.` 不吃它们。
fn is_line_terminator(cp : Int) -> Bool {
  cp == 0x0A || cp == 0x0D || cp == 0x2028 || cp == 0x2029
}

///|
/// ECMAScript 的 `\s`：WhiteSpace ∪ LineTerminator。
///
/// 注意这**不是** Unicode 的 `\p{Zs}` 的简单别名——除了空格类还包括
/// TAB/CR/LF 等控制字符和 U+FEFF。
fn is_ecma_space(cp : Int) -> Bool {
  if cp == 0x09 || cp == 0x0A || cp == 0x0B || cp == 0x0C || cp == 0x0D {
    return true
  }
  if cp == 0x20 || cp == 0xA0 || cp == 0xFEFF {
    return true
  }
  if cp == 0x2028 || cp == 0x2029 {
    return true
  }
  // 其余就是 Unicode 的空格分隔符（Zs）。
  category_of(cp) == cat_Zs
}

///|
/// ECMAScript 的 `\w`：ASCII 字母数字下划线。**不含**非 ASCII 字符。
fn is_word_cp(cp : Int) -> Bool {
  (cp >= 0x30 && cp <= 0x39) ||
  (cp >= 0x41 && cp <= 0x5A) ||
  (cp >= 0x61 && cp <= 0x7A) ||
  cp == 0x5F
}

///|
/// ECMAScript 的 `\d`：ASCII 数字。孟加拉数字之类的**不算**。
fn is_digit_cp(cp : Int) -> Bool {
  cp >= 0x30 && cp <= 0x39
}

///|
/// `\d \D \w \W \s \S` 的判定。`letter` 是转义里的字母本身。
fn builtin_matches(letter : Int, cp : Int) -> Bool {
  match letter {
    0x64 => is_digit_cp(cp) // d
    0x44 => !is_digit_cp(cp) // D
    0x77 => is_word_cp(cp) // w
    0x57 => !is_word_cp(cp) // W
    0x73 => is_ecma_space(cp) // s
    0x53 => !is_ecma_space(cp) // S
    _ => false
  }
}

///|
/// `d` / `D` / `w` / `W` / `s` / `S` 这六个转义字母。
fn is_builtin_class_letter(cp : Int) -> Bool {
  cp == 0x64 ||
  cp == 0x44 ||
  cp == 0x77 ||
  cp == 0x57 ||
  cp == 0x73 ||
  cp == 0x53
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

///|
priv struct Parser {
  src : Array[Int]
  mut pos : Int
  mut groups : Int
  names : Map[String, Int]
}

///|
fn to_code_points(s : String) -> Array[Int] {
  let out : Array[Int] = []
  for c in s {
    out.push(c.to_int())
  }
  out
}

///|
fn hex_value(cp : Int) -> Int {
  if cp >= 0x30 && cp <= 0x39 {
    cp - 0x30
  } else if (cp >= 0x61 && cp <= 0x66) || (cp >= 0x41 && cp <= 0x46) {
    (cp | 0x20) - 0x61 + 10
  } else {
    -1
  }
}

///|
fn Parser::peek(self : Parser) -> Int {
  if self.pos < self.src.length() {
    self.src[self.pos]
  } else {
    -1
  }
}

///|
fn Parser::at(self : Parser, offset : Int) -> Int {
  let i = self.pos + offset
  if i < self.src.length() {
    self.src[i]
  } else {
    -1
  }
}

///|
fn Parser::eof(self : Parser) -> Bool {
  self.pos >= self.src.length()
}

///|
fn Parser::slice_text(self : Parser, from : Int, to : Int) -> String {
  let sb = StringBuilder()
  for i = from; i < to; i = i + 1 {
    sb.write_char(Int::unsafe_to_char(self.src[i]))
  }
  sb.to_string()
}

///|
/// 解析整条模式。语法错误时返回说明文字。
/// 返回 `(顶层节点序列, 命名组表, 最大组号)`。
fn parse_pattern(
  pattern : String,
) -> Result[(Array[Node], Map[String, Int], Int), String] {
  let p : Parser = {
    src: to_code_points(pattern),
    pos: 0,
    groups: 0,
    names: Map([]),
  }
  let node = match p.parse_disjunction() {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  if !p.eof() {
    // 走到这里说明还剩一个没被消费的 `)`。
    return Err("unexpected ')' at offset " + p.pos.to_string())
  }
  // 顶层包一层 Seq，之后统一按序列处理。
  Ok(([node], p.names, p.groups))
}

///|
fn Parser::parse_disjunction(self : Parser) -> Result[Node, String] {
  let branches : Array[Node] = []
  while true {
    let branch = match self.parse_alternative() {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    branches.push(branch)
    if self.peek() == 0x7C {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
  if branches.length() == 1 {
    Ok(branches[0])
  } else {
    Ok(Alt(branches))
  }
}

///|
/// 一串原子。遇到 `|` 或 `)` 就收手——它们由调用方处理。
fn Parser::parse_alternative(self : Parser) -> Result[Node, String] {
  let terms : Array[Node] = []
  while !self.eof() && self.peek() != 0x7C && self.peek() != 0x29 {
    let term = match self.parse_term() {
      Ok(t) => t
      Err(e) => return Err(e)
    }
    terms.push(term)
  }
  if terms.length() == 1 {
    Ok(terms[0])
  } else {
    Ok(Seq(terms))
  }
}

///|
/// 一个原子 + 可选量词。
fn Parser::parse_term(self : Parser) -> Result[Node, String] {
  let atom = match self.parse_atom() {
    Ok(a) => a
    Err(e) => return Err(e)
  }
  let bounds = match self.peek() {
    0x2A => {
      self.pos = self.pos + 1
      Some((0, -1))
    }
    0x2B => {
      self.pos = self.pos + 1
      Some((1, -1))
    }
    0x3F => {
      self.pos = self.pos + 1
      Some((0, 1))
    }
    0x7B =>
      // `{` 只有形如量词时才当量词，否则退回字面量（Annex B 行为）。
      match self.try_parse_braces() {
        Ok(found) => found
        Err(e) => return Err(e)
      }
    _ => None
  }
  match bounds {
    None => Ok(atom)
    Some(pair) => {
      let lazy_ = if self.peek() == 0x3F {
        self.pos = self.pos + 1
        true
      } else {
        false
      }
      Ok(Repeat(atom, pair.0, pair.1, !lazy_))
    }
  }
}

///|
/// 尽力解析 `{n}` / `{n,}` / `{n,m}`。
///
/// 返回 `Ok(None)` 表示「这不是量词」——此时必须把位置**回退**到 `{` 之前，
/// 让 `{` 当普通字符处理（ECMAScript Annex B 的宽松行为）。
fn Parser::try_parse_braces(self : Parser) -> Result[(Int, Int)?, String] {
  let save = self.pos
  self.pos = self.pos + 1 // 跳过 '{'
  let mut lo = 0
  let mut lo_digits = 0
  while !self.eof() {
    let d = hex_value(self.peek())
    if d >= 0 && d < 10 {
      lo = lo * 10 + d
      lo_digits = lo_digits + 1
      self.pos = self.pos + 1
    } else {
      break
    }
  }
  if lo_digits == 0 {
    self.pos = save
    return Ok(None)
  }
  let mut hi = lo
  if self.peek() == 0x2C {
    self.pos = self.pos + 1
    if self.peek() == 0x7D {
      hi = -1
    } else {
      let mut value = 0
      let mut hi_digits = 0
      while !self.eof() {
        let d = hex_value(self.peek())
        if d >= 0 && d < 10 {
          value = value * 10 + d
          hi_digits = hi_digits + 1
          self.pos = self.pos + 1
        } else {
          break
        }
      }
      if hi_digits == 0 {
        self.pos = save
        return Ok(None)
      }
      hi = value
    }
  }
  if self.peek() != 0x7D {
    self.pos = save
    return Ok(None)
  }
  self.pos = self.pos + 1
  if hi >= 0 && hi < lo {
    return Err("quantifier bounds out of order at offset " + save.to_string())
  }
  Ok(Some((lo, hi)))
}

///|
fn Parser::parse_atom(self : Parser) -> Result[Node, String] {
  if self.eof() {
    return Err("unexpected end of pattern")
  }
  let cp = self.peek()
  match cp {
    0x28 => self.parse_group() // (
    0x5B => self.parse_class() // [
    0x2E => {
      self.pos = self.pos + 1
      Ok(AnyChar)
    }
    0x5E => {
      self.pos = self.pos + 1
      Ok(StartAnchor)
    }
    0x24 => {
      self.pos = self.pos + 1
      Ok(EndAnchor)
    }
    0x5C => self.parse_escape(false)
    0x29 => Err("unmatched ')' at offset " + self.pos.to_string())
    0x2A | 0x2B | 0x3F =>
      Err("nothing to repeat at offset " + self.pos.to_string())
    _ => {
      self.pos = self.pos + 1
      Ok(Lit(cp))
    }
  }
}

///|
/// 读一个 `\p{...}` 的名字并校验，位置停在 `}` 之后。
fn Parser::read_property(self : Parser, offset : Int) -> Result[String, String] {
  if self.peek() != 0x7B {
    return Err("expected '{' after \\p at offset " + offset.to_string())
  }
  self.pos = self.pos + 1
  let name_start = self.pos
  while !self.eof() && self.peek() != 0x7D {
    self.pos = self.pos + 1
  }
  if self.eof() {
    return Err("unclosed \\p{...} at offset " + offset.to_string())
  }
  let name = self.slice_text(name_start, self.pos)
  self.pos = self.pos + 1
  if !is_known_property(name) {
    return Err(
      "unknown Unicode property '" + name + "' at offset " + name_start.to_string(),
    )
  }
  Ok(name)
}

///|
fn Parser::parse_group(self : Parser) -> Result[Node, String] {
  let start = self.pos
  self.pos = self.pos + 1 // 跳过 '('
  if self.peek() != 0x3F {
    self.groups = self.groups + 1
    let index = self.groups
    let inner = match self.parse_disjunction() {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if self.peek() != 0x29 {
      return Err("unclosed group starting at offset " + start.to_string())
    }
    self.pos = self.pos + 1
    return Ok(Group(index, inner))
  }
  self.pos = self.pos + 1
  match self.peek() {
    0x3A => {
      // (?: ... )
      self.pos = self.pos + 1
      self.finish_group(start, fn(inner : Node) -> Node { NonCapture(inner) })
    }
    0x3D => {
      // (?= ... )
      self.pos = self.pos + 1
      self.finish_group(start, fn(inner : Node) -> Node { Look(inner, false, false) })
    }
    0x21 => {
      // (?! ... )
      self.pos = self.pos + 1
      self.finish_group(start, fn(inner : Node) -> Node { Look(inner, false, true) })
    }
    0x3C =>
      match self.at(1) {
        0x3D | 0x21 => {
          // (?<= ... ) / (?<! ... )
          let negated = self.at(1) == 0x21
          self.pos = self.pos + 2
          self.finish_group(start, fn(inner : Node) -> Node {
            Look(inner, true, negated)
          })
        }
        _ => {
          // (?<name> ... )
          self.pos = self.pos + 1
          let name_start = self.pos
          while !self.eof() && self.peek() != 0x3E {
            self.pos = self.pos + 1
          }
          if self.eof() {
            return Err(
              "unclosed group name at offset " + name_start.to_string(),
            )
          }
          let name = self.slice_text(name_start, self.pos)
          if name.length() == 0 {
            return Err("empty group name at offset " + name_start.to_string())
          }
          self.pos = self.pos + 1 // 跳过 '>'
          self.groups = self.groups + 1
          let index = self.groups
          self.names.set(name, index)
          let inner = match self.parse_disjunction() {
            Ok(n) => n
            Err(e) => return Err(e)
          }
          if self.peek() != 0x29 {
            return Err("unclosed group starting at offset " + start.to_string())
          }
          self.pos = self.pos + 1
          Ok(Group(index, inner))
        }
      }
    _ => Err("unsupported group type '(?' at offset " + start.to_string())
  }
}

///|
/// 读完组体并要求收尾的 `)`，然后用 `wrap` 组装节点。
fn Parser::finish_group(
  self : Parser,
  start : Int,
  wrap : (Node) -> Node,
) -> Result[Node, String] {
  let inner = match self.parse_disjunction() {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  if self.peek() != 0x29 {
    return Err("unclosed group starting at offset " + start.to_string())
  }
  self.pos = self.pos + 1
  Ok(wrap(inner))
}

///|
/// 解析类外转义。
fn Parser::parse_escape(self : Parser, in_class : Bool) -> Result[Node, String] {
  let start = self.pos
  self.pos = self.pos + 1 // 跳过 '\'
  if self.eof() {
    return Err("trailing backslash at offset " + start.to_string())
  }
  let cp = self.peek()
  if is_builtin_class_letter(cp) {
    // `\d` 之类在类外也合法：包成一个单元素字符类即可，判定逻辑不用分叉。
    self.pos = self.pos + 1
    return Ok(Class({ negated: false, items: [CBuiltin(cp)] }))
  }
  match cp {
    0x62 => {
      // \b：类内是退格，类外是词边界
      self.pos = self.pos + 1
      if in_class {
        Ok(Lit(0x08))
      } else {
        Ok(WordBoundary(true))
      }
    }
    0x42 => {
      self.pos = self.pos + 1
      if in_class {
        Ok(Lit(0x42))
      } else {
        Ok(WordBoundary(false))
      }
    }
    0x70 | 0x50 => {
      let negated = cp == 0x50
      self.pos = self.pos + 1
      let name = match self.read_property(start) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      Ok(Prop(name, negated))
    }
    0x6B => {
      // \k<name>
      self.pos = self.pos + 1
      if self.peek() != 0x3C {
        return Err("expected '<' after \\k at offset " + start.to_string())
      }
      self.pos = self.pos + 1
      let name_start = self.pos
      while !self.eof() && self.peek() != 0x3E {
        self.pos = self.pos + 1
      }
      if self.eof() {
        return Err("unclosed \\k<...> at offset " + start.to_string())
      }
      let name = self.slice_text(name_start, self.pos)
      self.pos = self.pos + 1
      Ok(Backref(ByName(name)))
    }
    _ => {
      if cp >= 0x31 && cp <= 0x39 {
        // 数字反向引用
        let mut value = 0
        while !self.eof() {
          let d = hex_value(self.peek())
          if d >= 0 && d < 10 {
            value = value * 10 + d
            self.pos = self.pos + 1
          } else {
            break
          }
        }
        return Ok(Backref(ByIndex(value)))
      }
      match self.read_char_escape() {
        Some(code) => Ok(Lit(code))
        None => Err("invalid escape at offset " + start.to_string())
      }
    }
  }
}

///|
/// 解析「一个字符」的转义，返回它的码点。位置停在转义之后。
fn Parser::read_char_escape(self : Parser) -> Int? {
  if self.eof() {
    return None
  }
  let cp = self.peek()
  self.pos = self.pos + 1
  match cp {
    0x74 => Some(0x09) // \t
    0x6E => Some(0x0A) // \n
    0x76 => Some(0x0B) // \v
    0x66 => Some(0x0C) // \f
    0x72 => Some(0x0D) // \r
    0x30 =>
      // \0：后面不能再跟十进制数字，否则在非 u 模式下有歧义
      if self.peek() >= 0x30 && self.peek() <= 0x39 {
        None
      } else {
        Some(0x00)
      }
    0x78 => self.read_hex(2) // \xHH
    0x75 =>
      // \uHHHH 或 \u{H+}
      if self.peek() == 0x7B {
        self.pos = self.pos + 1
        let mut value = 0
        let mut digits = 0
        while !self.eof() && self.peek() != 0x7D {
          let d = hex_value(self.peek())
          if d < 0 || value > 0x10FFFF {
            return None
          }
          value = value * 16 + d
          digits = digits + 1
          self.pos = self.pos + 1
        }
        if self.eof() || digits == 0 || value > 0x10FFFF {
          return None
        }
        self.pos = self.pos + 1
        Some(value)
      } else {
        self.read_hex(4)
      }
    0x63 =>
      // \cX：控制转义，X 必须是 ASCII 字母
      if self.eof() {
        None
      } else {
        let letter = self.peek()
        if (letter >= 0x41 && letter <= 0x5A) || (letter >= 0x61 && letter <= 0x7A) {
          self.pos = self.pos + 1
          Some(letter % 32)
        } else {
          // Annex B：`\c` 后面不是字母时按字面量 'c' 处理
          Some(0x63)
        }
      }
    // 其余在非 u 模式下都是「恒等转义」，就是字符本身（`\a`、`\/`、`\ ` …）
    _ => Some(cp)
  }
}

///|
fn Parser::read_hex(self : Parser, count : Int) -> Int? {
  let mut value = 0
  for step = 0; step < count; step = step + 1 {
    if self.eof() {
      return None
    }
    let d = hex_value(self.peek())
    if d < 0 {
      return None
    }
    value = value * 16 + d
    self.pos = self.pos + 1
  }
  Some(value)
}

///|
fn Parser::parse_class(self : Parser) -> Result[Node, String] {
  let start = self.pos
  self.pos = self.pos + 1 // 跳过 '['
  let negated = if self.peek() == 0x5E {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
  let items : Array[ClassItem] = []
  // ECMAScript 里 `[]` 是空类（什么都不匹配），没有 POSIX 那种
  // 「首位的 `]` 当字面量」的特例。
  while !self.eof() && self.peek() != 0x5D {
    let first = match self.parse_class_atom() {
      Ok(i) => i
      Err(e) => return Err(e)
    }
    // 形如 `a-z` 才是区间：`-` 后面还得有字符，且不能是收尾的 `]`。
    if self.peek() == 0x2D && self.at(1) != 0x5D && self.at(1) != -1 {
      self.pos = self.pos + 1
      let second = match self.parse_class_atom() {
        Ok(i) => i
        Err(e) => return Err(e)
      }
      match (first, second) {
        (CSingle(lo), CSingle(hi)) =>
          if lo > hi {
            return Err(
              "character class range out of order at offset " + start.to_string(),
            )
          } else {
            items.push(CRange(lo, hi))
          }
        _ =>
          return Err(
            "invalid character class range at offset " + start.to_string(),
          )
      }
    } else {
      items.push(first)
    }
  }
  if self.eof() {
    return Err("unclosed character class at offset " + start.to_string())
  }
  self.pos = self.pos + 1 // 跳过 ']'
  Ok(Class({ negated, items }))
}

///|
fn Parser::parse_class_atom(self : Parser) -> Result[ClassItem, String] {
  if self.eof() {
    return Err("unterminated character class")
  }
  let cp = self.peek()
  if cp != 0x5C {
    self.pos = self.pos + 1
    return Ok(CSingle(cp))
  }
  let start = self.pos
  self.pos = self.pos + 1
  if self.eof() {
    return Err("trailing backslash at offset " + start.to_string())
  }
  let esc = self.peek()
  if is_builtin_class_letter(esc) {
    self.pos = self.pos + 1
    return Ok(CBuiltin(esc))
  }
  if esc == 0x70 || esc == 0x50 {
    let negated = esc == 0x50
    self.pos = self.pos + 1
    let name = match self.read_property(start) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    return Ok(CProp(name, negated))
  }
  match self.read_char_escape() {
    Some(code) => Ok(CSingle(code))
    None => Err("invalid escape at offset " + start.to_string())
  }
}

// ---------------------------------------------------------------------------
// 匹配
// ---------------------------------------------------------------------------

///|
priv struct Matcher {
  input : Array[Int]
  len : Int
  names : Map[String, Int]
  cap_start : Array[Int]
  cap_end : Array[Int]
}

///|
/// 编译好的正则，可以复用。
pub struct Regex {
  priv prog : Array[Node]
  priv names : Map[String, Int]
  priv group_count : Int
  priv source : String
}

///|
pub impl Show for Regex with fn output(self, logger) {
  logger.write_string("/" + self.source + "/")
}

///|
/// 编译。模式不合法时抛出 `RegexError`。
pub fn Regex::compile(pattern : String) -> Regex raise RegexError {
  let parsed = match parse_pattern(pattern) {
    Ok(p) => p
    Err(message) => raise SyntaxError(message)
  }
  { prog: parsed.0, names: parsed.1, group_count: parsed.2, source: pattern }
}

///|
/// 模式是否合法。等价于「编译能否成功」，但不抛异常。
pub fn Regex::is_valid(pattern : String) -> Bool {
  match parse_pattern(pattern) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// 捕获组数量。
pub fn Regex::group_count(self : Regex) -> Int {
  self.group_count
}

///|
/// 模式原文。
pub fn Regex::source(self : Regex) -> String {
  self.source
}

///|
/// 未锚定搜索：等价于 ECMAScript 的 `RegExp.prototype.test`。
/// 从每个可能的位置起尝试一次。
pub fn Regex::find(self : Regex, input : String) -> Bool {
  let codes = to_code_points(input)
  let m : Matcher = {
    input: codes,
    len: codes.length(),
    names: self.names,
    cap_start: [],
    cap_end: [],
  }
  m.prepare_captures(self.group_count)
  for i = 0; i <= codes.length(); i = i + 1 {
    m.clear_captures()
    if m.seq(self.prog, 0, i, fn(_p : Int) -> Bool { true }) {
      return true
    }
  }
  false
}

///|
/// 整串匹配（等价于给模式加上 `^(?:...)$`）。
pub fn Regex::matches_whole(self : Regex, input : String) -> Bool {
  let codes = to_code_points(input)
  let m : Matcher = {
    input: codes,
    len: codes.length(),
    names: self.names,
    cap_start: [],
    cap_end: [],
  }
  m.prepare_captures(self.group_count)
  m.clear_captures()
  m.seq(self.prog, 0, 0, fn(p : Int) -> Bool { p == codes.length() })
}

///|
/// 按需要扩容捕获表（下标 0 空置，组号从 1 开始）。
fn Matcher::prepare_captures(self : Matcher, groups : Int) -> Unit {
  while self.cap_start.length() <= groups {
    self.cap_start.push(-1)
    self.cap_end.push(-1)
  }
}

///|
/// 把捕获表清空（-1 表示未参与匹配）。
fn Matcher::clear_captures(self : Matcher) -> Unit {
  for i = 0; i < self.cap_start.length(); i = i + 1 {
    self.cap_start[i] = -1
    self.cap_end[i] = -1
  }
}

///|
/// 依次匹配 `prog[i..]`，全部匹配上后调用延续 `k`。
fn Matcher::seq(
  self : Matcher,
  prog : Array[Node],
  i : Int,
  pos : Int,
  k : (Int) -> Bool,
) -> Bool {
  if i >= prog.length() {
    return k(pos)
  }
  self.node_match(prog[i], pos, fn(p : Int) -> Bool { self.seq(prog, i + 1, p, k) })
}

///|
fn Matcher::node_match(
  self : Matcher,
  node : Node,
  pos : Int,
  k : (Int) -> Bool,
) -> Bool {
  match node {
    Lit(cp) =>
      if pos < self.len && self.input[pos] == cp {
        k(pos + 1)
      } else {
        false
      }
    AnyChar =>
      if pos < self.len && !is_line_terminator(self.input[pos]) {
        k(pos + 1)
      } else {
        false
      }
    Class(klass) =>
      if pos < self.len && class_matches(klass, self.input[pos]) {
        k(pos + 1)
      } else {
        false
      }
    Prop(name, negated) => {
      let matched = pos < self.len && prop_matches(name, self.input[pos])
      let accept = if negated {
        !matched
      } else {
        matched
      }
      if pos < self.len && accept {
        k(pos + 1)
      } else {
        false
      }
    }
    Seq(list) => self.seq(list, 0, pos, k)
    Alt(branches) => {
      for branch in branches {
        if self.node_match(branch, pos, k) {
          return true
        }
      }
      false
    }
    Repeat(inner, min, max, greedy) =>
      self.repeat_match(inner, min, max, greedy, 0, pos, k)
    Group(index, inner) => {
      let saved_start = self.cap_start[index]
      let saved_end = self.cap_end[index]
      let ok = self.node_match(
        inner,
        pos,
        fn(p : Int) -> Bool {
          // 捕获要记成「本次尝试的起止」供反向引用读取；延续失败时
          // 连同捕获一起回滚，否则分支回溯会带出上一次尝试的脏值。
          let prev_start = self.cap_start[index]
          let prev_end = self.cap_end[index]
          self.cap_start[index] = pos
          self.cap_end[index] = p
          if k(p) {
            true
          } else {
            self.cap_start[index] = prev_start
            self.cap_end[index] = prev_end
            false
          }
        },
      )
      if !ok {
        self.cap_start[index] = saved_start
        self.cap_end[index] = saved_end
      }
      ok
    }
    NonCapture(inner) => self.node_match(inner, pos, k)
    Look(inner, behind, negated) => {
      let hit = if behind {
        self.matches_ending_at(inner, pos)
      } else {
        self.node_match(inner, pos, fn(_p : Int) -> Bool { true })
      }
      if hit != negated {
        k(pos)
      } else {
        false
      }
    }
    Backref(target) => {
      let index = match target {
        ByIndex(i) => i
        ByName(name) =>
          match self.names.get(name) {
            Some(i) => i
            None => -1
          }
      }
      let start = if index >= 0 && index < self.cap_start.length() {
        self.cap_start[index]
      } else {
        -1
      }
      let stop = if index >= 0 && index < self.cap_end.length() {
        self.cap_end[index]
      } else {
        -1
      }
      if start < 0 {
        // 未参与匹配的组，反向引用按空串处理（ECMAScript 的规定）。
        k(pos)
      } else {
        let width = stop - start
        if pos + width > self.len {
          false
        } else {
          let mut same = true
          for j = 0; j < width; j = j + 1 {
            if self.input[pos + j] != self.input[start + j] {
              same = false
            }
          }
          if same {
            k(pos + width)
          } else {
            false
          }
        }
      }
    }
    StartAnchor =>
      if pos == 0 {
        k(pos)
      } else {
        false
      }
    EndAnchor =>
      if pos == self.len {
        k(pos)
      } else {
        false
      }
    WordBoundary(want) => {
      let before = pos > 0 && is_word_cp(self.input[pos - 1])
      let after = pos < self.len && is_word_cp(self.input[pos])
      if (before != after) == want {
        k(pos)
      } else {
        false
      }
    }
  }
}

///|
/// 子式是否存在「结束于位置 `end`」的匹配（后瞻用）。
///
/// 后瞻要倒着匹配，而回溯引擎天然是正向的；这里用「枚举所有起点 + 要求
/// 恰好停在 end」来实现。输入通常很短，代价可以接受。
fn Matcher::matches_ending_at(
  self : Matcher,
  node : Node,
  end : Int,
) -> Bool {
  for start = 0; start <= end; start = start + 1 {
    if self.node_match(node, start, fn(p : Int) -> Bool { p == end }) {
      return true
    }
  }
  false
}

///|
/// 量词匹配。
///
/// 贪婪时先尽量多吃再逐步退回，懒惰时反过来。两种情况都要防「空匹配死循环」：
/// 一次迭代若没有推进位置，继续迭代只会原地打转。
fn Matcher::repeat_match(
  self : Matcher,
  inner : Node,
  min : Int,
  max : Int,
  greedy : Bool,
  count : Int,
  pos : Int,
  k : (Int) -> Bool,
) -> Bool {
  let can_more = max < 0 || count < max
  if greedy {
    if can_more &&
      self.node_match(
        inner,
        pos,
        fn(p : Int) -> Bool {
          if p == pos {
            false
          } else {
            self.repeat_match(inner, min, max, greedy, count + 1, p, k)
          }
        },
      ) {
      return true
    }
    if count >= min {
      return k(pos)
    }
    false
  } else {
    if count >= min && k(pos) {
      return true
    }
    if can_more {
      return self.node_match(
        inner,
        pos,
        fn(p : Int) -> Bool {
          if p == pos {
            false
          } else {
            self.repeat_match(inner, min, max, greedy, count + 1, p, k)
          }
        },
      )
    }
    false
  }
}

///|
/// 字符类匹配。
fn class_matches(klass : CharClass, cp : Int) -> Bool {
  let mut hit = false
  for item in klass.items {
    match item {
      CSingle(c) =>
        if cp == c {
          hit = true
        }
      CRange(lo, hi) =>
        if cp >= lo && cp <= hi {
          hit = true
        }
      CBuiltin(letter) =>
        if builtin_matches(letter, cp) {
          hit = true
        }
      CProp(name, negated) => {
        let m = prop_matches(name, cp)
        if (if negated { !m } else { m }) {
          hit = true
        }
      }
    }
  }
  if klass.negated {
    !hit
  } else {
    hit
  }
}
