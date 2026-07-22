/**
 * OpenAI-compatible proxy → xbreed HVM Gemma lane.
 *
 * Primary protocol: **Responses API** (`POST /v1/responses`) — what Codex
 * Titanium / modern agents expect (NOT Chat Completions).
 *
 * Path:  HTTP /v1/*  →  gemma-hvm  →  Bend → HVM2 → Ollama
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.XBREED_HVM_PORT ?? 11435);
const HOST = process.env.XBREED_HVM_HOST ?? "127.0.0.1";
const PROJECT_ROOT = path.dirname(fileURLToPath(import.meta.url));
const GEMMA_HVM4_RUNNER = path.resolve(PROJECT_ROOT, "..", "run-hvm4.sh");
const GEMMA_BIN = process.env.HVM_GEMMA_BIN ?? GEMMA_HVM4_RUNNER;
const DEFAULT_MODEL = process.env.HVM_GEMMA_MODEL ?? "gemma4-hvm:a4b-q4-k-m";
const XBREED_MODE = (process.env.XBREED_HVM_VIA ?? "gemma-hvm4").toLowerCase();
const USE_XBREED = XBREED_MODE === "xbreed";
const RAW_TIMEOUT_SECS = Number(process.env.XASK_TIMEOUT_SECS ?? 600);
const TIMEOUT_MS =
  Math.min(
    Math.max(Number.isFinite(RAW_TIMEOUT_SECS) && RAW_TIMEOUT_SECS > 0 ? RAW_TIMEOUT_SECS : 600, 1),
    1800,
  ) * 1000;
const BEARER = process.env.XBREED_HVM_API_KEY ?? "";
const LOOPBACK_HOST = HOST === "127.0.0.1" || HOST === "::1" || HOST === "localhost";
if (!LOOPBACK_HOST && !BEARER) {
  throw new Error("XBREED_HVM_API_KEY is required when binding outside loopback");
}

const CANONICAL_MODEL = "gemma4-hvm:a4b-q4-k-m";
const MODEL_ALIASES = new Map<string, string>([
  [CANONICAL_MODEL, CANONICAL_MODEL],
  ["gemma4:26b", CANONICAL_MODEL],
  ["gemma4:26b-hvm", CANONICAL_MODEL],
  ["gemma4-hvm:a4b-q4-k-m", CANONICAL_MODEL],
  ["gemma4-hvm:official-q4", CANONICAL_MODEL],
  ["xbreed-gemma", CANONICAL_MODEL],
  ["g-gemma", CANONICAL_MODEL],
]);
const MODEL_CATALOG = [CANONICAL_MODEL, ...MODEL_ALIASES.keys()]
  .filter((id, i, arr) => arr.indexOf(id) === i)
  .sort();

type ContentPart =
  | { type?: string; text?: string; content?: string }
  | string;

type InputItem = {
  type?: string;
  role?: string;
  content?: string | ContentPart[];
  text?: string;
};

type ChatMessage = {
  role?: string;
  content?: string | ContentPart[];
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

function authOk(req: Request): boolean {
  const h = req.headers.get("authorization") ?? "";
  if (!BEARER) return LOOPBACK_HOST && !h;
  const token = h.replace(/^Bearer\s+/i, "").trim();
  return token.length > 0 && token === BEARER;
}

function partText(p: ContentPart): string {
  if (typeof p === "string") return p;
  if (typeof p.text === "string") return p.text;
  if (typeof p.content === "string") return p.content;
  return "";
}

function contentToText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map(partText).filter(Boolean).join("\n");
  }
  return "";
}

function messagesToPrompt(
  messages: Array<{ role?: string; content?: unknown }>,
): string {
  const parts: string[] = [];
  for (const m of messages) {
    const role = (m.role ?? "user").toLowerCase();
    const text = contentToText(m.content).trim();
    if (!text) continue;
    if (role === "system" || role === "developer") parts.push(`# System\n${text}`);
    else if (role === "assistant") parts.push(`# Assistant\n${text}`);
    else parts.push(`# User\n${text}`);
  }
  parts.push("# Assistant");
  return parts.join("\n\n");
}

/** Flatten Responses API `input` (string | items) into a single HVM prompt. */
function responsesInputToPrompt(input: unknown): string {
  if (typeof input === "string") {
    return `# User\n${input.trim()}\n\n# Assistant`;
  }
  if (!Array.isArray(input)) return "";

  const messages: Array<{ role?: string; content?: unknown }> = [];
  for (const item of input as InputItem[]) {
    if (typeof item === "string") {
      messages.push({ role: "user", content: item });
      continue;
    }
    if (!item || typeof item !== "object") continue;

    // { type: "message", role, content }
    if (item.type === "message" || item.role) {
      messages.push({
        role: item.role ?? "user",
        content: item.content ?? item.text ?? "",
      });
      continue;
    }
    // { type: "input_text", text }
    if (item.type === "input_text" || item.type === "text") {
      messages.push({ role: "user", content: item.text ?? item.content ?? "" });
      continue;
    }
    // fallback
    const t = contentToText(item.content) || item.text || "";
    if (t) messages.push({ role: "user", content: t });
  }
  return messagesToPrompt(messages);
}

function stripHvmStats(stdout: string): string {
  const lines = stdout.split("\n");
  while (lines.length) {
    const t = lines[lines.length - 1]!.trim();
    if (
      !t ||
      t.startsWith("Result:") ||
      t.startsWith("- ITRS:") ||
      t.startsWith("- TIME:") ||
      t.startsWith("- MIPS:")
    ) {
      lines.pop();
      continue;
    }
    break;
  }
  return lines.join("\n").trimEnd();
}

class TimeoutError extends Error {
  constructor() {
    super("HVM runner timed out");
    this.name = "TimeoutError";
  }
}

function resolveModel(requested?: string): string {
  const requestedModel = (requested ?? DEFAULT_MODEL).trim();
  const normalized = requestedModel || CANONICAL_MODEL;
  const canonical = MODEL_ALIASES.get(normalized);
  if (!canonical) {
    throw new Error(`Unsupported model ${normalized}; allowed: ${MODEL_CATALOG.join(", ")}`);
  }
  return canonical;
}

function errorStatusFromCause(err: unknown): number {
  if (err instanceof TimeoutError) return 504;
  return 502;
}

function errorTypeFromCause(err: unknown): string {
  if (err instanceof TimeoutError) return "timeout";
  return "hvm_error";
}

async function runThroughHvm(prompt: string, model: string): Promise<string> {
  const env = { ...process.env, HVM_GEMMA_MODEL: model };

  const proc = USE_XBREED
    ? Bun.spawn(["xbreed", "ask", "gemma", "--with", "godspeed", prompt], {
        env,
        stdout: "pipe",
        stderr: "pipe",
      })
    : Bun.spawn([GEMMA_BIN, prompt], { env, stdout: "pipe", stderr: "pipe" });

  let killedByTimeout = false;
  let hardKillTimer: ReturnType<typeof setTimeout> | null = null;
  const timer = setTimeout(() => {
    killedByTimeout = true;
    try {
      proc.kill("SIGTERM");
    } catch {
      /* ignore */
    }
    hardKillTimer = setTimeout(() => {
      try {
        proc.kill("SIGKILL");
      } catch {
        /* ignore */
      }
    }, 1000);
  }, TIMEOUT_MS);

  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  if (hardKillTimer !== null) {
    clearTimeout(hardKillTimer);
  }

  if (killedByTimeout) {
    throw new TimeoutError();
  }
  if (code !== 0) {
    const err = stderr.trim() || stdout.trim() || `exit ${code}`;
    throw new Error(`HVM gemma failed: ${err}`);
  }
  const text = stripHvmStats(stdout);
  if (text.startsWith("HVM_GEMMA_ERROR:")) {
    throw new Error(text);
  }
  return text;
}

function modelsList() {
  const now = Math.floor(Date.now() / 1000);
  return {
    object: "list",
    data: MODEL_CATALOG.map((id) => ({
      id,
      object: "model",
      created: now,
      owned_by: "xbreed-hvm",
    })),
  };
}

/** OpenAI Responses API shape (Codex wire_api = "responses"). */
function responsesResponse(model: string, text: string) {
  const id = `resp_hvm_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
  const msgId = `msg_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
  return {
    id,
    object: "response",
    created_at: Math.floor(Date.now() / 1000),
    status: "completed",
    error: null,
    incomplete_details: null,
    model,
    output: [
      {
        type: "message",
        id: msgId,
        status: "completed",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text,
            annotations: [],
          },
        ],
      },
    ],
    // convenience field some clients also read
    output_text: text,
    usage: {
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
    },
  };
}

function chatResponse(model: string, content: string) {
  return {
    id: `chatcmpl-hvm-${crypto.randomUUID().slice(0, 8)}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
}

const server = Bun.serve({
  hostname: HOST,
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
          "Access-Control-Allow-Headers": "Authorization,Content-Type",
        },
      });
    }

    if (path === "/" || path === "/health") {
      return json({
        ok: true,
        service: "xbreed-hvm-proxy",
        protocol: "openai-responses (+ chat/completions fallback)",
        transport: USE_XBREED ? "xbreed ask gemma" : GEMMA_BIN,
        default_model: DEFAULT_MODEL,
        port: PORT,
        endpoints: ["/v1/responses", "/v1/models", "/v1/chat/completions"],
      });
    }

    if (!authOk(req)) {
      return json({ error: { message: "Unauthorized", type: "auth" } }, 401);
    }

    if (req.method === "GET" && (path === "/v1/models" || path === "/models")) {
      return json(modelsList());
    }

    // ── Primary: Responses API (Codex Titanium / Pi openai-responses) ──
    if (
      req.method === "POST" &&
      (path === "/v1/responses" || path === "/responses")
    ) {
      let body: {
        model?: string;
        input?: unknown;
        stream?: boolean;
        instructions?: string;
        messages?: ChatMessage[];
      };
      try {
        body = (await req.json()) as typeof body;
      } catch {
        return json({ error: { message: "invalid JSON body" } }, 400);
      }

      if (body.stream) {
        // Non-stream only for HVM; reject loud so clients don't hang.
        return json(
          {
            error: {
              message:
                "stream=true not supported on xbreed-hvm (HVM is non-streaming). Set stream=false.",
              type: "invalid_request_error",
            },
          },
          400,
        );
      }

      let model: string;
      try {
        model = resolveModel(body.model);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return json({ error: { message: msg, type: "invalid_request_error" } }, 400);
      }
      let prompt = "";
      if (body.input !== undefined && body.input !== null) {
        prompt = responsesInputToPrompt(body.input);
      } else if (body.messages?.length) {
        prompt = messagesToPrompt(body.messages);
      }
      if (body.instructions?.trim()) {
        prompt = `# System\n${body.instructions.trim()}\n\n${prompt}`;
      }
      if (!prompt.trim()) {
        return json(
          { error: { message: "input (or messages) required", type: "invalid_request_error" } },
          400,
        );
      }

      try {
        const text = await runThroughHvm(prompt, model);
        return json(responsesResponse(model, text || "(empty HVM response)"));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        const status = errorStatusFromCause(e);
        return json(
          { error: { message: msg, type: errorTypeFromCause(e) } },
          status,
        );
      }
    }

    // ── Fallback: Chat Completions (Kimi / some OpenAI-compatible clients) ──
    if (
      req.method === "POST" &&
      (path === "/v1/chat/completions" || path === "/chat/completions")
    ) {
      let body: {
        model?: string;
        messages?: ChatMessage[];
        stream?: boolean;
        prompt?: string;
      };
      try {
        body = (await req.json()) as typeof body;
      } catch {
        return json({ error: { message: "invalid JSON body" } }, 400);
      }
      if (body.stream) {
        return json(
          {
            error: {
              message: "stream not supported; use /v1/responses with stream=false",
              type: "invalid_request_error",
            },
          },
          400,
        );
      }
      let model: string;
      try {
        model = resolveModel(body.model);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return json({ error: { message: msg, type: "invalid_request_error" } }, 400);
      }
      const prompt =
        body.messages?.length
          ? messagesToPrompt(body.messages)
          : String(body.prompt ?? "").trim();
      if (!prompt) {
        return json({ error: { message: "messages required" } }, 400);
      }
      try {
        const content = await runThroughHvm(prompt, model);
        return json(chatResponse(model, content || "(empty HVM response)"));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        const status = errorStatusFromCause(e);
        return json(
          { error: { message: msg, type: errorTypeFromCause(e) } },
          status,
        );
      }
    }

    return json(
      {
        error: {
          message: `not found: ${path}. Primary endpoint is POST /v1/responses`,
        },
      },
      404,
    );
  },
});

console.log(
  `xbreed-hvm-proxy listening on http://${server.hostname}:${server.port}`,
);
console.log(`  primary: POST /v1/responses  (wire_api=responses)`);
console.log(
  `  transport=${USE_XBREED ? "xbreed ask gemma" : GEMMA_BIN} model=${DEFAULT_MODEL}`,
);
