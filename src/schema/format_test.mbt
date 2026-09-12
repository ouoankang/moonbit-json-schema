// `format.mbt` 的单元测试。
//
// 这些用例不追求穷举（穷举交给一致性套件的 optional/format/*），而是钉住
// 每个格式「最容易手滑」的边界：闰秒与闰年、前导零、IPv6 压缩、duration
// 的跳级、email 的引号与 IPv6 字面量、URI 的 authority、uri-template 的
// 表达式语法。

///|
test "format: date 与闰年" {
  assert_true(format_ok("date", "2020-02-29"))
  assert_false(format_ok("date", "2021-02-29"))
  assert_false(format_ok("date", "2020-01-32"))
  assert_false(format_ok("date", "06/19/1963"))
  // 400 整除是闰年，100 整除不是（2100 平年）。
  assert_true(format_ok("date", "0400-02-29"))
  assert_false(format_ok("date", "0100-02-29"))
  assert_false(format_ok("date", "2100-02-29"))
}

///|
test "format: time 的闰秒与时区偏移" {
  assert_true(format_ok("time", "23:59:60Z"))
  assert_false(format_ok("time", "22:59:60Z"))
  // 闰秒换算到 UTC 后必须是 23:59。
  assert_true(format_ok("time", "01:29:60+01:30"))
  assert_true(format_ok("time", "15:59:60-08:00"))
  assert_false(format_ok("time", "23:59:60+01:00"))
  assert_true(format_ok("time", "23:20:50.52Z"))
  assert_false(format_ok("time", "24:00:00Z"))
}

///|
test "format: duration 的组件顺序与跳级" {
  assert_true(format_ok("duration", "P4DT12H30M5S"))
  assert_true(format_ok("duration", "P1Y2M3DT4H5M6S"))
  assert_false(format_ok("duration", "P2D1Y")) // 顺序错
  assert_false(format_ok("duration", "P1Y2D")) // Y 与 D 之间缺 M
  assert_true(format_ok("duration", "P1M2D"))
  assert_false(format_ok("duration", "PT1H2S")) // H 与 S 之间缺 M
  assert_false(format_ok("duration", "P1Y2W")) // 周不能与 Y 混用
  assert_false(format_ok("duration", "P1WT1H")) // 周不能与时间混用
}

///|
test "format: ipv4 前导零与越界" {
  assert_true(format_ok("ipv4", "192.168.0.1"))
  assert_true(format_ok("ipv4", "255.255.255.255"))
  assert_false(format_ok("ipv4", "192.168.0.256"))
  assert_false(format_ok("ipv4", "192.168.01.1")) // 前导零
  assert_false(format_ok("ipv4", "192.168.0.1.")) // 尾点
  assert_false(format_ok("ipv4", "127.0.0.0.1"))
}

///|
test "format: ipv6 压缩与嵌入式 IPv4" {
  assert_true(format_ok("ipv6", "::1"))
  assert_true(format_ok("ipv6", "::"))
  assert_true(format_ok("ipv6", "1:2:3:4:5:6:7:8"))
  assert_false(format_ok("ipv6", "1:2:3:4:5:6:7")) // 少一段
  assert_false(format_ok("ipv6", "1::d6::42")) // 两个 ::
  assert_true(format_ok("ipv6", "::ffff:192.168.0.1"))
  assert_false(format_ok("ipv6", "[::1]")) // 不能带方括号
}

///|
test "format: email 的引号与字面量" {
  assert_true(format_ok("email", "joe.bloggs@example.com"))
  assert_true(format_ok("email", "\"joe@bloggs\"@example.com")) // 引号内 @ 合法
  assert_true(format_ok("email", "joe.bloggs@[127.0.0.1]"))
  assert_true(format_ok("email", "joe.bloggs@[ipv6:::1]")) // 小写 ipv6
  assert_false(format_ok("email", "a@b@c.org"))
  assert_false(format_ok("email", "\"test\\©\"@iana.org")) // 非 ASCII 转义
  assert_false(format_ok("email", "joe bloggs@example.com")) // 空格
}

///|
test "format: uri 的 authority 校验" {
  assert_true(format_ok("uri", "http://foo.bar/?baz=qux#quux"))
  assert_true(format_ok("uri", "mailto:John.Doe@example.com"))
  assert_false(format_ok("uri", "http://example.com:abc/path")) // 非数字端口
  assert_false(format_ok("uri", "http:// shouldfail.com")) // 空格
  assert_false(format_ok("uri", "//foo.bar")) // 缺 scheme
  assert_false(format_ok("uri", "http:/[::1]")) // 路径段里的 []
}

///|
test "format: uuid 与 json-pointer" {
  assert_true(format_ok("uuid", "2eb8aa08-aa98-11ea-b4aa-73b441d16380"))
  assert_false(format_ok("uuid", "2eb8aa08-aa98-11ea-73b441d16380"))
  assert_true(format_ok("json-pointer", "/foo/bar~0/baz~1/%a"))
  assert_false(format_ok("json-pointer", "/foo/bar~"))
}

///|
test "format: uri-template 表达式语法" {
  assert_true(format_ok("uri-template", "http://example.com/{term:1}/{term}"))
  assert_true(format_ok("uri-template", "{+var}"))
  assert_true(format_ok("uri-template", "a😀b")) // 非 ASCII 字面量
  assert_false(format_ok("uri-template", "{}")) // 空表达式
  assert_false(format_ok("uri-template", "{a,,b}")) // 空 varspec
  assert_false(format_ok("uri-template", "{v:0}")) // 前缀不能是 0
  assert_false(format_ok("uri-template", "{a..b}")) // 双点
}

///|
test "format: 未识别的格式放行" {
  // 规范允许实现忽略它不认识的 format，所以 idn-hostname / iri 等返回 true。
  assert_true(format_ok("idn-hostname", "anything"))
  assert_true(format_ok("iri", "http://例え.テスト/"))
  assert_true(format_ok("no-such-format", "whatever"))
}
