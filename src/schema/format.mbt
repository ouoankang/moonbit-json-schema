// `format` 关键字的值校验（仅在 `format-assertion` 词汇表启用时生效）。
//
// 2020-12 默认把 `format` 当注解（`format-annotation` 词汇表），只有元 schema
// 显式声明了 `format-assertion`，`format` 才升级为断言。本模块实现那些断言
// 的「值是否合法」判定。
//
// 设计原则：
//   * 只认规范明确定义的格式，未实现/未识别的格式一律「放行」（返回 true），
//     因为规范要求实现可以忽略它不认识的 format。
//   * 每个格式只做「字符串值」的判定；非字符串实例由调用方（validate.mbt）
//     按 `format` 语义跳过（`format` 只约束字符串）。
//   * 全部按 ASCII/码点语义手写实现，不依赖宿主正则，保证跨后端一致。
//
// 注意：本文件里 `s.code_units()[i]` 取到的是 UTF-16 码元（UInt16），
// 这些格式的合法字符集都是 ASCII，所以按码元逐字节比较是正确且充分的。

///|
/// 判断 `format` 关键字的值是否满足对应格式。
///
/// 返回 `true` 表示「该字符串值满足此格式」（或本实现不识别该格式，放行）。
pub fn format_ok(name : String, value : String) -> Bool {
  match name {
    "date-time" => date_time_ok(value)
    "date" => date_ok(value)
    "time" => time_ok(value)
    "duration" => duration_ok(value)
    "ipv4" => ipv4_ok(value)
    "ipv6" => ipv6_ok(value)
    "hostname" => hostname_ok(value)
    "email" => email_ok(value)
    "uri" => uri_ok(value, false)
    "uri-reference" => uri_ok(value, true)
    "uuid" => uuid_ok(value)
    "json-pointer" => @pointer.is_valid(value)
    "relative-json-pointer" => relative_json_pointer_ok(value)
    "regex" => @regex.Regex::is_valid_strict(value)
    "uri-template" => uri_template_ok(value)
    // 未实现的格式（idn-email / idn-hostname / iri / iri-reference /
    // unknown 等）：按规范放行。
    _ => true
  }
}

// ===========================================================================
// 通用辅助
// ===========================================================================

///|
/// 取第 `i` 个 UTF-16 码元的整数值，越界返回 -1。
fn code(s : String, i : Int) -> Int {
  let units = s.code_units()
  if i < 0 || i >= units.length() {
    -1
  } else {
    units[i].to_int()
  }
}

///|
/// `s` 从 `i` 起的 `n` 个码元是否全是 ASCII 数字。
fn digits(s : String, i : Int, n : Int) -> Bool {
  if i < 0 || i + n > s.length() {
    return false
  }
  let units = s.code_units()
  let mut k = i
  while k < i + n {
    let c = units[k].to_int()
    if c < 0x30 || c > 0x39 {
      return false
    }
    k = k + 1
  }
  true
}

///|
/// 读取 4 位年份，返回整数值（不合法返回 -1）。
fn read_year(s : String, i : Int) -> Int {
  if !digits(s, i, 4) {
    return -1
  }
  let units = s.code_units()
  let mut y = 0
  let mut k = i
  while k < i + 4 {
    y = y * 10 + (units[k].to_int() - 0x30)
    k = k + 1
  }
  y
}

///|
/// 读取 2 位数字（`i..i+2`），返回整数值（不合法返回 -1）。
fn read2(s : String, i : Int) -> Int {
  if !digits(s, i, 2) {
    return -1
  }
  let units = s.code_units()
  (units[i].to_int() - 0x30) * 10 + (units[i + 1].to_int() - 0x30)
}

///|
/// 十六进制数字值，非十六进制返回 -1。
fn hex_digit(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    -1
  }
}

///|
/// 判断 `s` 是否以 `prefix` 开头。
fn has_prefix(s : String, prefix : String) -> Bool {
  let pn = prefix.length()
  if s.length() < pn {
    return false
  }
  let su = s.code_units()
  let pu = prefix.code_units()
  let mut i = 0
  while i < pn {
    if su[i].to_int() != pu[i].to_int() {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 判断 `s` 是否含字符 `c`（按码元值）。
fn contains_char(s : String, c : Int) -> Bool {
  let units = s.code_units()
  let mut i = 0
  while i < units.length() {
    if units[i].to_int() == c {
      return true
    }
    i = i + 1
  }
  false
}

// ===========================================================================
// date（RFC 3339 full-date）
// ===========================================================================

///|
/// 闰年判定（公历规则）。
fn is_leap(year : Int) -> Bool {
  if year % 4 != 0 {
    false
  } else if year % 100 != 0 {
    true
  } else {
    year % 400 == 0
  }
}

///|
/// 某月天数（1 月 = 1）。
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 => 31
    2 => if is_leap(year) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
/// 校验 `YYYY-MM-DD`（RFC 3339 full-date）。要求恰好 10 个字符。
fn date_ok(s : String) -> Bool {
  if s.length() != 10 {
    return false
  }
  let y = read_year(s, 0)
  if y < 0 {
    return false
  }
  if code(s, 4) != 0x2D {
    return false
  }
  let m = read2(s, 5)
  if m < 1 || m > 12 {
    return false
  }
  if code(s, 7) != 0x2D {
    return false
  }
  let d = read2(s, 8)
  d >= 1 && d <= days_in_month(y, m)
}

// ===========================================================================
// date-time（RFC 3339）
// ===========================================================================

///|
/// 校验 RFC 3339 `date-time`：`full-date ("T"|"t") full-time`。
fn date_time_ok(s : String) -> Bool {
  let units = s.code_units()
  let mut t = -1
  let mut i = 0
  while i < units.length() {
    let c = units[i].to_int()
    if c == 0x54 || c == 0x74 {
      t = i
      break
    }
    i = i + 1
  }
  if t < 0 {
    return false
  }
  date_ok(slice(s, 0, t)) && time_ok(slice(s, t + 1, units.length()))
}

// ===========================================================================
// time（RFC 3339 full-time）
// ===========================================================================

///|
/// 校验 RFC 3339 `full-time`：`HH:MM:SS[.frac](Z | ±HH:MM)`，允许 23:59:60 闰秒。
fn time_ok(s : String) -> Bool {
  let units = s.code_units()
  let n = units.length()
  if n < 9 {
    return false
  }
  let hh = read2(s, 0)
  if code(s, 2) != 0x3A {
    return false
  }
  let mm = read2(s, 3)
  if code(s, 5) != 0x3A {
    return false
  }
  let ss = read2(s, 6)
  if hh < 0 || hh > 23 || mm < 0 || mm > 59 {
    return false
  }
  if ss > 60 {
    return false
  }
  let mut k = 8
  // 可选小数秒。
  if code(s, k) == 0x2E {
    k = k + 1
    let start = k
    while k < n {
      let c = units[k].to_int()
      if c < 0x30 || c > 0x39 {
        break
      }
      k = k + 1
    }
    if k == start {
      return false
    }
  }
  // 时区后缀。
  let mut offset_min = 0
  match code(s, k) {
    0x5A | 0x7A => {
      if k != n - 1 {
        return false
      }
      offset_min = 0
    }
    0x2B | 0x2D => {
      if n - k != 6 {
        return false
      }
      let oh = read2(s, k + 1)
      let om = read2(s, k + 4)
      if code(s, k + 3) != 0x3A {
        return false
      }
      if oh < 0 || oh > 23 || om < 0 || om > 59 {
        return false
      }
      let sign = if code(s, k) == 0x2B { 1 } else { -1 }
      offset_min = sign * (oh * 60 + om)
    }
    _ => return false
  }
  // 闰秒 `:60` 只允许出现在 UTC 的 23:59:60，即「本地时间换算到 UTC 后
  // 是 23:59」。例如 `01:29:60+01:30` → UTC 23:59。
  if ss == 60 {
    let total = hh * 60 + mm - offset_min
    let utc = (total % 1440 + 1440) % 1440
    if utc != 23 * 60 + 59 {
      return false
    }
  }
  true
}

// ===========================================================================
// duration（ISO 8601）
// ===========================================================================

///|
/// 校验 ISO 8601 duration：`P[nY][nM][nW][nD][T[nH][nM][nS]]`。
///
/// 规则要点（官方用例）：
///   * `P` 后必须至少有一个组件；`T` 后必须至少有一个时间组件。
///   * 日期组件顺序固定 Y→M→W→D，时间组件 H→M→S，且不可跳级：
///     Y 与 D 之间必须有 M（`P1Y2D` 非法，`P1Y2M`/`P1M2D` 合法），
///     H 与 S 之间必须有 M（`PT1H2S` 非法）。
///   * 周 `W` 是排他的：不能与任何日期组件或时间组件混用。
fn duration_ok(s : String) -> Bool {
  let units = s.code_units()
  let n = units.length()
  if n < 2 || units[0].to_int() != 0x50 {
    return false
  }
  let mut i = 1
  let mut saw_week = false
  let mut saw_y = false
  let mut saw_m = false
  let mut saw_d = false
  let mut saw_time_separator = false
  let mut saw_h = false
  let mut saw_tm = false
  let mut saw_s = false
  // 上一个出现的组件「级别」，用于强制顺序。日期：Y=1 M=2 W=3 D=4；
  // 时间：H=1 M=2 S=3。
  let mut last_level = 0
  while i < n {
    let c = units[i].to_int()
    if c == 0x54 {
      if saw_time_separator {
        return false
      }
      saw_time_separator = true
      last_level = 0
      i = i + 1
      continue
    }
    if c >= 0x30 && c <= 0x39 {
      while i < n {
        let d = units[i].to_int()
        if d < 0x30 || d > 0x39 {
          break
        }
        i = i + 1
      }
      if i >= n {
        return false
      }
      let letter = units[i].to_int()
      if saw_time_separator {
        // 时间组件：H=1 M=2 S=3，严格递增（不可跳级由最后统一判定）。
        if letter == 0x48 {
          if last_level >= 1 {
            return false
          }
          last_level = 1
          saw_h = true
        } else if letter == 0x4D {
          if last_level >= 2 {
            return false
          }
          last_level = 2
          saw_tm = true
        } else if letter == 0x53 {
          if last_level >= 3 {
            return false
          }
          last_level = 3
          saw_s = true
        } else {
          return false
        }
      } else if letter == 0x59 {
        if last_level >= 1 {
          return false
        }
        last_level = 1
        saw_y = true
      } else if letter == 0x4D {
        if last_level >= 2 {
          return false
        }
        last_level = 2
        saw_m = true
      } else if letter == 0x57 {
        // 周：排他，不能与任何已出现的日期组件混用。
        if last_level >= 3 || saw_y || saw_m || saw_d {
          return false
        }
        last_level = 3
        saw_week = true
      } else if letter == 0x44 {
        if last_level >= 4 {
          return false
        }
        last_level = 4
        saw_d = true
      } else {
        return false
      }
      i = i + 1
      continue
    }
    return false
  }
  let has_date = saw_y || saw_m || saw_week || saw_d
  let has_time = saw_h || saw_tm || saw_s
  if !has_date && !has_time {
    return false
  }
  if saw_time_separator && !has_time {
    return false
  }
  // 跳级禁止：Y 与 D 同时出现必须有 M；H 与 S 同时出现必须有 M。
  if saw_y && saw_d && !saw_m {
    return false
  }
  if saw_h && saw_s && !saw_tm {
    return false
  }
  // 周不能与时间混用。
  if saw_week && has_time {
    return false
  }
  true
}

// ===========================================================================
// ipv4
// ===========================================================================

///|
/// 校验点分十进制 IPv4：四个 0–255 的十进制段，不允许前导零。
fn ipv4_ok(s : String) -> Bool {
  let units = s.code_units()
  let n = units.length()
  // 首尾不能是 '.'（否则有空段）。
  if n == 0 || units[0].to_int() == 0x2E || units[n - 1].to_int() == 0x2E {
    return false
  }
  let mut parts = 0
  let mut i = 0
  while i < n {
    let start = i
    let mut val = 0
    let mut len = 0
    while i < n {
      let c = units[i].to_int()
      if c < 0x30 || c > 0x39 {
        break
      }
      val = val * 10 + (c - 0x30)
      len = len + 1
      i = i + 1
      if len > 3 {
        return false
      }
    }
    if len == 0 || val > 255 {
      return false
    }
    if len > 1 && units[start].to_int() == 0x30 {
      return false
    }
    parts = parts + 1
    if i == n {
      break
    }
    if units[i].to_int() != 0x2E {
      return false
    }
    i = i + 1
  }
  parts == 4
}

// ===========================================================================
// ipv6
// ===========================================================================

///|
/// 校验 IPv6 文本表示（RFC 4291 §2.2），支持 `::` 压缩与嵌入式 IPv4。
fn ipv6_ok(s : String) -> Bool {
  let n = s.length()
  // `::` 至多出现一次。
  let mut double_colon = -1
  let mut i = 0
  while i < n - 1 {
    if code(s, i) == 0x3A && code(s, i + 1) == 0x3A {
      if double_colon >= 0 {
        return false
      }
      double_colon = i
    }
    i = i + 1
  }
  // 拆段（按 ':'）。
  let segments : Array[String] = []
  let mut start = 0
  let mut j = 0
  while j <= n {
    if j == n || code(s, j) == 0x3A {
      segments.push(slice(s, start, j))
      start = j + 1
    }
    j = j + 1
  }
  let seg_count = segments.length()
  let mut hex_count = 0
  let mut has_v4 = false
  let mut empty_count = 0
  let mut idx = 0
  while idx < seg_count {
    let seg = segments[idx]
    if seg.length() == 0 {
      // 空段只能来自 `::`；首尾的空段只在 `::` 在两端时合法。
      if idx == 0 {
        if double_colon != 0 {
          return false
        }
      } else if idx == seg_count - 1 {
        if double_colon != n - 2 {
          return false
        }
      } else {
        // 中间空段：必须是 `::` 且仅此一个。
      }
      empty_count = empty_count + 1
      idx = idx + 1
      continue
    }
    if contains_char(seg, 0x2E) {
      // IPv4 尾段，只能是最后一段。
      if idx != seg_count - 1 {
        return false
      }
      if !ipv4_ok(seg) {
        return false
      }
      has_v4 = true
    } else {
      let units = seg.code_units()
      if units.length() > 4 {
        return false
      }
      let mut t = 0
      while t < units.length() {
        if hex_digit(units[t].to_int()) < 0 {
          return false
        }
        t = t + 1
      }
      hex_count = hex_count + 1
    }
    idx = idx + 1
  }
  // 段数约束。
  if has_v4 {
    // IPv4 尾占用 2 个 16 位组。
    if double_colon < 0 {
      if hex_count != 6 {
        return false
      }
    } else if hex_count >= 6 {
      return false
    }
  } else if double_colon < 0 {
    if hex_count != 8 {
      return false
    }
  } else if hex_count >= 8 {
    return false
  }
  // `::` 存在时中间空段最多一个（空段总数约束：无压缩时不能有空段）。
  if double_colon < 0 && empty_count > 0 {
    return false
  }
  true
}

// ===========================================================================
// hostname（RFC 1123 标签 + `xn--` IDN 前缀）
// ===========================================================================

///|
/// 校验 hostname：点分隔的标签，每标签 1–63 字符，总长 ≤253，
/// 标签由字母数字与 `-` 组成，首尾不能是 `-`。
///
/// `xn--` 前缀的 IDN 标签只做「长度与前缀」的形式校验，不做完整 punycode
/// 解码（那是 idn-hostname 的范畴）。
fn hostname_ok(s : String) -> Bool {
  let n = s.length()
  if n == 0 || n > 253 {
    return false
  }
  let units = s.code_units()
  let mut label_start = 0
  let mut i = 0
  while i <= n {
    let at_end = i == n
    let c = if at_end { 0x2E } else { units[i].to_int() }
    if c == 0x2E || at_end {
      if !hostname_label_ok(slice(s, label_start, i)) {
        return false
      }
      label_start = i + 1
    }
    i = i + 1
  }
  true
}

///|
fn hostname_label_ok(label : String) -> Bool {
  let n = label.length()
  if n == 0 || n > 63 {
    return false
  }
  let units = label.code_units()
  let first = units[0].to_int()
  let last = units[n - 1].to_int()
  if first == 0x2D || last == 0x2D {
    return false
  }
  let mut i = 0
  while i < n {
    let c = units[i].to_int()
    let alpha = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    let digit = c >= 0x30 && c <= 0x39
    if !alpha && !digit && c != 0x2D {
      return false
    }
    i = i + 1
  }
  true
}

// ===========================================================================
// email（RFC 5322 简化）
// ===========================================================================

///|
/// 校验 email 地址。采用官方用例约束的简化语义：
///   * 恰好一个 `@`。
///   * 本地部分可为 dot-atom 或带引号的字符串（含转义）。
///   * 域部分可为 dot-atom、IPv4 字面量 `[1.2.3.4]` 或 `[IPv6:...]`。
fn email_ok(s : String) -> Bool {
  let n = s.length()
  let units = s.code_units()
  let mut at = -1
  let mut k = 0
  // 若本地部分以 `"` 开头，跳过往后到配对 `"`（含转义）之间的所有字符，
  // 这样引号内的 `@` 不会被误判为分隔符。
  let mut in_quoted = false
  while k < n {
    let c = units[k].to_int()
    if in_quoted {
      if c == 0x5C {
        k = k + 1 // 跳过转义的下一个字符
      } else if c == 0x22 {
        in_quoted = false
      }
    } else if c == 0x40 {
      if at >= 0 {
        return false
      }
      at = k
    } else if c == 0x22 && at < 0 {
      in_quoted = true
    }
    k = k + 1
  }
  if at <= 0 || at == n - 1 {
    return false
  }
  email_local_ok(slice(s, 0, at)) && email_domain_ok(slice(s, at + 1, n))
}

///|
fn email_local_ok(local_part : String) -> Bool {
  let n = local_part.length()
  if n == 0 || n > 64 {
    return false
  }
  let units = local_part.code_units()
  if units[0].to_int() == 0x22 {
    return quoted_local_ok(local_part)
  }
  // dot-atom：`.` 不能连续、不能在首尾。
  let mut prev_dot = false
  let mut i = 0
  while i < n {
    let c = units[i].to_int()
    if c == 0x2E {
      if prev_dot {
        return false
      }
      prev_dot = true
    } else {
      if !email_atom_char(c) {
        return false
      }
      prev_dot = false
    }
    i = i + 1
  }
  units[0].to_int() != 0x2E && units[n - 1].to_int() != 0x2E
}

///|
/// dot-atom 允许的字符：ASCII 字母数字与 `!#$%&'*+-/=?^_`{|}~`。
fn email_atom_char(c : Int) -> Bool {
  let alpha = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
  let digit = c >= 0x30 && c <= 0x39
  if alpha || digit {
    return true
  }
  match c {
    0x21
    | 0x23
    | 0x24
    | 0x25
    | 0x26
    | 0x27
    | 0x2A
    | 0x2B
    | 0x2D
    | 0x2F
    | 0x3D
    | 0x3F
    | 0x5E
    | 0x5F
    | 0x60
    | 0x7B
    | 0x7C
    | 0x7D
    | 0x7E => true
    _ => false
  }
}

///|
fn quoted_local_ok(local_part : String) -> Bool {
  let n = local_part.length()
  if n < 2 {
    return false
  }
  let units = local_part.code_units()
  if units[n - 1].to_int() != 0x22 {
    return false
  }
  let mut i = 1
  while i < n - 1 {
    let c = units[i].to_int()
    if c == 0x5C {
      // 转义：后面必须还有一个字符，且该字符必须是 ASCII（quoted-pair
      // 不允许非 ASCII 字符，官方用例 `"test\©"` 因此非法）。
      if i + 1 >= n - 1 {
        return false
      }
      let next = units[i + 1].to_int()
      if next > 0x7E {
        return false
      }
      i = i + 2
    } else if c == 0x22 {
      return false
    } else if c == 0x0D || c == 0x0A {
      return false
    } else {
      i = i + 1
    }
  }
  true
}

///|
fn email_domain_ok(domain : String) -> Bool {
  let n = domain.length()
  if n == 0 || n > 253 {
    return false
  }
  let units = domain.code_units()
  if units[0].to_int() == 0x5B {
    // 域名字面量 [ ... ]。
    if units[n - 1].to_int() != 0x5D {
      return false
    }
    let inner = slice(domain, 1, n - 1)
    // IPv6 标签大小写不敏感（官方用例接受 `[ipv6:::1]` 小写形式）。
    if has_prefix(inner, "IPv6:") || has_prefix(inner, "ipv6:") {
      return ipv6_ok(slice(inner, 5, inner.length()))
    }
    return ipv4_ok(inner)
  }
  hostname_ok(domain)
}

// ===========================================================================
// uri / uri-reference
// ===========================================================================

///|
/// 校验 URI（RFC 3986）。`allow_relative` 为 true 时接受无 scheme 的相对引用。
///
/// 分两步：先做整串的字符集校验（拒绝非法字符、非法百分号），再做结构校验
/// （scheme / authority 的 host、port、userinfo、IP-literal）。
fn uri_ok(s : String, allow_relative : Bool) -> Bool {
  let n = s.length()
  if !uri_chars_ok(s) {
    return false
  }
  // 找 scheme 结束的 ':'（只在前缀里找，遇 '/', '?', '#' 即停止）。
  let mut colon = -1
  let mut i = 0
  while i < n {
    let c = code(s, i)
    if c == 0x3A {
      colon = i
      break
    }
    if c == 0x2F || c == 0x3F || c == 0x23 {
      break
    }
    i = i + 1
  }
  let has_scheme = colon > 0 && uri_scheme_ok(slice(s, 0, colon))
  if !has_scheme && !allow_relative {
    return false
  }
  // 结构校验：找到 authority（`//` 之后到下一个 `/`、`?`、`#` 之间）。
  // 只有 scheme 之后紧接 `//` 才开启 authority 解析。
  let after_scheme = if colon > 0 { colon + 1 } else { 0 }
  if has_scheme &&
    code(s, after_scheme) == 0x2F &&
    code(s, after_scheme + 1) == 0x2F {
    let auth_start = after_scheme + 2
    let mut auth_end = auth_start
    while auth_end < n {
      let c = code(s, auth_end)
      if c == 0x2F || c == 0x3F || c == 0x23 {
        break
      }
      auth_end = auth_end + 1
    }
    if !authority_ok(slice(s, auth_start, auth_end)) {
      return false
    }
  } else if !has_scheme {
    // 相对引用。三种形态：network-path（`//...`）、absolute-path（`/...`）、
    // relative-path（不以 `/` 开头）。
    if code(s, 0) == 0x2F && code(s, 1) == 0x2F {
      // network-path reference：`//` 后接 authority，可为空（RFC 3986 §4.2）。
      let mut auth_end = 2
      while auth_end < n {
        let c = code(s, auth_end)
        if c == 0x2F || c == 0x3F || c == 0x23 {
          break
        }
        auth_end = auth_end + 1
      }
      let authority = slice(s, 2, auth_end)
      if authority.length() > 0 && !authority_ok(authority) {
        return false
      }
    } else {
      // absolute-path 或 relative-path：首段不能含 ':'（RFC 3986 §4.2，
      // 否则会被误认成 scheme）。`./this:that` 首段是 `.`，所以合法。
      let start = if code(s, 0) == 0x2F { 1 } else { 0 }
      let mut k = start
      while k < n {
        let c = code(s, k)
        if c == 0x2F || c == 0x3F || c == 0x23 {
          break
        }
        if c == 0x3A {
          return false
        }
        k = k + 1
      }
    }
  }
  // 路径段里不允许出现 `[` / `]`（它们只属于 authority 的 IP-literal）。
  if uri_path_has_bracket(s) {
    return false
  }
  true
}

///|
/// 判断 URI 的 path 部分（`?` / `#` 之前、authority 之后）是否含 `[` 或 `]`。
fn uri_path_has_bracket(s : String) -> Bool {
  let n = s.length()
  // 定位 path 起点：跳过 scheme 与 authority（`//...` 到下一个 `/`）。
  let mut i = 0
  // 跳过 scheme。
  while i < n {
    let c = code(s, i)
    if c == 0x3A {
      i = i + 1
      break
    }
    if c == 0x2F || c == 0x3F || c == 0x23 {
      break
    }
    i = i + 1
  }
  // 跳过 authority（若以 `//` 开头，跳到下一个 `/`）。
  if i < n && code(s, i) == 0x2F && code(s, i + 1) == 0x2F {
    i = i + 2
    while i < n {
      let c = code(s, i)
      if c == 0x2F || c == 0x3F || c == 0x23 {
        break
      }
      i = i + 1
    }
  }
  // 从这里到 `?` / `#` 之间是 path，检查 `[` / `]`。
  while i < n {
    let c = code(s, i)
    if c == 0x3F || c == 0x23 {
      break
    }
    if c == 0x5B || c == 0x5D {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// 校验 authority 部分：`[userinfo "@"] host [":" port]`。
fn authority_ok(authority : String) -> Bool {
  let n = authority.length()
  // 找最后一个 '@'（userinfo 分隔符）。
  let mut at = -1
  let mut i = 0
  while i < n {
    if code(authority, i) == 0x40 {
      at = i
    }
    i = i + 1
  }
  let hostport = if at >= 0 {
    // userinfo 存在：校验 userinfo 部分不允许出现 '[' 等（`[` 未闭合是非法
    // userinfo，官方用例 `https://[@example.org/...` 由此判 false）。
    let userinfo = slice(authority, 0, at)
    if !userinfo_ok(userinfo) {
      return false
    }
    slice(authority, at + 1, n)
  } else {
    authority
  }
  // host:port
  let hp = hostport
  let hp_n = hp.length()
  if hp_n == 0 {
    return false
  }
  // 找 ':' 分隔 host 与 port（注意 IPv6 字面量里的 ':' 要用 ']' 跳过）。
  let mut host_end = hp_n
  let mut port_start = -1
  let mut k = hp_n - 1
  let mut in_bracket = false
  while k >= 0 {
    let c = code(hp, k)
    if c == 0x5D {
      in_bracket = true
    } else if c == 0x5B {
      in_bracket = false
    } else if c == 0x3A && !in_bracket {
      port_start = k
      host_end = k
    }
    k = k - 1
  }
  let host = slice(hp, 0, host_end)
  if !uri_host_ok(host) {
    return false
  }
  if port_start >= 0 {
    let port = slice(hp, port_start + 1, hp_n)
    if port.length() == 0 {
      return false
    }
    let units = port.code_units()
    let mut j = 0
    while j < units.length() {
      let c = units[j].to_int()
      if c < 0x30 || c > 0x39 {
        return false
      }
      j = j + 1
    }
  }
  true
}

///|
/// userinfo 只允许 unreserved / sub-delims / `:` / pct-encoded，不允许 `[`、`]`。
fn userinfo_ok(userinfo : String) -> Bool {
  let units = userinfo.code_units()
  let mut i = 0
  while i < units.length() {
    let c = units[i].to_int()
    if c == 0x25 {
      // pct-encoded，已由 uri_chars_ok 保证合法。
      i = i + 1
    } else if c == 0x5B || c == 0x5D || c == 0x40 {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// host 的合法性：IP-literal `[...]`、IPv4、或 reg-name。
fn uri_host_ok(host : String) -> Bool {
  let n = host.length()
  if n == 0 {
    return false
  }
  let units = host.code_units()
  if units[0].to_int() == 0x5B {
    // IP-literal。
    if units[n - 1].to_int() != 0x5D {
      return false
    }
    let inner = slice(host, 1, n - 1)
    // IPv6 或 IPvFuture（`v<hex>.<...>`，版本字符大小写不敏感）。
    let vc = inner.code_units()[0].to_int()
    if inner.length() >= 2 && (vc == 0x76 || vc == 0x56) {
      // IPvFuture：v 后跟 hex 再 '.'
      let mut k = 1
      while k < inner.length() {
        let c = inner.code_units()[k].to_int()
        if c == 0x2E {
          return k > 1
        }
        if hex_digit(c) < 0 {
          return false
        }
        k = k + 1
      }
      return false
    }
    return ipv6_ok(inner)
  }
  // 含 '.' 可能是 IPv4，也可能是 reg-name（含 '.' 的域名）。
  // 这里按「能解析成 IPv4 就当 IPv4 校验，否则当 reg-name」处理。
  ipv4_ok(host) || hostname_ok(host)
}

///|
/// scheme 合法性：首字符字母，其后字母数字 `+-.`。
fn uri_scheme_ok(scheme : String) -> Bool {
  let n = scheme.length()
  if n == 0 {
    return false
  }
  let units = scheme.code_units()
  let first = units[0].to_int()
  let alpha = (first >= 0x61 && first <= 0x7A) ||
    (first >= 0x41 && first <= 0x5A)
  if !alpha {
    return false
  }
  let mut i = 1
  while i < n {
    let c = units[i].to_int()
    let a = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    let d = c >= 0x30 && c <= 0x39
    if !a && !d && c != 0x2B && c != 0x2D && c != 0x2E {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// URI 字符合法性：只允许 ASCII 可打印子集，`%` 后必须跟两个十六进制。
/// 拒绝空格、反斜杠、`<>"{}|^``、控制字符与非 ASCII。
fn uri_chars_ok(s : String) -> Bool {
  let units = s.code_units()
  let n = units.length()
  let mut i = 0
  while i < n {
    let c = units[i].to_int()
    if c < 0x21 || c > 0x7E {
      return false
    }
    if c == 0x5C ||
      c == 0x22 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x5E ||
      c == 0x60 ||
      c == 0x7C {
      return false
    }
    if c == 0x25 {
      if i + 2 >= n {
        return false
      }
      if hex_digit(units[i + 1].to_int()) < 0 ||
        hex_digit(units[i + 2].to_int()) < 0 {
        return false
      }
      i = i + 2
    }
    i = i + 1
  }
  true
}

// ===========================================================================
// uuid（RFC 4122）
// ===========================================================================

///|
/// 校验 UUID：`8-4-4-4-12` 的十六进制分组。
fn uuid_ok(s : String) -> Bool {
  let n = s.length()
  if n != 36 {
    return false
  }
  let units = s.code_units()
  let groups = [8, 4, 4, 4, 12]
  let mut pos = 0
  for gi = 0; gi < groups.length(); gi = gi + 1 {
    let len = groups[gi]
    for k = 0; k < len; k = k + 1 {
      if hex_digit(units[pos].to_int()) < 0 {
        return false
      }
      pos = pos + 1
    }
    if gi < groups.length() - 1 {
      if units[pos].to_int() != 0x2D {
        return false
      }
      pos = pos + 1
    }
  }
  true
}

// ===========================================================================
// relative-json-pointer
// ===========================================================================

///|
/// 校验相对 JSON Pointer：`非负整数 [ "#" | JSON Pointer ]`。
fn relative_json_pointer_ok(s : String) -> Bool {
  let n = s.length()
  if n == 0 {
    return false
  }
  let units = s.code_units()
  let mut i = 0
  if units[0].to_int() == 0x30 {
    // "0"：后面若还有数字则是前导零非法。
    if n > 1 && units[1].to_int() >= 0x30 && units[1].to_int() <= 0x39 {
      return false
    }
    i = 1
  } else {
    while i < n {
      let c = units[i].to_int()
      if c < 0x30 || c > 0x39 {
        break
      }
      i = i + 1
    }
    if i == 0 {
      return false
    }
  }
  if i == n {
    return true
  }
  let rest = slice(s, i, n)
  if has_prefix(rest, "#") {
    rest.length() == 1
  } else {
    has_prefix(rest, "/") && @pointer.is_valid(rest)
  }
}

// ===========================================================================
// uri-template（RFC 6570）
// ===========================================================================

///|
/// 校验 URI Template（RFC 6570）的语法合法性（不做展开）。
///
/// 语法要点：
///   * 字面量：允许 pchar 字符集与合法的 `%HH`；`%` 后必须跟两个十六进制。
///   * 表达式 `{...}`：可选操作符（`+ # . / ; ? &`）后接逗号分隔的 varspec。
///   * varspec：`varname`（varchar 或百分号编码，`.` 分隔层级）可带 `:前缀`
///     （1–4 位十进制、无前导零）与 `*`（explode，仅最后一个 varspec）。
///   * 不允许空表达式、空 varspec、尾逗号、默认值 `=`。
fn uri_template_ok(s : String) -> Bool {
  let units = s.code_units()
  let n = units.length()
  let mut i = 0
  while i < n {
    let c = units[i].to_int()
    if c == 0x7B {
      // 表达式。
      let (ok, next) = uri_template_expr_ok(s, i)
      if !ok {
        return false
      }
      i = next
    } else if c == 0x7D {
      // 孤立右花括号非法。
      return false
    } else if c == 0x25 {
      // 百分号编码必须是 `%HH`。
      if i + 2 >= n {
        return false
      }
      if hex_digit(units[i + 1].to_int()) < 0 ||
        hex_digit(units[i + 2].to_int()) < 0 {
        return false
      }
      i = i + 3
    } else {
      // 字面量字符：空格（0x20）、删除（0x7F）与 C0 控制字符非法；
      // 非 ASCII（Unicode）字符允许（展开时会被百分号编码，官方用例
      // `a😀b` 即如此）。
      if c == 0x20 || c == 0x7F || c < 0x21 {
        return false
      }
      i = i + 1
    }
  }
  true
}

///|
/// 从 `{` 处解析一个表达式，返回 `(是否合法, 表达式结束后下一个位置)`。
fn uri_template_expr_ok(s : String, start : Int) -> (Bool, Int) {
  let units = s.code_units()
  let n = units.length()
  let mut i = start + 1
  // 可选操作符。
  let op = units[i].to_int()
  if op == 0x2B ||
    op == 0x23 ||
    op == 0x2E ||
    op == 0x2F ||
    op == 0x3B ||
    op == 0x3F ||
    op == 0x26 {
    i = i + 1
  }
  // 至少要有一个 varspec。
  if i >= n {
    return (false, start)
  }
  let mut first_varspec = true
  while true {
    if i >= n {
      return (false, start)
    }
    let c = units[i].to_int()
    if c == 0x7D {
      // 结束。空表达式 `{}` 非法（first_varspec 且没读任何字符）。
      if first_varspec {
        return (false, start)
      }
      return (true, i + 1)
    }
    if c == 0x2C {
      // 逗号：必须后接一个 varspec（尾逗号非法）。
      if first_varspec {
        return (false, start)
      }
      i = i + 1
      if i >= n || units[i].to_int() == 0x7D || units[i].to_int() == 0x2C {
        return (false, start)
      }
      first_varspec = true
      continue
    }
    // 解析一个 varspec。
    let (ok, next) = uri_template_varspec_ok(s, i)
    if !ok {
      return (false, start)
    }
    i = next
    first_varspec = false
  }
  (true, i)
}

///|
/// 从 `i` 处解析一个 varspec（`varname[:prefix][*]`），返回 `(是否合法, 下一个位置)`。
fn uri_template_varspec_ok(s : String, i : Int) -> (Bool, Int) {
  let units = s.code_units()
  let n = units.length()
  let mut k = i
  // varname：varchar = ALPHA / DIGIT / '_' / pct-encoded，或用 '.' 分隔的多个。
  let mut segment_has_char = false
  while k < n {
    let c = units[k].to_int()
    if c == 0x2E {
      // '.'：层级分隔，前后都必须有内容（`{a..b}` 非法）。
      if !segment_has_char {
        return (false, i)
      }
      segment_has_char = false
      k = k + 1
    } else if c == 0x25 {
      if k + 2 >= n {
        return (false, i)
      }
      if hex_digit(units[k + 1].to_int()) < 0 ||
        hex_digit(units[k + 2].to_int()) < 0 {
        return (false, i)
      }
      segment_has_char = true
      k = k + 3
    } else if (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x5F {
      segment_has_char = true
      k = k + 1
    } else {
      break
    }
  }
  if !segment_has_char {
    return (false, i)
  }
  // 可选 `:prefix`（1–4 位十进制，无前导零）。
  if k < n && units[k].to_int() == 0x3A {
    k = k + 1
    let pstart = k
    let mut plen = 0
    while k < n {
      let c = units[k].to_int()
      if c < 0x30 || c > 0x39 {
        break
      }
      plen = plen + 1
      k = k + 1
    }
    // 1–4 位，且无前导零（`01` 非法，`0` 非法因为规范要求 prefix ≥ 1）。
    if plen == 0 || plen > 4 {
      return (false, i)
    }
    if units[pstart].to_int() == 0x30 {
      return (false, i)
    }
  }
  // 可选 explode `*`。
  if k < n && units[k].to_int() == 0x2A {
    k = k + 1
  }
  (true, k)
}
