// Model.js is a QML JavaScript module: it declares functions but has no
// module.exports, so require() returns an empty object. Evaluate it and call
// the function directly instead. Objects come back as JSON so the shell side
// can assert on fields with jq.
//   node tests/eval-model.js <path-to-Model.js> <fn> <json-arg> [json-arg...]
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
eval(src);
const fn = eval(process.argv[3]);
const args = process.argv.slice(4).map(a => (a === "undefined" ? undefined : JSON.parse(a)));
const out = fn.apply(null, args);
process.stdout.write(out !== null && typeof out === "object" ? JSON.stringify(out) : String(out));
