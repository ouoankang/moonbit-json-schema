// 正则引擎的单元测试。
//
// 覆盖重点放在「和 ECMA-262 语义容易产生分歧」的地方：
// ASCII-only 的 `\d`/`\w`、按码点匹配、空匹配、回溯后的捕获回滚。

///|
test "literal and anchors" {
  let re = Regex::compile("^abc$")
  if !re.find("abc") {
    fail("abc should match ^abc$")
  }
  if re.find("xabc") {
    fail("xabc should not match ^abc$")
  }
  // 未锚定时是「搜索」而不是「整串匹配」
  let loose = Regex::compile("abc")
  if !loose.find("xxabcxx") {
    fail("unanchored search should look inside the string")
  }
}

///|
test "quantifiers" {
  if !Regex::compile("^a*$").find("") {
    fail("a* matches empty")
  }
  if !Regex::compile("^a*$").find("aaa") {
    fail("a* matches aaa")
  }
  if !Regex::compile("^a+$").find("aaa") {
    fail("a+ matches aaa")
  }
  if Regex::compile("^a+$").find("") {
    fail("a+ does not match empty")
  }
  if !Regex::compile("[0-9]{2,}").find("x123") {
    fail("{2,} should match three digits")
  }
  if Regex::compile("[0-9]{2,}").find("x1") {
    fail("{2,} should not match one digit")
  }
}

///|
test "dot does not match line terminators" {
  if !Regex::compile("f.o").find("foo") {
    fail("f.o matches foo")
  }
  if Regex::compile("^a.b$").find("a\nb") {
    fail(". must not match a line feed")
  }
}

///|
test "ascii-only shorthand classes" {
  // 关键分歧点：ECMA-262 的 \d 只认 ASCII，不能拿 Unicode 数字顶替
  if !Regex::compile("^\\d$").find("5") {
    fail("\\d matches an ASCII digit")
  }
  if Regex::compile("^\\d$").find("৪") {
    fail("\\d must not match a non-ASCII digit")
  }
  if !Regex::compile("^\\D$").find("৪") {
    fail("\\D matches a non-ASCII digit")
  }
  if !Regex::compile("^\\w$").find("_") {
    fail("\\w includes underscore")
  }
  if Regex::compile("^\\w$").find("π") {
    fail("\\w is ASCII-only")
  }
  if !Regex::compile("^\\s$").find(" ") {
    fail("\\s matches a space")
  }
  if !Regex::compile("^\\s$").find("\t") {
    fail("\\s matches a tab")
  }
}

///|
test "unicode property escapes" {
  // 官方套件里的 `\p{Letter}` / `\p{digit}`：这才是「按 Unicode 算」的入口
  if !Regex::compile("^\\p{Letter}+$").find("π") {
    fail("\\p{Letter} matches a Greek letter")
  }
  if Regex::compile("^\\p{Letter}+$").find("123") {
    fail("\\p{Letter} must not match digits")
  }
  if !Regex::compile("^\\p{Letter}+$").find("abcXYZ") {
    fail("\\p{Letter} matches ASCII letters")
  }
  if !Regex::compile("^\\p{digit}+$").find("৪২") {
    fail("\\p{digit} matches Bengali digits")
  }
  if Regex::compile("^\\p{digit}+$").find("-%#") {
    fail("\\p{digit} must not match punctuation")
  }
  if !Regex::compile("^\\P{Letter}$").find("7") {
    fail("\\P{Letter} is the negation")
  }
}

///|
test "code point matching for astral characters" {
  // 🐲 是一个码点（U+1F432），不是两个 UTF-16 码元；
  // 若按码元匹配，`^🐲*$` 会退化成一堆乱配。
  let re = Regex::compile("^🐲*$")
  if !re.find("") {
    fail("matches empty")
  }
  if !re.find("🐲") {
    fail("matches one dragon")
  }
  if !re.find("🐲🐲") {
    fail("matches two dragons")
  }
  if re.find("🐉") {
    fail("a different dragon must not match")
  }
  if re.find("DD") {
    fail("ASCII must not match")
  }
}

///|
test "alternation and groups" {
  if !Regex::compile("^(cat|dog)$").find("dog") {
    fail("alternation picks the second branch")
  }
  if Regex::compile("^(cat|dog)$").find("cow") {
    fail("alternation rejects")
  }
  // 非捕获组
  if !Regex::compile("^(?:ab)+$").find("abab") {
    fail("non-capturing group repeats")
  }
}

///|
test "backreferences" {
  if !Regex::compile("^(a+)\\1$").find("aaaa") {
    fail("backreference repeats the captured text")
  }
  if Regex::compile("^(a+)\\1$").find("aaa") {
    fail("aaa is not a doubled prefix")
  }
  // 命名组 + 命名反向引用
  if !Regex::compile("^(?<n>ab)\\k<n>$").find("abab") {
    fail("named backreference")
  }
}

///|
test "lookaround" {
  if !Regex::compile("foo(?=bar)").find("foobar") {
    fail("positive lookahead")
  }
  if Regex::compile("foo(?=bar)").find("foobaz") {
    fail("positive lookahead rejects")
  }
  if !Regex::compile("foo(?!bar)").find("foobaz") {
    fail("negative lookahead")
  }
  if !Regex::compile("(?<=a)b").find("ab") {
    fail("positive lookbehind")
  }
  if Regex::compile("(?<=a)b").find("cb") {
    fail("positive lookbehind rejects")
  }
}

///|
test "character classes" {
  if !Regex::compile("^[a-z]+$").find("hello") {
    fail("range in class")
  }
  if Regex::compile("^[a-z]+$").find("Hello") {
    fail("range is case sensitive")
  }
  if !Regex::compile("^[^a-z]+$").find("123") {
    fail("negated class")
  }
  if !Regex::compile("^[\\d]+$").find("123") {
    fail("shorthand inside class")
  }
  if !Regex::compile("^[\\p{Letter}]+$").find("π") {
    fail("property escape inside class")
  }
  // ECMAScript 特例：空类什么都不匹配，取反后什么都匹配
  if Regex::compile("^[]$").find("a") {
    fail("empty class matches nothing")
  }
  if !Regex::compile("^[^]$").find("a") {
    fail("negated empty class matches everything")
  }
}

///|
test "escapes" {
  if !Regex::compile("^\\t$").find("\t") {
    fail("\\t")
  }
  if !Regex::compile("^\\x41$").find("A") {
    fail("\\xHH")
  }
  if !Regex::compile("^\\u0041$").find("A") {
    fail("\\uHHHH")
  }
  if !Regex::compile("^\\u{1F432}$").find("🐲") {
    fail("\\u{...} code point escape")
  }
  if !Regex::compile("^\\cC$").find("\u{3}") {
    fail("\\cX control escape")
  }
  if !Regex::compile("^\\a$").find("a") {
    fail("identity escape \\a is just 'a'")
  }
}

///|
test "word boundaries" {
  if !Regex::compile("\\bfoo\\b").find("a foo b") {
    fail("\\b finds a whole word")
  }
  if Regex::compile("\\bfoo\\b").find("afoob") {
    fail("\\b must not match inside a word")
  }
  if !Regex::compile("\\Bfoo").find("afoob") {
    fail("\\B is the negation")
  }
}

///|
test "lazy quantifiers" {
  // 懒惰不等于「可以省略」：`+?` 仍然要求至少一个字符。
  if Regex::compile("^<.+?>$").find("<>") {
    fail("lazy + still requires at least one character")
  }
  if !Regex::compile("^<.+?>$").find("<a>") {
    fail("lazy + matches once there is one character")
  }
  // 懒惰量词必须愿意回溯：`a+?` 先只吃一个 a，被 `b` 挡住后再多吃。
  if !Regex::compile("^a+?b$").find("aab") {
    fail("lazy + backtracks to let b match")
  }
}

///|
test "syntax validation" {
  // 合法
  for pattern in [
    "(?<=a+)b", "(?<n>a)\\k<n>", "(?<name>x)", "([abc])+\\s+$", "[]", "[^]",
    "\\a", "\\cA", "a{2,3}", "a{2,}", "(?:x)",
  ] {
    if !Regex::is_valid(pattern) {
      fail("should be valid: " + pattern)
    }
  }
  // 非法
  for pattern in ["^(abc]", "(?#comment)a", "(?P<n>a)(?P=n)", "(?i)abc", "(?ims)abc", "a{3,1}", "\\p{NoSuchProperty}", "[z-a]"] {
    if Regex::is_valid(pattern) {
      fail("should be invalid: " + pattern)
    }
  }
}
