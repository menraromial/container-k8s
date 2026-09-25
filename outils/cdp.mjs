// Usage : node cdp.mjs URL "expression JS"  (Chrome lancé avec --remote-debugging-port=9333)
const [url, expr] = process.argv.slice(2);
const cible = await (await fetch('http://127.0.0.1:9333/json/new?' + encodeURIComponent(url), {method: 'PUT'})).json();
const ws = new WebSocket(cible.webSocketDebuggerUrl);
let id = 0; const attente = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (attente.has(m.id)) { attente.get(m.id)(m); attente.delete(m.id); } };
const appel = (method, params = {}) => new Promise((r) => { const i = ++id; attente.set(i, r); ws.send(JSON.stringify({id: i, method, params})); });
await new Promise((r) => (ws.onopen = r));
await new Promise((r) => setTimeout(r, 4000));
const res = await appel('Runtime.evaluate', {expression: expr, returnByValue: true});
console.log(JSON.stringify(res.result.result.value ?? res.result, null, 1));
await fetch('http://127.0.0.1:9333/json/close/' + cible.id);
ws.close(); process.exit(0);
