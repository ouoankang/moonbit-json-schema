// JSON Schema draft 2020-12 的校验引擎。
//
// 求值模型遵循规范里的「断言 + 注解」两分法。本文件里这两件事是分开处理的：
//
//   * 断言（assertion）——type / minimum / required ... 决定通过与否；
//   * 注解（annotation）——「哪些属性、哪些元素已经被认领过」。
//
// 注解不是可有可无的装饰。`unevaluatedProperties` / `unevaluatedItems` 的
// 全部语义都建立在它之上：它们只看「同一层里已经认领过什么」，所以在求值
// 过程中必须把认领结果一层层带上来，见 `Outcome`。
//
// 纯注解关键字（title / description / default / examples / ...）
// 一概不参与判定。`format` 在 2020-12 里默认就是注解，这一点经常被实现
// 搞错——把 format 当断言会误判一批用例。唯一的例外是：当根文档的 `$schema`
// 指向的元 schema 显式声明了 `format-assertion` 词汇表时，`format` 才升级为
// 断言（见 `format_ok`，其值校验逻辑在 format.mbt）。
//
// `$ref` 在 2020-12 中不再是「替换式」的：它和兄弟关键字同时生效，
// 所以这里不做提前返回，而是把 $ref 的结果和本层的其它关键字合并判定。

///|
/// 已编译的 schema 文档，可以复用来校验多个实例。
pub struct Schema {
  ctx : Validator
}

///|
/// 编译一份 schema 文档。
pub fn Schema::of(root : Json) -> Schema {
  { ctx: Validator::build(root), }
}

///|
/// 编译一份 schema 文档，并登记一批外部文档供跨文档 `$ref` 使用。
///
/// `documents` 的每一项是 `(绝对 URI, 文档节点)`，内容通常来自本地文件或
/// 事先下载好的 schema 仓库。
pub fn Schema::of_with_documents(
  root : Json,
  documents : Array[(String, Json)],
) -> Schema {
  { ctx: Validator::build_with(root, documents), }
}

///|
/// 编译 schema 并强制启用 `format` 断言（无视元 schema 声明的词汇表）。
///
/// 供一致性测试台跑 `optional/format/*.json` 用：那些用例的 `$schema` 指向
/// 标准元 schema（声明的是 format-annotation），但官方套件把它们放在
/// `optional/format/` 下，本意就是「给愿意实现 format 断言的做法跑分」。
/// 普通用户应使用 `of` / `of_with_documents`，保持 2020-12 的默认注解语义。
pub fn Schema::of_with_documents_forcing_format(
  root : Json,
  documents : Array[(String, Json)],
) -> Schema {
  { ctx: Validator::build_with_forced_format(root, documents), }
}

///|
/// 用已编译的 schema 校验实例，返回全部错误（空数组表示通过）。
pub fn Schema::validate(
  self : Schema,
  instance : Json,
) -> Array[ValidationError] {
  self.ctx.reset()
  // 根文档的 base 传空串：它的 `$id` 相对空 base 解析（`eval_object` 会做
  // 这一步）。传 `root_base` 会让根本身带 `$id` 时把它解析两次。
  ignore(eval(self.ctx, self.ctx.root, "", "", instance, "", true))
  self.ctx.errors
}

///|
/// 便捷入口：编译并校验一次。
pub fn validate(root : Json, instance : Json) -> Array[ValidationError] {
  Schema::of(root).validate(instance)
}

///|
/// 便捷入口：只判断是否通过。
pub fn is_valid(root : Json, instance : Json) -> Bool {
  validate(root, instance).length() == 0
}

///|
/// 从 JSON 文本直接校验。
///
/// JSON 语法错误会以异常抛出，好让调用方把「输入不是合法 JSON」和
/// 「校验不通过」区分开——这两件事的处置方式完全不同。
pub fn validate_text(
  schema_text : String,
  instance_text : String,
) -> Array[ValidationError] raise {
  validate(@json.parse(schema_text), @json.parse(instance_text))
}

///|
/// 从 JSON 文本直接校验，只回答「是否通过」。
pub fn is_valid_text(
  schema_text : String,
  instance_text : String,
) -> Bool raise {
  validate_text(schema_text, instance_text).length() == 0
}

///|
/// 记录一条错误。`collect` 为假时表示当前处于「试探」上下文
/// （anyOf / oneOf / not / if / contains），不应该往错误列表里写东西。
///
/// `node_path` 是「承载该关键字的 schema 节点」的位置；这里统一把关键字名
/// 拼在末尾，于是 `schema_path` 精确指向关键字本身（`/properties/n/minimum`），
/// 而不是它所在的节点（`/properties/n`）。使用者据此可以直接跳到要改的那一行。
/// 布尔 schema 的 `false` 没有关键字名，此时不拼接。
fn report(
  v : Validator,
  collect : Bool,
  instance_path : String,
  keyword : String,
  node_path : String,
  message : String,
) -> Unit {
  if collect {
    let location = if keyword == "false" {
      node_path
    } else {
      node_path + "/" + @pointer.escape_token(keyword)
    }
    v.errors.push({ instance_path, keyword, schema_path: location, message, })
  }
}

///|
/// 一个 JSON 数值是否满足 `integer` 语义。
/// `1.0` 是整数（规范只看数值本身，不看到底写没写小数点）。
fn is_integer_value(n : Double) -> Bool {
  !n.is_nan() && !n.is_inf() && n == n.floor()
}

///|
/// `multipleOf` 判定。
///
/// 直接比较 `value / m` 是否为整数在浮点上会翻车：
/// `0.0075 / 0.0001` 得到 `74.99999999999999`。这里对小数部分做容差判断，
/// 容差按商的量级缩放，避免大数下退化成「什么都是倍数」。
fn is_multiple_of(value : Double, divisor : Double) -> Bool {
  if divisor == 0.0 || divisor.is_nan() || divisor.is_inf() {
    return false
  }
  let quotient = value / divisor
  if quotient.is_nan() {
    return false
  }
  if quotient.is_inf() {
    // 商溢出：`value` 与 `divisor` 都有限，但相除超出双精度范围
    // （`1e308 / 0.5`）。这时不能因为「商不是有限数」就判定不是倍数——
    // 取余不做除法，不会溢出，用它收尾。
    return value % divisor == 0.0
  }
  let floor_q = quotient.floor()
  let tail = quotient - floor_q
  let tolerance = 1.0e-9 *
    (if quotient.abs() > 1.0 { quotient.abs() } else { 1.0 })
  tail <= tolerance || 1.0 - tail <= tolerance
}

///|
fn type_matches(name : String, instance : Json) -> Bool {
  match name {
    "null" =>
      match instance {
        Null => true
        _ => false
      }
    "boolean" =>
      match instance {
        True => true
        False => true
        _ => false
      }
    "object" =>
      match instance {
        Object(_) => true
        _ => false
      }
    "array" =>
      match instance {
        Array(_) => true
        _ => false
      }
    "string" =>
      match instance {
        String(_) => true
        _ => false
      }
    "number" =>
      match instance {
        Number(_, ..) => true
        _ => false
      }
    "integer" =>
      match instance {
        Number(n, ..) => is_integer_value(n)
        _ => false
      }
    _ => false
  }
}

///|
/// 正则是否命中（未锚定，与 ECMA-262 的 `RegExp.prototype.test` 一致）。
fn regex_test(re : @regex.Regex, s : String) -> Bool {
  re.find(s)
}

///|
/// 按 pattern 匹配字符串。正则编译失败时返回 `false`。
fn pattern_ok(v : Validator, pattern : String, s : String) -> Bool {
  match v.regex_for(pattern) {
    Some(re) => regex_test(re, s)
    None => false
  }
}

///|
/// 数组是否含重复元素（用 JSON 相等语义：`1` 与 `1.0` 相等）。
fn has_duplicate(items : Array[Json]) -> Bool {
  for i = 0; i < items.length(); i = i + 1 {
    for j = i + 1; j < items.length(); j = j + 1 {
      if items[i] == items[j] {
        return true
      }
    }
  }
  false
}

// ---------------------------------------------------------------------------
// 注解（annotation）
// ---------------------------------------------------------------------------

///|
/// 一次子 schema 求值的完整结果：断言结果 + 它产生的注解。
///
/// 「认领」的两种形态分开记，是为了贴合实际的匹配方式：
///
///   * `prefix_items`——`prefixItems` / `items` 认领的是**从 0 开始的一段**，
///     记长度就够，不必逐个下标塞进集合；
///   * `index_items`——`contains` 认领的是**零散下标**（第 1、第 5 个满足），
///     只能老老实实记集合。
///
/// 注解只会沿着求值路径向上传，不会横向流到堂兄弟（cousin）那里——这正是
/// 规范要求的行为，也是「unevaluatedItems 看不见隔壁 allOf 分支」的原因。
priv struct Outcome {
  mut ok : Bool
  /// 已被认领的属性名。
  props : Map[String, Bool]
  /// 已被认领的元素下标（`contains` 造成的散点）。
  index_items : Map[Int, Bool]
  /// 从下标 0 起连续被认领的元素个数。
  mut prefix_items : Int
  /// 是否全部元素都已被认领（出现 `items` 时成立）。
  mut all_items : Bool
}

///|
fn outcome_ok() -> Outcome {
  {
    ok: true,
    props: Map([]),
    index_items: Map([]),
    prefix_items: 0,
    all_items: false,
  }
}

///|
fn outcome_fail() -> Outcome {
  {
    ok: false,
    props: Map([]),
    index_items: Map([]),
    prefix_items: 0,
    all_items: false,
  }
}

///|
/// 把 `other` 的注解并进 `self`。调用前应确认 `other` 是成功的——
/// 失败的那次求值不该留下任何认领记录。
fn Outcome::absorb(self : Outcome, other : Outcome) -> Unit {
  for key, _ in other.props {
    self.props.set(key, true)
  }
  for key, _ in other.index_items {
    self.index_items.set(key, true)
  }
  if other.prefix_items > self.prefix_items {
    self.prefix_items = other.prefix_items
  }
  if other.all_items {
    self.all_items = true
  }
}

///|
/// 合并一个「必须通过」的子结果：成功了就把注解收下，失败了就把失败传上来。
fn Outcome::merge(self : Outcome, other : Outcome) -> Unit {
  if other.ok {
    self.absorb(other)
  } else {
    self.ok = false
  }
}

///|
/// 合并一个**在更深实例位置上**求值的子结果：只取通过与否，注解一律丢弃。
///
/// 这个区分是 `unevaluated*` 正确性的关键。注解是「在某个实例位置上，
/// 哪些属性/元素已经被认领」的记录，它天然带位置。`properties` 对
/// `{"foo":{"properties":{"bar":...}}}` 求值子 schema 时，子结果里那句
/// 「bar 已认领」说的是 `/foo` 这个位置的 bar，而不是根位置的 bar。
///
/// 如果把它当成普通 `merge` 收下来，根位置就会凭空多出一条「bar 已认领」，
/// 于是 `{"foo":{"bar":..},"bar":..}` 会错误地通过 `unevaluatedProperties: false`。
/// 测试套件里 "Evaluated properties collection needs to consider instance
/// location" 那一组就是专门抓这个的。
fn Outcome::require(self : Outcome, other : Outcome) -> Unit {
  if !other.ok {
    self.ok = false
  }
}

///|
/// 标记某个属性已被认领。
fn Outcome::claim_prop(self : Outcome, name : String) -> Unit {
  self.props.set(name, true)
}

///|
/// 标记从 0 起连续 `n` 个元素已被认领。
fn Outcome::claim_prefix(self : Outcome, n : Int) -> Unit {
  if n > self.prefix_items {
    self.prefix_items = n
  }
}

///|
/// 标记某个散点下标已被认领。
fn Outcome::claim_index(self : Outcome, i : Int) -> Unit {
  self.index_items.set(i, true)
}

///|
/// 下标 `i` 是否已被认领。
fn Outcome::is_claimed(self : Outcome, i : Int) -> Bool {
  if self.all_items {
    return true
  }
  if i < self.prefix_items {
    return true
  }
  match self.index_items.get(i) {
    Some(_) => true
    None => false
  }
}

// ---------------------------------------------------------------------------
// 求值
// ---------------------------------------------------------------------------

///|
/// 求值入口。负责深度控制与自引用保护。
fn eval(
  v : Validator,
  node : Json,
  base : String,
  schema_path : String,
  instance : Json,
  instance_path : String,
  collect : Bool,
) -> Outcome {
  if v.depth >= MAX_DEPTH {
    return outcome_ok()
  }
  v.depth = v.depth + 1
  // 环的判据是「同一个 schema 节点 × 同一个实例位置」，所以键必须能唯一定位
  // 一个 schema 节点。只用 `schema_path` 是不够的：它是**相对根文档**的路径，
  // 两份不同文档的根都是 `""`，于是「远程文档根」的 `$ref` 会被误判成自引用。
  // 加上 `base` 才能把两份文档的根区分开。
  let key = base + "\u{1}" + schema_path + "\u{1}" + instance_path
  let result = match v.active.get(key) {
    // 同一 (schema, 实例位置) 正在求值中，说明遇到了自引用环。
    // 直接按通过处理以打断循环——规范并未要求实现必须给出错误。
    Some(_) => outcome_ok()
    None => {
      v.active.set(key, true)
      let r = eval_node(
        v, node, base, schema_path, instance, instance_path, collect,
      )
      v.active.remove(key)
      r
    }
  }
  v.depth = v.depth - 1
  result
}

///|
fn eval_node(
  v : Validator,
  node : Json,
  base : String,
  schema_path : String,
  instance : Json,
  instance_path : String,
  collect : Bool,
) -> Outcome {
  match node {
    True => outcome_ok()
    False => {
      report(
        v, collect, instance_path, "false", schema_path, "boolean schema `false` rejects every instance",
      )
      outcome_fail()
    }
    Object(obj) =>
      eval_object(v, obj, base, schema_path, instance, instance_path, collect)
    // 非 object / 非 bool 的 schema 节点是非法 schema，这里选择忽略。
    _ => outcome_ok()
  }
}

///|
/// 解析并应用一个引用型关键字。
///
/// `dynamic` 为真时走 `$dynamicRef` 的解析路径。无论哪种，进入目标资源时都要
/// 把它压入动态作用域，并在返回后弹回——这样 `$dynamicRef` 才只看得到
/// 「当前正在求值的这条链」。
fn apply_ref(
  v : Validator,
  base : String,
  reference : String,
  keyword : String,
  schema_path : String,
  instance : Json,
  instance_path : String,
  collect : Bool,
  dynamic : Bool,
) -> Outcome {
  let resolved = if dynamic {
    v.lookup_dynamic(base, reference)
  } else {
    v.lookup(base, reference)
  }
  match resolved {
    Hit(target) => {
      // 动态作用域压的是**资源** URI，所以这里用 `uri` 而不是 `base`。
      let (scope_uri, _) = split_fragment(target.uri)
      let pushed = v.enter_resource(scope_uri)
      let r = eval(
        v,
        target.node,
        target.base,
        target.path,
        instance,
        instance_path,
        collect,
      )
      if pushed {
        ignore(v.dynamic_scope.pop())
      }
      r
    }
    External(absolute) => {
      report(
        v,
        collect,
        instance_path,
        keyword,
        schema_path,
        "cannot resolve external reference `" +
        absolute +
        "`; register the document via `Schema::of_with_documents`",
      )
      // 无法求值的引用不作为失败处理，否则会把「未实现」误报成「校验不通过」。
      outcome_ok()
    }
    Missing(absolute) => {
      report(
        v,
        collect,
        instance_path,
        keyword,
        schema_path,
        "unresolvable reference `" + absolute + "`",
      )
      outcome_fail()
    }
  }
}

///|
/// validation 词汇表的关键字。元 schema 没声明这个词汇表时，这些关键字
/// 一律当未知关键字忽略。
let validation_keywords : Array[String] = [
  "type", "enum", "const", "multipleOf", "maximum", "exclusiveMaximum", "minimum",
  "exclusiveMinimum", "maxLength", "minLength", "pattern", "maxItems", "minItems",
  "uniqueItems", "maxContains", "minContains", "maxProperties", "minProperties",
  "required", "dependentRequired",
]

///|
/// applicator 词汇表的关键字。
let applicator_keywords : Array[String] = [
  "prefixItems", "items", "contains", "additionalProperties", "properties", "patternProperties",
  "dependentSchemas", "propertyNames", "if", "then", "else", "allOf", "anyOf", "oneOf",
  "not",
  // 2019-09 的旧关键字，2020-12 为兼容而保留（见 `eval_object_body` 里的处理）。
   "dependencies",
]

///|
/// unevaluated 词汇表的关键字。
let unevaluated_keywords : Array[String] = [
  "unevaluatedItems", "unevaluatedProperties",
]

///|
/// 复制一份 `obj`，去掉 `keys` 里列出的键。用于词汇表裁剪。
///
/// 只在真的需要裁剪时才调用（`$vocabulary` 显式关掉某个词汇表），
/// 常规路径上不会产生这次拷贝。
fn without_keywords(
  obj : Map[String, Json],
  keys : Array[String],
) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for name, value in obj {
    let mut drop = false
    for key in keys {
      if name == key {
        drop = true
      }
    }
    if !drop {
      out.set(name, value)
    }
  }
  out
}

///|
/// 求值一个 object 形式的 schema 节点。
///
/// 这里是两件横切事情的落点，所以它在 `eval_object_body` 外面又包了一层：
///
///   * **词汇表裁剪**——`$vocabulary` 没声明的词汇表，其关键字要按未知关键字
///     忽略，等价于「这些键不存在」。与其在 1300 行里给每个关键字都套一个
///     条件，不如在入口处把键去掉。
///   * **动态作用域**——本节点若用 `$id` 开了新资源，求值期间它就在动态作用域
///     里，`$dynamicRef` 要能看到它（也必须看不到已经离开的那些）。
///     只在 `$ref` 处压栈是不够的：`if` / `then` / `$defs` 里直接用 `$id`
///     开出来的资源是**走**进去的，不经过任何 `$ref`。
fn eval_object(
  v : Validator,
  obj : Map[String, Json],
  base : String,
  schema_path : String,
  instance : Json,
  instance_path : String,
  collect : Bool,
) -> Outcome {
  let mut effective = obj
  if !v.vocab_validation {
    effective = without_keywords(effective, validation_keywords)
  }
  if !v.vocab_applicator {
    effective = without_keywords(effective, applicator_keywords)
  }
  if !v.vocab_unevaluated {
    effective = without_keywords(effective, unevaluated_keywords)
  }
  // 有 `$id` 才意味着「进入了一个新的 schema 资源」；没 `$id` 的节点只是
  // 上一层资源里的一段，压栈会污染动态作用域。
  let pushed = match obj_get_str(obj, "$id") {
    Some(id) => v.enter_resource(resolve(base, id))
    None => false
  }
  let r = eval_object_body(
    v, effective, base, schema_path, instance, instance_path, collect,
  )
  if pushed {
    ignore(v.dynamic_scope.pop())
  }
  r
}

///|
fn eval_object_body(
  v : Validator,
  obj : Map[String, Json],
  base : String,
  schema_path : String,
  instance : Json,
  instance_path : String,
  collect : Bool,
) -> Outcome {
  // 本节点自身的 base：`$id` 先于 `$ref` 生效（规范明确要求）。
  let node_base = match obj_get_str(obj, "$id") {
    Some(id) => resolve(base, id)
    None => base
  }
  let acc = outcome_ok()
  // =========================================================================
  // 1. 原地应用器（in-place applicators）
  //
  // 它们的共同点是「作用在同一个实例位置上」，因此产生的注解和本层关键字
  // 产生的注解是同一层的东西，`unevaluated*` 能看到它们。
  // =========================================================================
  match obj_get_str(obj, "$ref") {
    Some(reference) =>
      acc.merge(
        apply_ref(
          v, node_base, reference, "$ref", schema_path, instance, instance_path,
          collect, false,
        ),
      )
    None => ()
  }
  match obj_get_str(obj, "$dynamicRef") {
    Some(reference) =>
      acc.merge(
        apply_ref(
          v, node_base, reference, "$dynamicRef", schema_path, instance, instance_path,
          collect, true,
        ),
      )
    None => ()
  }
  match obj_get_arr(obj, "allOf") {
    Some(list) =>
      for i = 0; i < list.length(); i = i + 1 {
        acc.merge(
          eval(
            v,
            list[i],
            node_base,
            schema_path + "/allOf/" + i.to_string(),
            instance,
            instance_path,
            collect,
          ),
        )
      }
    None => ()
  }
  match obj_get_arr(obj, "anyOf") {
    Some(list) => {
      let mut hit = false
      for i = 0; i < list.length(); i = i + 1 {
        let branch = eval(
          v,
          list[i],
          node_base,
          schema_path + "/anyOf/" + i.to_string(),
          instance,
          instance_path,
          false,
        )
        if branch.ok {
          // 通过的每一个分支都要收下注解：anyOf 允许多个分支同时成立，
          // 它们认领的东西都是真的。
          hit = true
          acc.absorb(branch)
        }
      }
      if !hit {
        report(
          v, collect, instance_path, "anyOf", schema_path, "instance does not match any of the subschemas",
        )
        acc.ok = false
      }
    }
    None => ()
  }
  match obj_get_arr(obj, "oneOf") {
    Some(list) => {
      let mut matches = 0
      let mut winner = outcome_ok()
      for i = 0; i < list.length(); i = i + 1 {
        let branch = eval(
          v,
          list[i],
          node_base,
          schema_path + "/oneOf/" + i.to_string(),
          instance,
          instance_path,
          false,
        )
        if branch.ok {
          matches = matches + 1
          winner = branch
        }
      }
      if matches == 1 {
        acc.absorb(winner)
      } else {
        report(
          v, collect, instance_path, "oneOf", schema_path, "instance must match exactly one subschema",
        )
        acc.ok = false
      }
    }
    None => ()
  }
  match obj.get("not") {
    // `not` 不产生注解：它成立恰恰意味着子 schema 失败了，
    // 而失败的求值不留下认领记录。
    Some(sub) =>
      if eval(
          v,
          sub,
          node_base,
          schema_path + "/not",
          instance,
          instance_path,
          false,
        ).ok {
        report(
          v, collect, instance_path, "not", schema_path, "instance must not match the `not` subschema",
        )
        acc.ok = false
      }
    None => ()
  }
  // if 只用于选择分支，本身不构成断言；它成立时的注解要收下
  // （用例："unevaluatedItems can see annotations from if without then and else"）。
  match obj.get("if") {
    Some(condition) => {
      let matched = eval(
        v,
        condition,
        node_base,
        schema_path + "/if",
        instance,
        instance_path,
        false,
      )
      if matched.ok {
        acc.absorb(matched)
      }
      let branch = if matched.ok { "then" } else { "else" }
      match obj.get(branch) {
        Some(sub) =>
          acc.merge(
            eval(
              v,
              sub,
              node_base,
              schema_path + "/" + branch,
              instance,
              instance_path,
              collect,
            ),
          )
        None => ()
      }
    }
    None => ()
  }
  // =========================================================================
  // 2. 通用断言
  // =========================================================================
  match obj.get("type") {
    Some(String(name)) =>
      if !type_matches(name, instance) {
        report(
          v,
          collect,
          instance_path,
          "type",
          schema_path,
          "expected type `" + name + "`",
        )
        acc.ok = false
      }
    Some(Array(names)) => {
      let mut hit = false
      for candidate in names {
        match candidate {
          String(name) => if type_matches(name, instance) { hit = true }
          _ => ()
        }
      }
      if !hit {
        report(
          v, collect, instance_path, "type", schema_path, "instance type does not match any of the listed types",
        )
        acc.ok = false
      }
    }
    _ => ()
  }
  match obj_get_arr(obj, "enum") {
    Some(choices) => {
      let mut hit = false
      for choice in choices {
        if choice == instance {
          hit = true
        }
      }
      if !hit {
        report(
          v, collect, instance_path, "enum", schema_path, "instance is not one of the enumerated values",
        )
        acc.ok = false
      }
    }
    None => ()
  }
  match obj.get("const") {
    Some(expected) =>
      if !(expected == instance) {
        report(
          v, collect, instance_path, "const", schema_path, "instance does not equal the const value",
        )
        acc.ok = false
      }
    None => ()
  }
  // =========================================================================
  // 3. 数值断言
  // =========================================================================
  match instance {
    Number(n, ..) => {
      match obj_get_num(obj, "multipleOf") {
        Some(m) =>
          if !is_multiple_of(n, m) {
            report(
              v, collect, instance_path, "multipleOf", schema_path, "value is not a multiple of the divisor",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "maximum") {
        Some(m) =>
          if !(n <= m) {
            report(
              v, collect, instance_path, "maximum", schema_path, "value exceeds the maximum",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "exclusiveMaximum") {
        Some(m) =>
          if !(n < m) {
            report(
              v, collect, instance_path, "exclusiveMaximum", schema_path, "value must be strictly less than exclusiveMaximum",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "minimum") {
        Some(m) =>
          if !(n >= m) {
            report(
              v, collect, instance_path, "minimum", schema_path, "value is below the minimum",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "exclusiveMinimum") {
        Some(m) =>
          if !(n > m) {
            report(
              v, collect, instance_path, "exclusiveMinimum", schema_path, "value must be strictly greater than exclusiveMinimum",
            )
            acc.ok = false
          }
        None => ()
      }
    }
    _ => ()
  }
  // =========================================================================
  // 4. 字符串断言
  // =========================================================================
  match instance {
    String(s) => {
      // 长度按 Unicode 码点算，不是 UTF-16 码元——`char_length` 才是对的。
      let length = s.char_length().to_double()
      match obj_get_num(obj, "maxLength") {
        Some(m) =>
          if length > m {
            report(
              v, collect, instance_path, "maxLength", schema_path, "string is longer than maxLength (counted in Unicode code points)",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "minLength") {
        Some(m) =>
          if length < m {
            report(
              v, collect, instance_path, "minLength", schema_path, "string is shorter than minLength (counted in Unicode code points)",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_str(obj, "pattern") {
        Some(pattern) =>
          if !pattern_ok(v, pattern, s) {
            report(
              v,
              collect,
              instance_path,
              "pattern",
              schema_path,
              "string does not match pattern `" + pattern + "`",
            )
            acc.ok = false
          }
        None => ()
      }
      // `format` 只在 format-assertion 词汇表启用时作为断言；默认是注解。
      // `force_format` 让测试台跑 optional/format 时强制断言。
      if v.vocab_format_assertion || v.force_format {
        match obj_get_str(obj, "format") {
          Some(fmt) =>
            if !format_ok(fmt, s) {
              report(
                v,
                collect,
                instance_path,
                "format",
                schema_path,
                "string does not match format `" + fmt + "`",
              )
              acc.ok = false
            }
          None => ()
        }
      }
    }
    _ => ()
  }
  // =========================================================================
  // 5. 数组断言与子应用器
  // =========================================================================
  match instance {
    Array(items) => {
      match obj_get_num(obj, "maxItems") {
        Some(m) =>
          if items.length().to_double() > m {
            report(
              v, collect, instance_path, "maxItems", schema_path, "array has more items than maxItems",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "minItems") {
        Some(m) =>
          if items.length().to_double() < m {
            report(
              v, collect, instance_path, "minItems", schema_path, "array has fewer items than minItems",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj.get("uniqueItems") {
        Some(True) =>
          if has_duplicate(items) {
            report(
              v, collect, instance_path, "uniqueItems", schema_path, "array items are not unique",
            )
            acc.ok = false
          }
        _ => ()
      }
      // prefixItems：逐位绑定，只覆盖实例已有的下标。
      match obj_get_arr(obj, "prefixItems") {
        Some(prefix) => {
          let bound = if prefix.length() < items.length() {
            prefix.length()
          } else {
            items.length()
          }
          for i = 0; i < bound; i = i + 1 {
            let child_instance = instance_path + "/" + i.to_string()
            // 元素在新位置上求值：子 schema 里那些「认领」说的是元素内部，
            // 不是本层数组。收下它会让 `[["foo","bar"],"bar"]` 对本层的
            // `unevaluatedItems: false` 错误地通过。
            acc.require(
              eval(
                v,
                prefix[i],
                node_base,
                schema_path + "/prefixItems/" + i.to_string(),
                items[i],
                child_instance,
                collect,
              ),
            )
          }
          // 认领「从 0 起连续 prefixItems.length() 个」：声明长度超过实例长度时
          // 多认领的部分不存在，没有副作用。
          acc.claim_prefix(prefix.length())
        }
        None => ()
      }
      // items：2020-12 中作用于 prefixItems 之后的剩余元素；一旦出现，
      // 就等价于「所有元素都已被认领」。
      match obj.get("items") {
        Some(items_schema) => {
          let start = match obj_get_arr(obj, "prefixItems") {
            Some(prefix) => prefix.length()
            None => 0
          }
          for i = start; i < items.length(); i = i + 1 {
            let child_instance = instance_path + "/" + i.to_string()
            acc.require(
              eval(
                v,
                items_schema,
                node_base,
                schema_path + "/items",
                items[i],
                child_instance,
                collect,
              ),
            )
          }
          acc.all_items = true
        }
        None => ()
      }
      // contains / minContains / maxContains
      match obj.get("contains") {
        Some(contains_schema) => {
          let mut count = 0
          let matched_indices : Array[Int] = []
          for i = 0; i < items.length(); i = i + 1 {
            let child_instance = instance_path + "/" + i.to_string()
            if eval(
                v,
                contains_schema,
                node_base,
                schema_path + "/contains",
                items[i],
                child_instance,
                false,
              ).ok {
              count = count + 1
              matched_indices.push(i)
            }
          }
          let min_contains = match obj_get_num(obj, "minContains") {
            Some(m) => m
            None => 1.0
          }
          let contains_ok = if min_contains > 0.0 {
            count.to_double() >= min_contains
          } else {
            true
          }
          let within_max = match obj_get_num(obj, "maxContains") {
            Some(mx) => count.to_double() <= mx
            None => true
          }
          if !contains_ok {
            report(
              v, collect, instance_path, "contains", schema_path, "not enough array items match `contains`",
            )
            acc.ok = false
          }
          if !within_max {
            report(
              v, collect, instance_path, "maxContains", schema_path, "too many array items match `contains`",
            )
            acc.ok = false
          }
          // `contains` 成功时一定产生注解（匹配到的下标列表，可能为空），
          // 与 `minContains` 的取值无关。`minContains: 0` 只是说「可以一个都
          // 没匹配上」，不是说「不产生注解」——把它排除掉会让
          // `{"contains":…,"minContains":0,"unevaluatedItems":false}` 对
          // `["foo","bar"]` 误判为不通过。
          if contains_ok && within_max {
            for i in matched_indices {
              acc.claim_index(i)
            }
          }
        }
        None => ()
      }
    }
    _ => ()
  }
  // =========================================================================
  // 6. 对象断言与子应用器
  // =========================================================================
  match instance {
    Object(members) => {
      match obj_get_num(obj, "maxProperties") {
        Some(m) =>
          if members.length().to_double() > m {
            report(
              v, collect, instance_path, "maxProperties", schema_path, "object has more properties than maxProperties",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_num(obj, "minProperties") {
        Some(m) =>
          if members.length().to_double() < m {
            report(
              v, collect, instance_path, "minProperties", schema_path, "object has fewer properties than minProperties",
            )
            acc.ok = false
          }
        None => ()
      }
      match obj_get_arr(obj, "required") {
        Some(names) =>
          for candidate in names {
            match candidate {
              String(name) =>
                match members.get(name) {
                  Some(_) => ()
                  None => {
                    report(
                      v,
                      collect,
                      instance_path,
                      "required",
                      schema_path,
                      "missing required property `" + name + "`",
                    )
                    acc.ok = false
                  }
                }
              _ => ()
            }
          }
        None => ()
      }
      // 被 properties / patternProperties 认领的键，不再进入 additionalProperties。
      let covered : Map[String, Bool] = Map([])
      match obj_get_obj(obj, "properties") {
        Some(properties) =>
          for name, sub in properties {
            match members.get(name) {
              Some(value) => {
                covered.set(name, true)
                // 子 schema 在新位置上求值：只取通过与否（见 `Outcome::require`）。
                acc.require(
                  eval(
                    v,
                    sub,
                    node_base,
                    schema_path + "/properties/" + @pointer.escape_token(name),
                    value,
                    instance_path + "/" + @pointer.escape_token(name),
                    collect,
                  ),
                )
                acc.claim_prop(name)
              }
              None => ()
            }
          }
        None => ()
      }
      match obj_get_obj(obj, "patternProperties") {
        Some(patterns) =>
          for pattern, sub in patterns {
            for name, value in members {
              if pattern_ok(v, pattern, name) {
                covered.set(name, true)
                acc.require(
                  eval(
                    v,
                    sub,
                    node_base,
                    schema_path +
                    "/patternProperties/" +
                    @pointer.escape_token(pattern),
                    value,
                    instance_path + "/" + @pointer.escape_token(name),
                    collect,
                  ),
                )
                acc.claim_prop(name)
              }
            }
          }
        None => ()
      }
      match obj.get("additionalProperties") {
        Some(additional) =>
          for name, value in members {
            match covered.get(name) {
              Some(_) => ()
              None => {
                acc.require(
                  eval(
                    v,
                    additional,
                    node_base,
                    schema_path + "/additionalProperties",
                    value,
                    instance_path + "/" + @pointer.escape_token(name),
                    collect,
                  ),
                )
                acc.claim_prop(name)
              }
            }
          }
        None => ()
      }
      // propertyNames 作用在「名字」上，不认领属性值——规范里
      // unevaluatedProperties 的认领来源只有 properties / patternProperties /
      // additionalProperties 与原地应用器，不含 propertyNames。
      match obj.get("propertyNames") {
        Some(property_names) =>
          for name, _ in members {
            // 实例是「属性名」这个合成位置，同样不能把子注解收上来。
            acc.require(
              eval(
                v,
                property_names,
                node_base,
                schema_path + "/propertyNames",
                Json::string(name),
                instance_path + "/" + @pointer.escape_token(name),
                collect,
              ),
            )
          }
        None => ()
      }
      match obj_get_obj(obj, "dependentRequired") {
        Some(dependencies) =>
          for name, required_here in dependencies {
            match members.get(name) {
              Some(_) =>
                match required_here {
                  Array(names) =>
                    for candidate in names {
                      match candidate {
                        String(dep) =>
                          match members.get(dep) {
                            Some(_) => ()
                            None => {
                              report(
                                v,
                                collect,
                                instance_path,
                                "dependentRequired",
                                schema_path,
                                "property `" +
                                name +
                                "` requires `" +
                                dep +
                                "` to be present",
                              )
                              acc.ok = false
                            }
                          }
                        _ => ()
                      }
                    }
                  _ => ()
                }
              None => ()
            }
          }
        None => ()
      }
      // dependentSchemas 作用在同一实例位置上，属于原地应用器，注解要收下。
      match obj_get_obj(obj, "dependentSchemas") {
        Some(dependencies) =>
          for name, sub in dependencies {
            match members.get(name) {
              Some(_) =>
                acc.merge(
                  eval(
                    v,
                    sub,
                    node_base,
                    schema_path +
                    "/dependentSchemas/" +
                    @pointer.escape_token(name),
                    instance,
                    instance_path,
                    collect,
                  ),
                )
              None => ()
            }
          }
        None => ()
      }
      // `dependencies` 是 2019-09 起被拆开的旧关键字：值要么是字符串数组
      // （等价 dependentRequired），要么是一个 schema（等价 dependentSchemas）。
      // 2020-12 保留它只是为了兼容——元 schema 里它标着 `deprecated`。
      // 它不是 2020-12 的正式关键字，所以放在词汇表裁剪的 applicator 名单里。
      match obj_get_obj(obj, "dependencies") {
        Some(dependencies) =>
          for name, spec in dependencies {
            match members.get(name) {
              Some(_) =>
                match spec {
                  Array(names) =>
                    for candidate in names {
                      match candidate {
                        String(dep) =>
                          match members.get(dep) {
                            Some(_) => ()
                            None => {
                              report(
                                v,
                                collect,
                                instance_path,
                                "dependencies",
                                schema_path,
                                "property `" +
                                name +
                                "` requires `" +
                                dep +
                                "` to be present",
                              )
                              acc.ok = false
                            }
                          }
                        _ => ()
                      }
                    }
                  // schema 形式：和 dependentSchemas 一样作用在同一实例位置上。
                  _ =>
                    acc.merge(
                      eval(
                        v,
                        spec,
                        node_base,
                        schema_path +
                        "/dependencies/" +
                        @pointer.escape_token(name),
                        instance,
                        instance_path,
                        collect,
                      ),
                    )
                }
              None => ()
            }
          }
        None => ()
      }
    }
    _ => ()
  }
  // =========================================================================
  // 7. unevaluatedProperties / unevaluatedItems
  //
  // 必须放在最后：它们要看到本层所有关键字（包括原地应用器）累积出来的
  // 认领记录。把它们写在前面就会漏掉后面关键字认领的那部分。
  // =========================================================================
  match instance {
    Object(members) =>
      match obj.get("unevaluatedProperties") {
        Some(sub) =>
          for name, value in members {
            match acc.props.get(name) {
              Some(_) => ()
              None => {
                acc.require(
                  eval(
                    v,
                    sub,
                    node_base,
                    schema_path + "/unevaluatedProperties",
                    value,
                    instance_path + "/" + @pointer.escape_token(name),
                    collect,
                  ),
                )
                acc.claim_prop(name)
              }
            }
          }
        None => ()
      }
    _ => ()
  }
  match instance {
    Array(items) =>
      match obj.get("unevaluatedItems") {
        Some(sub) =>
          for i = 0; i < items.length(); i = i + 1 {
            if !acc.is_claimed(i) {
              acc.require(
                eval(
                  v,
                  sub,
                  node_base,
                  schema_path + "/unevaluatedItems",
                  items[i],
                  instance_path + "/" + i.to_string(),
                  collect,
                ),
              )
              acc.claim_index(i)
            }
          }
        None => ()
      }
    _ => ()
  }
  acc
}
