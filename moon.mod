// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "ouoankang/moonbit-json-schema"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/ouoankang/moonbit-json-schema"

license = "Apache-2.0"

keywords = [
  "json",
  "jsonschema",
  "validation",
  "schema",
  "draft2020-12",
  "regex",
]

preferred_target = "wasm"

description = "JSON Schema draft 2020-12 validator: 1301/1301 official conformance tests, with a self-contained ECMA-262 regex engine and the official meta-schemas built in."
