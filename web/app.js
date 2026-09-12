// 在线试用页的胶水层。
//
// 这里没有任何校验逻辑 —— 全部结论来自 vendor/moonbit-json-schema.js，
// 也就是 MoonBit 那份实现本身。本文件只负责：把文本框内容送进去、
// 把回来的 JSON 渲染成表格、并把「解析失败」和「校验不通过」显示成
// 两种明显不同的东西。
//
// 刻意用传统 <script> 而不是 ES module：这样页面在 file:// 下双击就能打开，
// 不必先起一个本地服务器。

(function () {
  "use strict";

  var REPO = "https://github.com/ouoankang/moonbit-json-schema";

  // ---------------------------------------------------------------------
  // 示例
  // ---------------------------------------------------------------------

  // 示例数据放在 examples.js 里。抽出去是为了让 scripts/web-examples-check.mjs
  // 能在 Node 里对每条示例跑断言 —— 示例和实现脱节时，页面会开始演示一个
  // 并不存在的功能，而这种错误肉眼看不出来。
  var EXAMPLES = window.JSON_SCHEMA_DEMO_EXAMPLES || [];

  function pretty(value) {
    return JSON.stringify(value, null, 2);
  }

  // ---------------------------------------------------------------------
  // DOM
  // ---------------------------------------------------------------------

  var el = {
    select: document.getElementById("example-select"),
    schema: document.getElementById("schema"),
    instance: document.getElementById("instance"),
    verdict: document.getElementById("verdict"),
    timing: document.getElementById("timing"),
    note: document.getElementById("note"),
    tableSlot: document.getElementById("table-slot"),
    metaList: document.getElementById("meta-list"),
    footStat: document.getElementById("foot-stat"),
    btnValidate: document.getElementById("btn-validate"),
    btnLint: document.getElementById("btn-lint"),
    btnClear: document.getElementById("btn-clear"),
    repoLink: document.getElementById("repo-link"),
    footRepo: document.getElementById("foot-repo")
  };

  el.repoLink.href = REPO;
  el.footRepo.href = REPO;

  var api = window.MoonbitJsonSchema;

  // ---------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------

  function setVerdict(kind, text) {
    var cls = { ok: "verdict ok", bad: "verdict bad", error: "verdict error", idle: "verdict idle" };
    el.verdict.className = cls[kind] || cls.idle;
    el.verdict.textContent = text;
  }

  function setNote(text, mono) {
    el.note.textContent = text;
    el.note.className = mono ? "note mono" : "note";
  }

  function clearTable() {
    el.tableSlot.innerHTML = "";
  }

  /** 把错误列表渲染成表格。四个字段都显示出来：位置、关键字、说明、规则出处。 */
  function renderErrors(errors) {
    clearTable();
    if (!errors || errors.length === 0) {
      return;
    }
    var table = document.createElement("table");
    var thead = document.createElement("thead");
    var hr = document.createElement("tr");
    ["实例位置", "关键字", "说明", "规则位于 schema 的"].forEach(function (t) {
      var th = document.createElement("th");
      th.textContent = t;
      hr.appendChild(th);
    });
    thead.appendChild(hr);
    table.appendChild(thead);

    var tbody = document.createElement("tbody");
    var sawBooleanFalse = false;

    errors.forEach(function (e) {
      var tr = document.createElement("tr");

      var tdPath = document.createElement("td");
      tdPath.className = "mono";
      tdPath.textContent = e.instancePath === "" ? "/（根）" : e.instancePath;
      tr.appendChild(tdPath);

      var tdKw = document.createElement("td");
      var span = document.createElement("span");
      span.className = "kw";
      span.textContent = e.keyword;
      tdKw.appendChild(span);
      tr.appendChild(tdKw);

      if (e.keyword === "false") {
        sawBooleanFalse = true;
      }

      var tdMsg = document.createElement("td");
      tdMsg.textContent = e.message;
      tr.appendChild(tdMsg);

      var tdSchema = document.createElement("td");
      tdSchema.className = "mono";
      tdSchema.textContent = e.schemaPath;
      tr.appendChild(tdSchema);

      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    el.tableSlot.appendChild(table);

    // 布尔 schema 直接拒绝时，「关键字」一栏会显示 false。这是准确的
    // ——失败的确实就是那个布尔 false 本身，而不是某个带名字的关键字
    // ——但对头一次看到的人像是 bug，所以出现时补一句说明。
    if (sawBooleanFalse) {
      var foot = document.createElement("p");
      foot.className = "note";
      foot.style.marginTop = "10px";
      foot.textContent =
        "「关键字」显示 false，表示该处规则写的就是布尔 schema false（例如 " +
        "unevaluatedProperties: false）。它拒绝一切，本身没有关键字名，" +
        "确切位置看最后一列。";
      el.tableSlot.appendChild(foot);
    }
  }

  // ---------------------------------------------------------------------
  // 动作
  // ---------------------------------------------------------------------

  function run(action) {
    if (!api) {
      setVerdict("error", "加载失败");
      setNote("没有找到 MoonBitJsonSchema。请确认 vendor/moonbit-json-schema.js 已随页面一起加载。");
      return;
    }

    var schemaText = el.schema.value;
    var instanceText = el.instance.value;

    var t0 = performance.now();
    var raw;
    try {
      raw = action === "lint" ? api.lint(schemaText) : api.validate(schemaText, instanceText);
    } catch (e) {
      setVerdict("error", "运行时异常");
      setNote(String(e && e.message ? e.message : e), true);
      clearTable();
      return;
    }
    var ms = performance.now() - t0;

    var data;
    try {
      data = JSON.parse(raw);
    } catch (e) {
      setVerdict("error", "响应无法解析");
      setNote(String(raw).slice(0, 500), true);
      clearTable();
      return;
    }

    el.timing.textContent = ms.toFixed(1) + " ms";

    if (data.status === "error") {
      // 输入本身不是合法 JSON —— 和「校验不通过」是两回事，必须分开显示。
      setVerdict("error", "输入无法解析");
      setNote(data.message || "未知错误", true);
      clearTable();
      return;
    }

    if (data.status === "ok") {
      setVerdict("ok", action === "lint" ? "schema 合法" : "校验通过");
      setNote(
        action === "lint"
          ? "这份 schema 符合 JSON Schema draft 2020-12 的元 schema，没有拼写或取值问题。"
          : "这份数据符合 schema 的全部约束。"
      );
      clearTable();
      return;
    }

    setVerdict("bad", (action === "lint" ? "schema 不合法" : "校验不通过") + " · " + data.count + " 处");
    setNote(
      action === "lint"
        ? "下面每一条都指向 schema 自身的问题。第 4 列给出问题所在的关键字位置。"
        : "下面每一条都是一处具体的不符合。第 4 列说明这条规则写在 schema 的哪个位置。"
    );
    renderErrors(data.errors);
  }

  // ---------------------------------------------------------------------
  // 事件
  // ---------------------------------------------------------------------

  EXAMPLES.forEach(function (ex, i) {
    var opt = document.createElement("option");
    opt.value = String(i);
    opt.textContent = ex.name;
    el.select.appendChild(opt);
  });

  function loadExample(i) {
    var ex = EXAMPLES[i];
    el.schema.value = pretty(ex.schema);
    el.instance.value = pretty(ex.instance);
    clearTable();
    el.timing.textContent = "";
    setVerdict("idle", "尚未校验");
    setNote(ex.note);
    // 「写错的 schema」那条默认走 lint —— 用 validate 看它会得出误导性的结论。
    run(ex.preferLint ? "lint" : "validate");
  }

  el.select.addEventListener("change", function () {
    loadExample(Number(el.select.value));
  });

  el.btnValidate.addEventListener("click", function () {
    run("validate");
  });

  el.btnLint.addEventListener("click", function () {
    run("lint");
  });

  el.btnClear.addEventListener("click", function () {
    el.schema.value = "";
    el.instance.value = "";
    clearTable();
    el.timing.textContent = "";
    setVerdict("idle", "尚未校验");
    setNote("已清空。");
  });

  // 文本框里按 Tab 插入两个空格，别把焦点跳走。
  [el.schema, el.instance].forEach(function (ta) {
    ta.addEventListener("keydown", function (ev) {
      if (ev.key !== "Tab") {
        return;
      }
      ev.preventDefault();
      var s = ta.selectionStart;
      var e = ta.selectionEnd;
      ta.value = ta.value.slice(0, s) + "  " + ta.value.slice(e);
      ta.selectionStart = ta.selectionEnd = s + 2;
    });
  });

  // ---------------------------------------------------------------------
  // 启动
  // ---------------------------------------------------------------------

  if (!api) {
    setVerdict("error", "加载失败");
    setNote("没有找到 MoonbitJsonSchema。");
  } else {
    // 列一下内置元 schema，让人看到「离线可用」是有实据的。
    try {
      var meta = JSON.parse(api.metaschemaList());
      var total = meta.items.reduce(function (acc, it) {
        return acc + it.chars;
      }, 0);
      meta.items.forEach(function (it) {
        var row = document.createElement("div");
        var uri = document.createElement("span");
        uri.textContent = it.uri;
        var sz = document.createElement("span");
        sz.className = "sz";
        sz.textContent = "  (" + it.chars.toLocaleString() + " 字符)";
        row.appendChild(uri);
        row.appendChild(sz);
        el.metaList.appendChild(row);
      });
      el.footStat.textContent =
        "内置 " +
        meta.count +
        " 份官方元 schema，共 " +
        total.toLocaleString() +
        " 字符，全部打包进了这个页面";
    } catch (e) {
      el.metaList.textContent = "读取失败：" + e.message;
    }

    loadExample(0);
  }
})();
