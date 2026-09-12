///|
/// 一条校验失败记录。
///
/// 三个位置字段互相独立、都很重要：
/// * `instance_path`：实例中出错的位置（JSON Pointer），例如 `/items/0/name`
/// * `schema_path`：约束来自哪个 schema 节点（JSON Pointer，相对根文档）
/// * `keyword`：具体是哪个关键字判定的
///
/// 保留 `schema_path` 是刻意的：只报「哪里错了」对使用者帮助有限，
/// 能指出「是哪条规则」才能直接定位到 schema 里要改的那一行。
pub(all) struct ValidationError {
  instance_path : String
  keyword : String
  schema_path : String
  message : String
} derive(Eq, @debug.Debug)

///|
pub impl Show for ValidationError with fn output(self, logger) {
  logger.write_string(self.instance_path)
  logger.write_string(": ")
  logger.write_string(self.keyword)
  logger.write_string(": ")
  logger.write_string(self.message)
  logger.write_string(" (schema at ")
  logger.write_string(self.schema_path)
  logger.write_string(")")
}
