import { appendFile } from "node:fs/promises";

const upstream = process.env.UPSTREAM ?? "http://127.0.0.1:11434";
const output = process.env.METRICS_FILE ?? "/tmp/hvm-1000-metrics.jsonl";
const port = Number(process.env.PROXY_PORT ?? "11437");

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const requestBytes = request.method === "GET" || request.method === "HEAD"
      ? undefined
      : await request.arrayBuffer();
    const response = await fetch(upstream + url.pathname + url.search, {
      method: request.method,
      headers: request.headers,
      body: requestBytes,
    });
    const responseBytes = await response.arrayBuffer();
    if (url.pathname === "/api/generate" && response.ok && requestBytes) {
      try {
        const input = JSON.parse(new TextDecoder().decode(requestBytes));
        const result = JSON.parse(new TextDecoder().decode(responseBytes));
        const match = /^\[Q(\d{4})\]/.exec(String(input.prompt ?? ""));
        await appendFile(output, JSON.stringify({
          id: match ? Number(match[1]) : null,
          eval_count: result.eval_count,
          eval_duration: result.eval_duration,
          prompt_eval_count: result.prompt_eval_count,
          prompt_eval_duration: result.prompt_eval_duration,
          total_duration: result.total_duration,
          load_duration: result.load_duration,
          response_chars: String(result.response ?? "").length,
        }) + "\n");
      } catch (error) {
        await appendFile(output, JSON.stringify({error: String(error)}) + "\n");
      }
    }
    return new Response(responseBytes, {status: response.status, headers: response.headers});
  },
});
