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

description = "Strict ECMA-262 regular expression engine for MoonBit (cross-backend consistent), with a JSON Schema 2020-12 validator as its conformance testbed (1301/1301)."
