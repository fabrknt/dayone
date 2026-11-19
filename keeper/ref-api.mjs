// A stand-in for HL's info API in keeper/e2e.sh: answers metaAndAssetCtxs with xyz:TSLA's oracle
// set to the contents of the file named on the command line.
//   node keeper/ref-api.mjs PRICE_FILE PORT
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
const [file, port] = process.argv.slice(2);
createServer((req, res) => {
  req.resume();
  req.on("end", () => {
    const px = readFileSync(file, "utf8").trim();
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify([{ universe: [{ name: "xyz:AAPL" }, { name: "xyz:TSLA" }] }, [{ oraclePx: "1" }, { oraclePx: px }]]));
  });
}).listen(Number(port), "127.0.0.1");
