// 演示用的示例数据。
//
// 单独成一个文件，是为了让 scripts/web-examples-check.mjs 能在 Node 里
// 直接加载并对每条示例跑一遍断言。示例一旦和实现的真实行为脱节，
// 页面就会开始「演示一个不存在的功能」——那种错误光靠肉眼看是发现不了的。
//
// 每条示例都带 `expect`，描述它应该产生什么结果。改示例就得同步改期望值，
// 改不动就说明预期本身站不住。

(function (root) {
  "use strict";

  var EXAMPLES = [
    {
      name: "人物档案 · 应该通过",
      note: "覆盖 $defs/$ref、patternProperties、unevaluatedProperties、pattern、enum、uniqueItems。",
      expect: { action: "validate", status: "ok" },
      schema: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        $id: "https://example.com/person.schema.json",
        title: "人物档案",
        type: "object",
        required: ["name", "age"],
        properties: {
          name: { type: "string", minLength: 1, maxLength: 64 },
          age: { type: "integer", minimum: 0, maximum: 150 },
          email: { type: "string", format: "email" },
          tags: {
            type: "array",
            items: { type: "string" },
            uniqueItems: true,
            minItems: 1
          },
          address: { $ref: "#/$defs/address" },
          friends: {
            type: "array",
            items: { $ref: "#/$defs/friend" },
            maxItems: 20
          },
          role: { $ref: "#/$defs/role" }
        },
        patternProperties: {
          "^x-": { type: "string" }
        },
        unevaluatedProperties: false,
        $defs: {
          address: {
            type: "object",
            required: ["city"],
            properties: {
              city: { type: "string" },
              postcode: { type: "string", pattern: "^[0-9]{6}$" }
            },
            unevaluatedProperties: false
          },
          friend: {
            type: "object",
            required: ["name"],
            properties: {
              name: { type: "string" },
              since: { type: "integer", minimum: 1900 }
            }
          },
          role: { enum: ["admin", "editor", "viewer"] }
        }
      },
      instance: {
        name: "张三",
        age: 34,
        email: "zhangsan@example.com",
        tags: ["前端", "骑行"],
        role: "editor",
        "x-source": "手工录入",
        address: { city: "杭州", postcode: "310000" },
        friends: [
          { name: "李四", since: 2015 },
          { name: "王五" }
        ]
      }
    },

    {
      name: "人物档案 · 应该不通过",
      note: "同一份 schema，换成一份有问题的数据。7 处错误分别来自不同关键字。",
      expect: { action: "validate", status: "invalid", count: 7 },
      reuseSchemaFrom: 0,
      instance: {
        name: "",
        age: -3,
        tags: ["重复", "重复"],
        role: "superuser",
        nickname: "这个属性没在 schema 里声明",
        address: { city: "上海", postcode: "31" },
        friends: [{ since: 2015 }]
      }
    },

    {
      name: "类型协商 · 应该通过",
      note: "anyOf 的两个分支加同一层 properties。unevaluatedProperties: false 之所以不误杀 radius，正是因为注解会从通过的分支冒泡上来。",
      expect: { action: "validate", status: "ok" },
      schema: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        type: "object",
        required: ["kind"],
        properties: { kind: { type: "string" } },
        anyOf: [
          {
            properties: {
              kind: { const: "circle" },
              radius: { type: "number", exclusiveMinimum: 0 }
            },
            required: ["radius"]
          },
          {
            properties: {
              kind: { const: "rect" },
              w: { type: "number", exclusiveMinimum: 0 },
              h: { type: "number", exclusiveMinimum: 0 }
            },
            required: ["w", "h"]
          }
        ],
        unevaluatedProperties: false
      },
      instance: { kind: "circle", radius: 1.5 }
    },

    {
      name: "类型协商 · 混入未声明属性",
      note: "同样合法的一行数据，只多了一个 extra。它不属于任何一个分支，被 unevaluatedProperties 拦下。注意「关键字」一栏显示的是 false —— 因为这条规则写的就是布尔 false 本身，规则位置看第 4 列。",
      expect: {
        action: "validate",
        status: "invalid",
        count: 1,
        instancePath: "/extra",
        keyword: "false"
      },
      reuseSchemaFrom: 2,
      instance: { kind: "rect", w: 3, h: 4, extra: true }
    },

    {
      name: "递归结构 · 应该通过",
      note: "$dynamicRef 指回本文档的 $dynamicAnchor，自引用能正常收敛（环判据带上了文档 base，不会误判成死循环）。",
      expect: { action: "validate", status: "ok" },
      schema: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        $id: "https://example.com/tree",
        $dynamicAnchor: "node",
        type: "object",
        required: ["name"],
        properties: {
          name: { type: "string", minLength: 1 },
          children: {
            type: "array",
            items: { $dynamicRef: "#node" },
            maxItems: 5
          }
        },
        unevaluatedProperties: false
      },
      instance: {
        name: "根",
        children: [
          { name: "甲" },
          {
            name: "乙",
            children: [{ name: "乙-1" }]
          }
        ]
      }
    },

    {
      name: "递归结构 · 深层出错",
      note: "错误位置是 /children/1/children/0/name —— 路径一路带到底，说明递归求值没有在某一层丢掉上下文。",
      expect: {
        action: "validate",
        status: "invalid",
        count: 1,
        instancePath: "/children/1/children/0/name"
      },
      reuseSchemaFrom: 4,
      instance: {
        name: "根",
        children: [{ name: "甲" }, { name: "乙", children: [{ name: "" }] }]
      }
    },

    {
      name: "写错的 schema（用「用元 schema 检查」）",
      note: "注意：点「校验实例」不会告诉你 schema 写错了，它只会给出一堆误导性的结论。切到「用元 schema 检查 schema」才会指出真正的问题。",
      expect: { action: "lint", status: "invalid", count: 4 },
      preferLint: true,
      schema: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        title: "一份写错了的 schema —— 用来演示 lint",
        type: "object",
        properties: {
          age: { type: "sting", minimum: -5 },
          score: { type: "number", exclusiveMaximum: 0 },
          level: { enum: "low" }
        },
        required: "age",
        minLength: -1,
        pattern: "^(abc]"
      },
      instance: { age: 30 }
    }
  ];

  // 解析「复用前面某份 schema」的引用，省得复制粘贴。
  EXAMPLES.forEach(function (ex) {
    if (!ex.schema && typeof ex.reuseSchemaFrom === "number") {
      ex.schema = EXAMPLES[ex.reuseSchemaFrom].schema;
    }
  });

  root.JSON_SCHEMA_DEMO_EXAMPLES = EXAMPLES;

  // 让 Node 也能 require 到（页面里没有 module，这段会被跳过）。
  if (typeof module !== "undefined" && module.exports) {
    module.exports = EXAMPLES;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
