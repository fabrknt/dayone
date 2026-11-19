// A JSON-RPC proxy for keeper/e2e.sh: forwards everything to UPSTREAM, but while LOSE_FILE exists it
// forwards eth_sendRawTransaction and answers with an error, as a node that took the transaction
// and lost the reply.
//   node keeper/rpc-lossy.mjs UPSTREAM PORT LOSE_FILE
import { createServer } from "node:http";
import { existsSync } from "node:fs";
const [upstream, port, loseFile] = process.argv.slice(2);
createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", async () => {
    const up = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body });
    const text = await up.text();
    const calls = [JSON.parse(body)].flat();
    res.setHeader("content-type", "application/json");
    if (existsSync(loseFile) && calls.some((c) => c.method === "eth_sendRawTransaction")) {
      res.statusCode = 502;
      res.end("lost");
      return;
    }
    res.end(text);
  });
}).listen(Number(port), "127.0.0.1");
