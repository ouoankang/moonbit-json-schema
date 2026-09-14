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

name = "ouoankang/moonbit-regex"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/ouoankang/moonbit-regex"

license = "Apache-2.0"

keywords = [ "regex", "regexp", "ecma-262", "ecmascript", "unicode", "pattern" ]

preferred_target = "wasm"

description = "A strict ECMA-262 regular expression engine for MoonBit, cross-backend consistent (wasm/js/native), validated against test262 conformance tests."
