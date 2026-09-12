// Unicode 区间表的自检（**白盒**测试）。
//
// 这张表由 `scripts/gen-unicode-categories.mjs` 从 Node 的 `\p{...}`
// 规则生成，是本仓库里唯一「体积大又是机械产物」的部分。它一旦生成错，
// 表现会非常隐蔽（某个码点悄悄归错类别），所以这里直接把不变量钉住：
// 类别数、覆盖范围、区间无缝升序。
//
// 放在 `_wbtest.mbt` 而不是 `_test.mbt`：黑盒测试只能看到公开 API，
// 而 `unicode_runs` / `unicode_category_names` 是包内私有的实现细节。

///|
test "unicode category table sanity" {
  // 30 个一般类别：L(5) M(3) N(3) P(7) S(4) Z(3) C(5)
  if unicode_category_names.length() != 30 {
    fail(
      "expected 30 general categories, got " +
      unicode_category_names.length().to_string(),
    )
  }

  let first = unicode_runs[0]
  let last = unicode_runs[unicode_runs.length() - 1]
  if first.0 != 0x0 {
    fail("range table should start at U+0000")
  }
  if last.1 != 0x10FFFF {
    fail("range table should end at U+10FFFF")
  }

  // 区间必须无缝且升序——有洞就意味着某些码点会落到错误的类别上
  for i = 1; i < unicode_runs.length(); i = i + 1 {
    if unicode_runs[i].0 != unicode_runs[i - 1].1 + 1 {
      fail("range table has a gap at index " + i.to_string())
    }
  }
}

///|
test "category lookup agrees with the table extremes" {
  // 几个手挑的锚点：ASCII 字母、ASCII 空格、代理区、未指派区
  if category_of(0x41) != cat_Lu {
    fail("U+0041 should be Lu")
  }
  if category_of(0x61) != cat_Ll {
    fail("U+0061 should be Ll")
  }
  if category_of(0x20) != cat_Zs {
    fail("U+0020 should be Zs")
  }
  if category_of(0x0) != cat_Cc {
    fail("U+0000 should be Cc")
  }
  // 超过 BMP 的私有区末端，仍未指派
  if category_of(0x10FFFF) != cat_Cn {
    fail("U+10FFFF should be Cn")
  }
}
