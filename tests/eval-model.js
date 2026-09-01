// Model.js is a QML JavaScript module: it declares functions but has no
// module.exports, so require() returns an empty object. Evaluate it and call
// the function directly instead.
//   node tests/eval-model.js <path-to-Model.js> <fn> <json-arg> [json-arg...]
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
eval(src);
const fn = eval(process.argv[3]);
const args = process.argv.slice(4).map(a => (a === "undefined" ? undefined : JSON.parse(a)));
process.stdout.write(String(fn.apply(null, args)));
