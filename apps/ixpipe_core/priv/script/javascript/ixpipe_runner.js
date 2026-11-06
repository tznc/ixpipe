'use strict';
// Runs a Script tool's JavaScript code: unsandboxed, in the user's Node.
//
// `inputs` maps each input to rows (an array of objects) or, with the
// parquet format, to its Parquet file. The script assigns `output` (an
// array of objects or an object of column arrays), or returns it. It runs
// in an async function, so `await` works.
const fs = require('fs');
const util = require('util');
const vm = require('vm');

const SCRIPT = 'script.js';
const MAX_TEXT = 1000000;

const read = (path) =>
  fs.readFileSync(path, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));

const text = (args) => args.map((a) => (typeof a === 'string' ? a : util.inspect(a))).join(' ') + '\n';

function write(output, path, format) {
  if (output === undefined) {
    if (format === 'parquet' && fs.existsSync(path)) return { format: 'parquet' };
    return { missing: true };
  }
  let rows;
  let columns;
  if (Array.isArray(output)) {
    const bad = output.find((r) => r === null || typeof r !== 'object' || Array.isArray(r));
    if (bad !== undefined) return { bad: `output is an array of ${typeof bad}, not of objects` };
    rows = output;
    columns = [...new Set(rows.flatMap((r) => Object.keys(r)))];
  } else if (output !== null && typeof output === 'object') {
    columns = Object.keys(output);
    const values = columns.map((c) => Array.from(output[c]));
    if (new Set(values.map((v) => v.length)).size > 1) return { bad: "output's columns have different lengths" };
    rows = (values[0] || []).map((_, i) => Object.fromEntries(columns.map((c, j) => [c, values[j][i]])));
  } else {
    return { bad: `output is a ${typeof output}` };
  }
  fs.writeFileSync(path, rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
  return { format: 'jsonl', columns, rows: rows.length };
}

function failure(e) {
  const stack = String((e && e.stack) || e);
  const match = stack.match(/script\.js:(\d+)/);
  return {
    type: (e && e.name) || 'Error',
    message: String((e && e.message) || e),
    line: match ? Number(match[1]) : null,
    traceback: stack.slice(0, MAX_TEXT),
  };
}

async function run(code, inputs, outputPath, format) {
  const stdout = [];
  const stderr = [];
  const log = (...args) => stdout.push(text(args));
  const warn = (...args) => stderr.push(text(args));
  const result = { stdout: '', stderr: '', error: null, written: null };
  try {
    const data = {};
    for (const [name, path] of Object.entries(inputs)) data[name] = format === 'parquet' ? path : read(path);
    const context = vm.createContext({
      ...globalThis,
      require,
      process,
      Buffer,
      console: { log, info: log, debug: log, warn, error: warn },
      inputs: data,
      outputPath,
      output: undefined,
    });
    // The wrapper's first line is not the script's: line numbers stay true.
    const script = new vm.Script(`(async () => {\n${code}\n})()`, { filename: SCRIPT, lineOffset: -1 });
    const returned = await script.runInContext(context);
    result.written = write(context.output !== undefined ? context.output : returned, outputPath, format);
  } catch (e) {
    result.error = failure(e);
  }
  result.stdout = stdout.join('').slice(0, MAX_TEXT);
  result.stderr = stderr.join('').slice(0, MAX_TEXT);
  return result;
}

module.exports = { run };
