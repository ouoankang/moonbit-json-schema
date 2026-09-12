// 跨文档 `$ref` 的单元测试。
//
// 这一层单独立一个文件，因为它和「单文档内 $ref」错的地方完全不同：
// 单文档内的错是 URI 解析或指针走错；跨文档的错大多是**注册表的键**错了——
// 明明解析出了一个绝对 URI，却因为键的形式对不上而查不到，于是静默退化。
//
// 静默退化是最危险的地方：查不到引用时引擎会把结果当「通过」，于是所有
// 期望「不通过」的用例全部误判为通过，而期望「通过」的用例照样通过。
// 也就是说**只看通过率是发现不了的**，必须正反两面都测。

///|
fn remote_doc(s : String) -> Json raise {
  @json.parse(s)
}

///|
test "跨文档 $ref：远程文档根" {
  let remote = remote_doc("{\"type\":\"integer\"}")
  let root = remote_doc("{\"$ref\":\"http://localhost:1234/draft2020-12/integer.json\"}")
  let s = Schema::of_with_documents(
    root,
    [("http://localhost:1234/draft2020-12/integer.json", remote)],
  )
  assert_true(s.validate(remote_doc("1")).length() == 0)
  assert_true(s.validate(remote_doc("\"a\"")).length() > 0)
}

///|
test "跨文档 $ref：带 fragment 的远程文档" {
  let remote = remote_doc(
    "{\"$id\":\"http://localhost:1234/draft2020-12/subSchemas.json\",\"$defs\":{\"integer\":{\"type\":\"integer\"}}}",
  )
  let root = remote_doc(
    "{\"$ref\":\"http://localhost:1234/draft2020-12/subSchemas.json#/$defs/integer\"}",
  )
  let s = Schema::of_with_documents(
    root,
    [("http://localhost:1234/draft2020-12/subSchemas.json", remote)],
  )
  assert_true(s.validate(remote_doc("1")).length() == 0)
  assert_true(s.validate(remote_doc("\"a\"")).length() > 0)
}

///|
test "跨文档 $ref：文档 $id 与取用 URI 不同的别名" {
  // 文件挂在 `different-id-ref-string.json` 下取用，但文档自己声明
  // `$id` 为 `real-id-ref-string.json`。两个 URI 都必须能查到。
  let remote = remote_doc(
    "{\"$id\":\"http://localhost:1234/draft2020-12/real-id-ref-string.json\",\"$defs\":{\"bar\":{\"type\":\"string\"}},\"$ref\":\"#/$defs/bar\"}",
  )
  let root = remote_doc(
    "{\"$ref\":\"http://localhost:1234/draft2020-12/different-id-ref-string.json\"}",
  )
  let s = Schema::of_with_documents(
    root,
    [
      (
        "http://localhost:1234/draft2020-12/different-id-ref-string.json",
        remote,
      ),
    ],
  )
  assert_true(s.validate(remote_doc("\"foo\"")).length() == 0)
  assert_true(s.validate(remote_doc("1")).length() > 0)
}

///|
test "跨文档 $ref：文档内的绝对 $id 子资源" {
  // `nested-absolute-ref-to-string.json` 用 `$ref` 指向文档内部某个
  // 带绝对 `$id` 的子 schema，而不是用指针。
  let remote = remote_doc(
    "{\"$defs\":{\"bar\":{\"$id\":\"http://localhost:1234/draft2020-12/the-nested-id.json\",\"type\":\"string\"}},\"$ref\":\"http://localhost:1234/draft2020-12/the-nested-id.json\"}",
  )
  let root = remote_doc(
    "{\"$ref\":\"http://localhost:1234/draft2020-12/nested-absolute-ref-to-string.json\"}",
  )
  let s = Schema::of_with_documents(
    root,
    [
      (
        "http://localhost:1234/draft2020-12/nested-absolute-ref-to-string.json",
        remote,
      ),
    ],
  )
  assert_true(s.validate(remote_doc("\"foo\"")).length() == 0)
  assert_true(s.validate(remote_doc("1")).length() > 0)
}

///|
test "跨文档 $ref：remote $ref 里再 $ref" {
  let inner = remote_doc(
    "{\"$id\":\"http://localhost:1234/draft2020-12/ref-and-defs.json\",\"$defs\":{\"inner\":{\"properties\":{\"bar\":{\"type\":\"string\"}}}},\"$ref\":\"#/$defs/inner\"}",
  )
  let root = remote_doc(
    "{\"$id\":\"http://localhost:1234/draft2020-12/schema-remote-ref-ref-defs1.json\",\"$ref\":\"ref-and-defs.json\"}",
  )
  let s = Schema::of_with_documents(
    root,
    [("http://localhost:1234/draft2020-12/ref-and-defs.json", inner)],
  )
  assert_true(s.validate(remote_doc("{\"bar\":\"a\"}")).length() == 0)
  assert_true(s.validate(remote_doc("{\"bar\":1}")).length() > 0)
}
