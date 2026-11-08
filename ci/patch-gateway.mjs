// 给上游前端打"统一网关前缀"补丁。
//
// 背景:fnOS 统一网关把页面放在 /app/<appname>/ 下,路径前缀原样保留。上游的 vite
// 配置已经是 base:"./" (静态资源是相对路径,天然兼容),但前端发请求时用的是绝对
// `/api/...`,在网关下会跑到站点根目录、绕开 /app/<appname> 前缀。
//
// 这里只给三个文件各加一行 `const BASE = ...`(从 location.pathname 里取前缀),再把
// 6 处请求地址拼上 BASE。直连 8095 时 BASE 为空串,行为与上游完全一致。
//
// 用 Node 而不是 Python:补丁在 rust:1-bookworm 构建容器里执行,那里只有 node,没有 python3。
//
// 用法: node patch-gateway.mjs <上游源码根目录>

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// `typeof location` 的判断不是多余的:http-client.ts / launcher.ts 会被 scripts/*.mjs 在
// 纯 node 里 import(上游的 check-poller / smoke 自检),那些进程里没有 location。
const DECL = `/** fnOS 统一网关下页面位于 /app/<appname>/:绝对 /api/… 会跑出前缀,这里取出来拼在路径前。 */
const BASE = typeof location === "undefined" ? "" : (/^\\/app\\/[^/]+/.exec(location.pathname) || [""])[0];

`;

// [文件, 原串, 新串] —— 原串必须唯一命中,否则报错,避免静默漏改
const EDITS = [
  ["app/src/http-client.ts", "    const res = await fetch(path, {", "    const res = await fetch(BASE + path, {"],
  ["app/src/http-client.ts", "  return `/api/edit_upload?source=", "  return BASE + `/api/edit_upload?source="],
  ["app/src/http-client.ts", "  const base = `/api/connect/upload?", "  const base = BASE + `/api/connect/upload?"],
  ["app/src/http-client.ts", "  return `/api/connect/download?path=", "  return BASE + `/api/connect/download?path="],
  ["app/src/launcher.ts", 'fetchText(d, "/api/session"', 'fetchText(d, BASE + "/api/session"'],
  ["app/src/common.tsx", 'src={props.connect ? "/api/qr?connect=1" : "/api/qr"}', 'src={BASE + (props.connect ? "/api/qr?connect=1" : "/api/qr")}'],
];

const DECL_FILES = ["app/src/http-client.ts", "app/src/launcher.ts", "app/src/common.tsx"];

/** 把 BASE 声明插在最后一条 import 之后(没有 import 就插在文件最前面)。 */
function insertDecl(text) {
  const lines = text.split("\n");
  let lastImport = -1;
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i].trimStart();
    if (s.startsWith("import ") || s.startsWith("import{")) lastImport = i;
  }
  const at = lastImport + 1;
  const head = lines.slice(0, at).join("\n");
  const tail = lines.slice(at).join("\n").replace(/^\n+/, "");
  return (head ? head + "\n\n" : "") + DECL + tail;
}

const root = process.argv[2] ?? ".";
const changed = [];

for (const [rel, oldText, newText] of EDITS) {
  const path = join(root, rel);
  const text = readFileSync(path, "utf8");
  if (text.includes(newText)) continue; // 已打过
  const n = text.split(oldText).length - 1;
  if (n !== 1) throw new Error(`补丁锚点不唯一(${n} 处): ${rel} :: ${oldText}`);
  writeFileSync(path, text.replace(oldText, newText));
  changed.push(`${rel} <- ${oldText.trim().slice(0, 48)}`);
}

for (const rel of DECL_FILES) {
  const path = join(root, rel);
  const text = readFileSync(path, "utf8");
  if (text.includes("const BASE = ")) continue;
  writeFileSync(path, insertDecl(text));
  changed.push(`${rel} <- BASE 声明`);
}

console.log(`已改动 ${changed.length} 处:`);
for (const c of changed) console.log("  " + c);
if (!changed.length) console.log("  (无改动,补丁此前已应用)");
