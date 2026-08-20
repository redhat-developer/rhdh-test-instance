const http = require("http");
const { URL } = require("url");

const UPSTREAM = process.env.OSL_DI_UPSTREAM || "http://sonataflow-platform-data-index-service.orchestrator.svc.cluster.local";
const PORT = Number(process.env.PORT || 8080);

function originFromEndpoint(endpoint) {
  try {
    return new URL(endpoint).origin;
  } catch {
    return null;
  }
}

function rewritePayload(obj) {
  const defs = obj && obj.data && obj.data.ProcessDefinitions;
  if (!Array.isArray(defs)) return;
  for (const def of defs) {
    if (!def || !def.endpoint) continue;
    const origin = originFromEndpoint(def.endpoint);
    if (origin) def.serviceUrl = origin;
  }
}

function augmentQuery(query) {
  if (typeof query !== "string") return query;
  if (!query.includes("ProcessDefinitions") || !query.includes("serviceUrl")) return query;
  if (/\bProcessDefinitions\s*\{[^}]*\bendpoint\b/.test(query)) return query;
  return query.replace(
    /ProcessDefinitions(\s*\{[^}]*\bserviceUrl\b)/,
    "ProcessDefinitions$1 endpoint",
  );
}

function proxy(req, res) {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body = Buffer.concat(chunks);
    const contentType = req.headers["content-type"] || "";
    if (contentType.includes("json") && body.length) {
      try {
        const parsed = JSON.parse(body.toString("utf8"));
        if (parsed && parsed.query) {
          parsed.query = augmentQuery(parsed.query);
          body = Buffer.from(JSON.stringify(parsed));
        }
      } catch (_err) {
        /* forward unmodified */
      }
    } else if (body.length && contentType.includes("graphql")) {
      const q = augmentQuery(body.toString("utf8"));
      body = Buffer.from(q);
    }
    const target = new URL(req.url || "/", UPSTREAM);
    if (target.searchParams.has("query")) {
      target.searchParams.set("query", augmentQuery(target.searchParams.get("query") || ""));
    }
    const headers = { ...req.headers, host: target.host };
    delete headers["accept-encoding"];
    headers["content-length"] = Buffer.byteLength(body);
    const preq = http.request(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port || 80,
        path: `${target.pathname}${target.search}`,
        method: req.method,
        headers,
      },
      (pres) => {
        const out = [];
        pres.on("data", (c) => out.push(c));
        pres.on("end", () => {
          let buf = Buffer.concat(out);
          const ct = pres.headers["content-type"] || "";
          if (ct.includes("json") && buf.length) {
            try {
              const parsed = JSON.parse(buf.toString("utf8"));
              rewritePayload(parsed);
              buf = Buffer.from(JSON.stringify(parsed));
            } catch (_err) {
              /* forward unmodified */
            }
          }
          const hdrs = { ...pres.headers, "content-length": Buffer.byteLength(buf) };
          delete hdrs["content-encoding"];
          delete hdrs["transfer-encoding"];
          res.writeHead(pres.statusCode || 502, hdrs);
          res.end(buf);
        });
      },
    );
    preq.on("error", (err) => {
      res.writeHead(502, { "content-type": "text/plain" });
      res.end(String(err));
    });
    preq.end(body.length ? body : undefined);
  });
}

http.createServer(proxy).listen(PORT, "0.0.0.0", () => {
  console.log(`osl-di-rewrite listening on ${PORT} -> ${UPSTREAM}`);
});
