// 校验引擎的单元测试。
//
// 这些用例刻意挑「实现容易写错、而且错了不会报错只会静默给错答案」的地方：
// 整数与浮点的区分、字符串按码点计数、`1` 与 `1.0` 的相等性、
// 浮点除法下的 multipleOf、$ref 与兄弟关键字的关系、以及 if 不能当断言。

///|
fn parse_json(s : String) -> Json raise {
  @json.parse(s)
}

///|
fn accepts(schema : String, instance : String) -> Bool raise {
  is_valid(parse_json(schema), parse_json(instance))
}

///|
test "type: integer 只认数值，1.0 也是整数" {
  assert_true(accepts("{\"type\":\"integer\"}", "1"))
  assert_true(accepts("{\"type\":\"integer\"}", "1.0"))
  assert_false(accepts("{\"type\":\"integer\"}", "1.5"))
  assert_false(accepts("{\"type\":\"integer\"}", "\"1\""))
  assert_true(accepts("{\"type\":\"number\"}", "1.5"))
  assert_false(accepts("{\"type\":\"number\"}", "true"))
}

///|
test "type: 联合类型" {
  let schema = "{\"type\":[\"string\",\"null\"]}"
  assert_true(accepts(schema, "\"a\""))
  assert_true(accepts(schema, "null"))
  assert_false(accepts(schema, "1"))
}

///|
test "maxLength/minLength 按 Unicode 码点计数，不是 UTF-16 码元" {
  // "🤣" 是一个码点、两个 UTF-16 码元。规范要求按码点算。
  assert_true(accepts("{\"maxLength\":1}", "\"\u{1F923}\""))
  assert_false(accepts("{\"maxLength\":1}", "\"ab\""))
  assert_true(accepts("{\"minLength\":2}", "\"\u{1F923}\u{1F923}\""))
  assert_false(accepts("{\"minLength\":2}", "\"\u{1F923}\""))
}

///|
test "multipleOf: 浮点除法不能直接判等" {
  // 0.0075 / 0.0001 在双精度下是 74.99999999999999
  assert_true(accepts("{\"multipleOf\":0.0001}", "0.0075"))
  assert_false(accepts("{\"multipleOf\":0.0001}", "0.00751"))
  assert_true(accepts("{\"multipleOf\":2}", "10"))
  assert_false(accepts("{\"multipleOf\":2}", "7"))
}

///|
test "uniqueItems: 1 与 1.0 视为重复" {
  assert_false(accepts("{\"uniqueItems\":true}", "[1,1.0]"))
  assert_true(accepts("{\"uniqueItems\":true}", "[1,2]"))
  assert_false(accepts("{\"uniqueItems\":true}", "[{\"a\":1},{\"a\":1}]"))
  // 键顺序不同但内容相同，仍算重复
  assert_false(accepts("{\"uniqueItems\":true}", "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1}]"))
}

///|
test "const / enum: 用 JSON 相等语义" {
  assert_true(accepts("{\"const\":1}", "1.0"))
  assert_false(accepts("{\"const\":1}", "2"))
  assert_true(accepts("{\"enum\":[1,2]}", "2.0"))
  assert_false(accepts("{\"enum\":[1,2]}", "3"))
}

///|
test "required / properties / additionalProperties" {
  let schema = "{\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"],\"additionalProperties\":false}"
  assert_true(accepts(schema, "{\"a\":\"x\"}"))
  assert_false(accepts(schema, "{}"), msg="missing required")
  assert_false(accepts(schema, "{\"a\":1}"), msg="wrong type")
  assert_false(accepts(schema, "{\"a\":\"x\",\"b\":1}"), msg="additional property")
  assert_true(accepts("{}", "{\"anything\":1}"), msg="空 schema 接受一切")
}

///|
test "patternProperties 与 additionalProperties 的覆盖关系" {
  let schema = "{\"patternProperties\":{\"^x-\":{\"type\":\"number\"}},\"additionalProperties\":{\"type\":\"string\"}}"
  assert_true(accepts(schema, "{\"x-1\":5,\"other\":\"s\"}"))
  assert_false(accepts(schema, "{\"x-1\":\"s\"}"), msg="pattern 命中要求 number")
  assert_false(accepts(schema, "{\"other\":5}"), msg="未命中要求 string")
}

///|
test "prefixItems 与 items 的分工（2020-12 语义）" {
  let good = "{\"prefixItems\":[{\"type\":\"integer\"}],\"items\":{\"type\":\"string\"}}"
  assert_true(accepts(good, "[1,\"a\",\"b\"]"))
  assert_false(accepts(good, "[\"a\"]"), msg="第一个元素必须是 integer")
  assert_false(accepts(good, "[1,2]"), msg="prefixItems 之后必须是 string")
  // 没有 prefixItems 时 items 作用于全部元素
  assert_false(accepts("{\"items\":{\"type\":\"string\"}}", "[1]"))
}

///|
test "contains / minContains / maxContains" {
  assert_true(accepts("{\"contains\":{\"const\":1}}", "[1,2]"))
  assert_false(accepts("{\"contains\":{\"const\":1}}", "[2,3]"))
  assert_true(accepts("{\"contains\":{\"const\":1},\"minContains\":2}", "[1,1]"))
  assert_false(accepts("{\"contains\":{\"const\":1},\"minContains\":2}", "[1,2]"))
  assert_false(accepts("{\"contains\":{\"const\":1},\"maxContains\":1}", "[1,1]"))
  // minContains: 0 使得 contains 恒真
  assert_true(accepts("{\"contains\":{\"const\":1},\"minContains\":0}", "[2]"))
}

///|
test "组合关键字" {
  assert_true(accepts("{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":3}]}", "5"))
  assert_false(accepts("{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":3}]}", "1"))
  assert_true(accepts("{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", "1"))
  assert_false(accepts("{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", "true"))
  assert_true(accepts("{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":3}]}", "1"))
  assert_false(accepts("{\"oneOf\":[{\"type\":\"integer\"},{\"minimum\":3}]}", "5"), msg="两个都满足")
  assert_true(accepts("{\"not\":{\"type\":\"string\"}}", "1"))
  assert_false(accepts("{\"not\":{\"type\":\"string\"}}", "\"a\""))
}

///|
test "if/then/else: if 本身不是断言" {
  let schema = "{\"if\":{\"type\":\"string\"},\"then\":{\"minLength\":3},\"else\":{\"type\":\"number\"}}"
  assert_true(accepts(schema, "\"abc\""))
  assert_false(accepts(schema, "\"ab\""), msg="走 then 分支失败")
  assert_true(accepts(schema, "1"))
  assert_false(accepts(schema, "true"), msg="走 else 分支失败")
  // if 命中但没有 then，不应因为 if 本身而失败
  assert_true(accepts("{\"if\":{\"type\":\"string\"}}", "\"a\""))
}

///|
test "$ref: 指针引用与 $defs" {
  let schema = "{\"$defs\":{\"pos\":{\"type\":\"integer\",\"minimum\":1}},\"properties\":{\"n\":{\"$ref\":\"#/$defs/pos\"}}}"
  assert_true(accepts(schema, "{\"n\":1}"))
  assert_false(accepts(schema, "{\"n\":0}"))
}

///|
test "$ref: 与兄弟关键字同时生效（2020-12）" {
  let schema = "{\"$defs\":{\"s\":{\"type\":\"string\"}},\"$ref\":\"#/$defs/s\",\"minLength\":3}"
  assert_true(accepts(schema, "\"abc\""))
  assert_false(accepts(schema, "\"ab\""), msg="兄弟关键字 minLength 必须生效")
  assert_false(accepts(schema, "1"), msg="$ref 目标必须生效")
}

///|
test "$ref: 锚点与嵌套 $id 作用域" {
  let schema = "{\"$defs\":{\"named\":{\"$anchor\":\"thing\",\"type\":\"boolean\"}},\"$ref\":\"#thing\"}"
  assert_true(accepts(schema, "true"))
  assert_false(accepts(schema, "1"))
  // 嵌套 $id 会成为新的 base，其内部的相对引用从新 base 解析
  let nested = "{\"$defs\":{\"sub\":{\"$id\":\"https://example.com/sub\",\"$defs\":{\"inner\":{\"type\":\"integer\"}},\"$ref\":\"#/$defs/inner\"}},\"$ref\":\"https://example.com/sub\"}"
  assert_true(accepts(nested, "3"))
  assert_false(accepts(nested, "\"x\""))
}

///|
test "$ref: 自引用不会死循环" {
  let schema = "{\"$defs\":{\"node\":{\"type\":\"object\",\"properties\":{\"next\":{\"$ref\":\"#/$defs/node\"}}}},\"$ref\":\"#/$defs/node\"}"
  assert_true(accepts(schema, "{\"next\":{\"next\":{}}}"))
  assert_false(accepts(schema, "{\"next\":1}"))
}

///|
test "布尔 schema" {
  assert_true(accepts("true", "1"))
  assert_false(accepts("false", "1"))
  assert_true(accepts("{\"properties\":{\"a\":true}}", "{\"a\":1}"))
  assert_false(accepts("{\"properties\":{\"a\":false}}", "{\"a\":1}"))
}

///|
test "注解关键字不参与断言" {
  // format 在 2020-12 中默认是注解，不应因格式不符而失败
  assert_true(accepts("{\"format\":\"email\"}", "\"not-an-email\""))
  assert_true(accepts("{\"title\":\"t\",\"description\":\"d\",\"default\":1}", "\"x\""))
  assert_true(accepts("{\"$comment\":\"hi\"}", "1"))
}

///|
test "错误信息带上位置与关键字" {
  let schema = parse_json(
    "{\"properties\":{\"n\":{\"minimum\":3}}}",
  )
  let instance = parse_json("{\"n\":1}")
  let errors = validate(schema, instance)
  assert_true(errors.length() == 1)
  assert_true(errors[0].instance_path == "/n")
  assert_true(errors[0].keyword == "minimum")
  assert_true(errors[0].schema_path == "/properties/n/minimum")
}
