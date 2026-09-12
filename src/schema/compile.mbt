// Schema 预处理：建立 $id / $anchor 索引，并提供 $ref 解析。
//
// 设计要点：
//   * 索引在第一次校验前一次性建好。校验过程中不再扫描整棵 schema 树。
//   * `$id` 会改变其后子 schema 的 base URI，所以索引阶段必须把 base
//     一路往下传。URI 解析交给 uri.mbt（RFC 3986）。
//   * 解析 $ref 的结果是「节点 + 该节点的 base + 路径」，而不是字符串比较。
//     `$ref: "#/a/0"` 这种指针要真正在文档里走一遍，才能拿到节点。

///|
/// 索引里保存的一条 schema 位置信息。
///
/// `uri` 和 `base` 是**两个不同的东西**，混用会出两类很难查的错：
///
///   * `uri`：这个节点所在资源的绝对 URI（`$id` 已经解析过）。
///     它是节点在「资源地图」上的地址，`$dynamicRef` 的动态作用域用的就是它。
///   * `base`：求值这个节点时应当传给 `eval` 的 base，也就是**它自己 `$id`
///     的解析基准**（规范要求 `$id` 相对父 base 解析）。
///
/// 如果拿 `uri` 当 `base` 用，`$id` 就会被解析两次：远程文档
/// `{"$id":"a/","items":{"$ref":"x.json"}}` 会算出 `a/a/x.json`。
/// 测试套件里 "base URI change - change folder" 就是专门抓这个的。
priv struct SchemaRef {
  /// schema 节点本身。
  node : Json
  /// 相对根文档的 JSON Pointer，用于报错时指明「是哪条规则」。
  path : String
  /// 节点所在资源的绝对 URI（已解析）。
  uri : String
  /// 求值该节点时应传入的 base（= 该节点 `$id` 的解析基准）。
  base : String
}

///|
/// `$ref` 的解析结果。
priv enum RefLookup {
  /// 命中当前文档内的某个节点。
  Hit(SchemaRef)
  /// 指向当前文档之外的资源（需要网络或文件系统），本实现不解析。
  External(String)
  /// 在当前文档内找不到（指针越界、锚点不存在等）。
  Missing(String)
}

///|
/// 一次校验会话的共享状态。
struct Validator {
  /// schema 文档根节点。
  root : Json
  /// 根文档的 base URI（等于根的 `$id`，没有则为空串）。
  root_base : String
  /// 资源表：绝对 URI（不含 fragment）-> 资源根节点。
  resources : Map[String, SchemaRef]
  /// `$anchor` 表：`绝对 URI#锚点名` -> 节点。只服务静态引用（`$ref`）。
  anchors : Map[String, SchemaRef]
  /// `$dynamicAnchor` 表，与 `anchors` 分开存。
  ///
  /// 分开是必要的：规范要求「同名 `$anchor` 不参与动态作用域解析」，
  /// 合成一张表就没法区分这两类锚点了。
  dynamic_anchors : Map[String, SchemaRef]
  /// 动态作用域：当前正在求值的资源 URI 栈，下标 0 是最外层。
  /// `$dynamicRef` 从最外层往内找第一个同名 `$dynamicAnchor`。
  mut dynamic_scope : Array[String]
  /// 正则缓存。`None` 表示该 pattern 编译失败（避免反复重试）。
  patterns : Map[String, @regex.Regex?]
  /// 根文档声明的方言启用了哪些词汇表。
  ///
  /// `$vocabulary` 不是装饰：元 schema 没声明某个词汇表，那个词汇表的关键字
  /// 就必须当成**未知关键字忽略**掉。官方套件里有专门用例：一份把
  /// validation 词汇表摘掉的元 schema，用它当 `$schema` 的文档里
  /// `minimum` 必须完全不起作用。core 永远启用，所以这里不记它。
  vocab_applicator : Bool
  vocab_validation : Bool
  vocab_unevaluated : Bool
  /// 收集到的错误。
  mut errors : Array[ValidationError]
  /// 正在求值的 (schema 路径, 实例路径) 组合，用于打断自引用造成的死循环。
  mut active : Map[String, Bool]
  /// 递归深度。
  mut depth : Int
}

///|
/// 递归深度上限。超出后放弃深入（宁可放过也不误报）。
const MAX_DEPTH : Int = 256

///|
fn obj_get_str(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn obj_get_num(obj : Map[String, Json], key : String) -> Double? {
  match obj.get(key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
fn obj_get_arr(obj : Map[String, Json], key : String) -> Array[Json]? {
  match obj.get(key) {
    Some(Array(a)) => Some(a)
    _ => None
  }
}

///|
fn obj_get_obj(obj : Map[String, Json], key : String) -> Map[String, Json]? {
  match obj.get(key) {
    Some(Object(o)) => Some(o)
    _ => None
  }
}

///|
/// 取节点的 `$id`（若存在且为字符串）。
fn schema_id(node : Json) -> String? {
  match node {
    Object(obj) => obj_get_str(obj, "$id")
    _ => None
  }
}

///|
/// 取节点的 `$dynamicAnchor`（若存在且为字符串）。
fn schema_dynamic_anchor(node : Json) -> String? {
  match node {
    Object(obj) => obj_get_str(obj, "$dynamicAnchor")
    _ => None
  }
}

///|
/// 在 JSON 文档里按 JSON Pointer 取节点；解析失败或越界返回 `None`。
fn pointer_lookup(root : Json, pointer : String) -> Json? {
  let tokens = try {
    Some(@pointer.parse(pointer))
  } catch {
    _ => None
  }
  match tokens {
    Some(ts) => @pointer.get_by_tokens(root, ts)
    None => None
  }
}

///|
/// 可能承载子 schema 的关键字（值本身是一个 schema）。
let single_subschema_keywords : Array[String] = [
  "additionalProperties",
  "additionalItems",
  "contains",
  "propertyNames",
  "if",
  "then",
  "else",
  "not",
  "unevaluatedItems",
  "unevaluatedProperties",
  "contentSchema",
]

///|
/// 值可能是「单个 schema」或「schema 数组」的关键字。
let list_subschema_keywords : Array[String] = [
  "allOf",
  "anyOf",
  "oneOf",
  "prefixItems",
  "items",
]

///|
/// 值是「名字 -> schema」映射的关键字。
let map_subschema_keywords : Array[String] = [
  "$defs",
  "definitions",
  "properties",
  "patternProperties",
  "dependentSchemas",
]

///|
/// 递归建立索引：把每个资源的根和每个锚点登记下来。
fn index_node(v : Validator, node : Json, base : String, path : String) -> Unit {
  let obj = match node {
    Object(o) => o
    _ => return
  }
  // 本节点自己的 base：`$id` 相对父 base 解析。
  //
  // 登记时 `base` 记的是**父 base**（见 `SchemaRef` 的注释），不是解析结果——
  // 求值时 `eval_object` 会再做一次同样的解析。
  let node_base = match obj_get_str(obj, "$id") {
    Some(id) => {
      let resolved = resolve(base, id)
      v.resources.set(resolved, { node, path, uri: resolved, base })
      resolved
    }
    None => base
  }
  // `$anchor` 只进静态表；`$dynamicAnchor` 两张表都进——因为它既能被
  // 普通 `$ref` 当锚点用，又是动态作用域解析的候选。
  match obj_get_str(obj, "$anchor") {
    Some(anchor) => {
      v.anchors.set(node_base + "#" + anchor, { node, path, uri: node_base, base })
    }
    None => ()
  }
  match obj_get_str(obj, "$dynamicAnchor") {
    Some(anchor) => {
      let entry : SchemaRef = { node, path, uri: node_base, base }
      v.anchors.set(node_base + "#" + anchor, entry)
      v.dynamic_anchors.set(node_base + "#" + anchor, entry)
    }
    None => ()
  }
  for key in single_subschema_keywords {
    match obj.get(key) {
      Some(child) => {
        index_node(v, child, node_base, path + "/" + @pointer.escape_token(key))
      }
      None => ()
    }
  }
  for key in list_subschema_keywords {
    match obj.get(key) {
      Some(Array(items)) => {
        for i = 0; i < items.length(); i = i + 1 {
          index_node(
            v,
            items[i],
            node_base,
            path + "/" + @pointer.escape_token(key) + "/" + i.to_string(),
          )
        }
      }
      // `items` 在 2020-12 里是单个 schema；旧草案里才是数组。
      Some(child) => {
        index_node(v, child, node_base, path + "/" + @pointer.escape_token(key))
      }
      None => ()
    }
  }
  for key in map_subschema_keywords {
    match obj_get_obj(obj, key) {
      Some(members) => {
        for name, child in members {
          index_node(
            v,
            child,
            node_base,
            path + "/" + @pointer.escape_token(key) + "/" + @pointer.escape_token(name),
          )
        }
      }
      None => ()
    }
  }
}

///|
/// 在已登记的外部文档里按绝对 URI 找一份文档。找不到时再按文档自身的
/// `$id` 找一遍——同一份元 schema 可能挂在别的 URI 下被取用。
fn find_document(documents : Array[(String, Json)], uri : String) -> Json? {
  for entry in documents {
    if entry.0 == uri {
      return Some(entry.1)
    }
  }
  for entry in documents {
    match schema_id(entry.1) {
      Some(id) =>
        if id == uri {
          return Some(entry.1)
        }
      None => ()
    }
  }
  None
}

///|
/// 从根文档的 `$schema` 读出它启用了哪些词汇表，返回
/// `(applicator, validation, unevaluated)`。
///
/// 默认全开。这个「默认」很关键：绝大多数 schema 不会自带一份元 schema，
/// 它们指向的是 `https://json-schema.org/draft/2020-12/schema` 这个标准 URI，
/// 而那份文档未必被登记进来。此时按 2020-12 全量词汇表处理才是对的——
/// 「查不到就当成什么都没启用」会让所有关键字集体失效。
///
/// 只有真的拿到了一份元 schema、且它写了 `$vocabulary`，才按声明裁剪。
fn dialect_of(
  root : Json,
  documents : Array[(String, Json)],
) -> (Bool, Bool, Bool) {
  let full = (true, true, true)
  let schema_uri = match root {
    Object(o) => obj_get_str(o, "$schema")
    _ => None
  }
  let uri = match schema_uri {
    Some(u) => u
    None => return full
  }
  let meta = match find_document(documents, uri) {
    Some(m) => m
    None => return full
  }
  let table = match meta {
    Object(o) => obj_get_obj(o, "$vocabulary")
    _ => None
  }
  let vocab = match table {
    Some(t) => t
    None => return full
  }
  let mut applicator = false
  let mut validation = false
  let mut unevaluated = false
  for name, enabled in vocab {
    // 值必须是 `true`：`false` 表示「本实现不支持时也不得忽略」（规范 §8.1.2）。
    // 我们按「不支持即忽略」处理，所以这里只认 `true`。
    let on = match enabled {
      True => true
      _ => false
    }
    if on {
      if name.has_suffix("/vocab/applicator") {
        applicator = true
      } else if name.has_suffix("/vocab/validation") {
        validation = true
      } else if name.has_suffix("/vocab/unevaluated") {
        unevaluated = true
      }
    }
  }
  (applicator, validation, unevaluated)
}

///|
/// 建立校验会话。`root` 是 schema 文档根节点。
fn Validator::build(root : Json) -> Validator {
  Validator::build_with(root, [])
}

///|
/// 建立校验会话，并预置一批外部文档。
///
/// `documents` 的每一项是 `(绝对 URI, 文档节点)`。这是跨文档 `$ref` 的入口：
/// 只要把远程 schema 事先读进来登记好，`$ref` 就能解析过去——不需要在
/// 校验途中做 IO。索引阶段每份文档都当一个独立资源处理，所以它们各自的
/// `$id`、`$anchor`、`$dynamicAnchor` 都会被正确登记。
fn Validator::build_with(
  root : Json,
  documents : Array[(String, Json)],
) -> Validator {
  let root_base = match schema_id(root) {
    Some(id) => resolve("", id)
    None => ""
  }
  let dialect = dialect_of(root, documents)
  let v : Validator = {
    root,
    root_base,
    resources: Map([]),
    anchors: Map([]),
    dynamic_anchors: Map([]),
    dynamic_scope: [],
    patterns: Map([]),
    vocab_applicator: dialect.0,
    vocab_validation: dialect.1,
    vocab_unevaluated: dialect.2,
    errors: [],
    active: Map([]),
    depth: 0,
  }
  // 根文档没有「父 base」——它的 `$id` 是相对空 base 解析的。所以这里传 `""`
  // 作为 base，让 `index_node` 自己算出 `root_base`。
  index_node(v, root, "", "")
  // 根文档没有 `$id` 时 `index_node` 不会为它登记资源，这里补上。
  v.resources.set(root_base, { node: root, path: "", uri: root_base, base: "" })
  for entry in documents {
    let (uri, node) = entry
    // 外部文档的「父 base」就是它被取用的那个 URI：`$id` 相对它解析。
    v.resources.set(uri, { node, path: "", uri, base: uri })
    index_node(v, node, uri, "")
  }
  v
}

///|
/// 复位一次校验之间的可变状态。索引与正则缓存保留，可以反复校验不同实例。
fn Validator::reset(self : Validator) -> Unit {
  self.errors = []
  self.active = Map([])
  self.depth = 0
  self.dynamic_scope = [self.root_base]
}

///|
/// 解析一个 `$ref`。
fn Validator::lookup(
  self : Validator,
  current_base : String,
  reference : String,
) -> RefLookup {
  let absolute = resolve(current_base, reference)
  let (resource_uri, fragment) = split_fragment(absolute)
  let start = match self.resources.get(resource_uri) {
    Some(r) => r
    None => return External(absolute)
  }
  if fragment.length() == 0 {
    return Hit(start)
  }
  // fragment 以 '/' 开头（或就是 "/"）时是 JSON Pointer。
  if fragment.unsafe_get(0).to_int() == 0x2F {
    match pointer_lookup(start.node, fragment) {
      Some(node) => {
        // 指针目标本身可能又是**另一个资源的根**（它自带 `$id`）。这时目标
        // 所在资源是那个 `$id` 解析出来的 URI，而不是 `start.uri`。
        //
        // 这个区别只在动态作用域上体现，但它是有语义的：`$ref` 指向
        // `bar#/$defs/item` 时，如果 `item` 自带 `$id`，那么进入的是 `item`
        // 这个资源，`bar` 只是被「跨过」。官方套件里
        // "$dynamicRef skips over intermediate resources" 说的就是这件事。
        let target_uri = match schema_id(node) {
          Some(id) => resolve(start.uri, id)
          None => start.uri
        }
        // `base` 仍是 `start.uri`：目标节点的 `$id`（如果有）要相对它解析。
        Hit({ node, path: fragment, uri: target_uri, base: start.uri })
      }
      None => Missing(absolute)
    }
  } else {
    match self.anchors.get(resource_uri + "#" + fragment) {
      Some(r) => Hit(r)
      None => Missing(absolute)
    }
  }
}

///|
/// 解析一个 `$dynamicRef`。
///
/// 分两步（core 规范 §8.2.3.2）：
///
///   1. 先按普通 `$ref` 做**静态**解析；
///   2. 只有当静态目标本身声明了同名的 `$dynamicAnchor` 时，才切换到
///      **动态**解析——在动态作用域里从最外层往里找第一个同名
///      `$dynamicAnchor`，用找到的那个替换静态目标。
///
/// 第 2 步的条件是容易搞错的地方：如果静态目标不是 `$dynamicAnchor`
/// （比如它只是个普通 `$anchor`，或者干脆是指针），`$dynamicRef` 的行为
/// 就和 `$ref` 完全一样，不参与动态查找。
fn Validator::lookup_dynamic(
  self : Validator,
  current_base : String,
  reference : String,
) -> RefLookup {
  let statically = self.lookup(current_base, reference)
  let target = match statically {
    Hit(t) => t
    _ => return statically
  }
  let (_, fragment) = split_fragment(resolve(current_base, reference))
  if fragment.length() == 0 {
    return statically
  }
  match schema_dynamic_anchor(target.node) {
    Some(name) =>
      if name != fragment {
        return statically
      }
    None => return statically
  }
  for i = 0; i < self.dynamic_scope.length(); i = i + 1 {
    match self.dynamic_anchors.get(self.dynamic_scope[i] + "#" + fragment) {
      Some(r) => return Hit(r)
      None => ()
    }
  }
  statically
}

///|
/// 进入一个资源，把它压入动态作用域。返回是否真的压了栈。
///
/// 与栈顶相同的资源不重复压：自引用（`$ref: "#"`）会让同一资源被反复进入，
/// 不设这个闸门，作用域会随递归深度线性膨胀，而语义上并没有多出任何东西。
fn Validator::enter_resource(self : Validator, uri : String) -> Bool {
  let n = self.dynamic_scope.length()
  if n > 0 && self.dynamic_scope[n - 1] == uri {
    return false
  }
  self.dynamic_scope.push(uri)
  true
}

///|
/// 取得（必要时编译并缓存）正则。
///
/// 缓存是必要的：`patternProperties` 会对「每个 pattern × 每个属性」调用
/// 匹配，属性多的时候同一份正则会被反复要用。编译失败也缓存（记成 `None`），
/// 否则非法 pattern 会在每次匹配时重新尝试编译。
///
/// 这里用的是本仓库自己的 ECMA-262 引擎，不是宿主平台的 `RegExp`——
/// 规范明确要求 `pattern` 按 ECMA-262 语义解释，而「宿主语言的正则够用」
/// 这个假设在 wasm 目标上根本不成立（那里没有原生正则）。
fn Validator::regex_for(self : Validator, pattern : String) -> @regex.Regex? {
  match self.patterns.get(pattern) {
    Some(cached) => cached
    None => {
      let compiled = try {
        Some(@regex.Regex::compile(pattern))
      } catch {
        _ => None
      }
      self.patterns.set(pattern, compiled)
      compiled
    }
  }
}
