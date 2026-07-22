/**
 * OpenAI-compatible proxy → xbreed HVM Gemma lane.
 *
 * Path:  HTTP /v1/*  →  gemma-hvm | xbreed ask gemma  →  Bend → HVM2 → Ollama
 * Prefix: g-  (xask gemma / xbreed ask gemma)
 */

const PORT = Number(process.env.XBREED_HVM_PORT ?? 11435);
const HOST = process.env.XBREED_HVM_HOST ?? "127.0.0.1";
const GEMMA_BIN = process.env.HVM_GEMMA_BIN ?? "gemma-hvm";
const DEFAULT_MODEL = process.env.HVM_GEMMA_MODEL ?? "gemma4:26b";
const USE_XBREED = (process.env.XBREED_HVM_VIA ?? "gemma-hvm") === "xbreed";
const TIMEOUT_MS = Number(process.env.XASK_TIMEOUT_SECS ?? 600) * 1000;
const BEARER = process.env.XBREED_HVM_API_KEY ?? "xbreed-hvm";

const MODEL_CATALOG = [
  "gemma4:26b",
  "gemma4-hvm:official-q4",
  "gemma4:12b",
  "gemma4:e4b",
  "gemma4:26b-hvm", // alias → gemma4:26b
] as const;

type ChatMessage = {
  role?: string;
  content?: string | Array<{ type?: string; text?: string }>;
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
  if (!h) return true; // local default: no key required
  const token = h.replace(/^Bearer\s+/i, "").trim();
  return token === BEARER || token === "ollama" || token === "xbreed-hvm";
}

function contentToText(content: ChatMessage["content"]): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => (typeof p?.text === "string" ? p.text : ""))
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function messagesToPrompt(messages: ChatMessage[]): string {
  const parts: string[] = [];
  for (const m of messages) {
    const role = (m.role ?? "user").toLowerCase();
    const text = contentToText(m.content).trim();
    if (!text) continue;
    if (role === "system") parts.push(`# System\n${text}`);
    else if (role === "assistant") parts.push(`# Assistant\n${text}`);
    else parts.push(`# User\n${text}`);
  }
  parts.push("# Assistant");
  return parts.join("\n\n");
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

function resolveModel(requested?: string): string {
  const m = (requested ?? DEFAULT_MODEL).trim() || DEFAULT_MODEL;
  if (m === "gemma4:26b-hvm" || m === "xbreed-gemma" || m === "g-gemma") {
    return DEFAULT_MODEL;
  }
  return m;
}

async function runThroughHvm(prompt: string, model: string): Promise<string> {
  const env = {
    ...process.env,
    HVM_GEMMA_MODEL: model,
  };

  const proc = USE_XBREED
    ? Bun.spawn(
        ["xbreed", "ask", "gemma", "--with", "godspeed", prompt],
        { env, stdout: "pipe", stderr: "pipe" },
      )
    : Bun.spawn([GEMMA_BIN, prompt], {
        env,
        stdout: "pipe",
        stderr: "pipe",
      });

  const timer = setTimeout(() => {
    try {
      proc.kill();
    } catch {
      /* ignore */
    }
  }, TIMEOUT_MS);

  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);

  if (code !== 0) {
    const err = stderr.trim() || stdout.trim() || `exit ${code}`;
    throw new Error(`HVM gemma failed: ${err}`);
  }
  return stripHvmStats(stdout);
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

function chatResponse(model: string, content: string) {
  const id = `chatcmpl-hvm-${crypto.randomUUID().slice(0, 8)}`;
  return {
    id,
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
    usage: {
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
    },
  };
}

function textResponse(model: string, content: string) {
  return {
    id: `cmpl-hvm-${crypto.randomUUID().slice(0, 8)}`,
    object: "text_completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, text: content, finish_reason: "stop" }],
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
        transport: USE_XBREED ? "xbreed ask gemma" : GEMMA_BIN,
        default_model: DEFAULT_MODEL,
        port: PORT,
      });
    }

    if (!authOk(req)) {
      return json({ error: { message: "Unauthorized", type: "auth" } }, 401);
    }

    if (req.method === "GET" && (path === "/v1/models" || path === "/models")) {
      return json(modelsList());
    }

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
              message:
                "stream=true not supported; use stream=false (HVM is non-streaming)",
              type: "invalid_request_error",
            },
          },
          400,
        );
      }

      const model = resolveModel(body.model);
      const prompt =
        body.messages && body.messages.length
          ? messagesToPrompt(body.messages)
          : String(body.prompt ?? "").trim();

      if (!prompt) {
        return json({ error: { message: "messages or prompt required" } }, 400);
      }

      try {
        const content = await runThroughHvm(prompt, model);
        return json(chatResponse(model, content || "(empty HVM response)"));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return json({ error: { message: msg, type: "hvm_error" } }, 502);
      }
    }

    if (
      req.method === "POST" &&
      (path === "/v1/completions" || path === "/completions")
    ) {
      let body: { model?: string; prompt?: string | string[]; stream?: boolean };
      try {
        body = (await req.json()) as typeof body;
      } catch {
        return json({ error: { message: "invalid JSON body" } }, 400);
      }
      if (body.stream) {
        return json(
          { error: { message: "stream not supported on HVM proxy" } },
          400,
        );
      }
      const model = resolveModel(body.model);
      const prompt = Array.isArray(body.prompt)
        ? body.prompt.join("\n")
        : String(body.prompt ?? "").trim();
      if (!prompt) {
        return json({ error: { message: "prompt required" } }, 400);
      }
      try {
        const content = await runThroughHvm(prompt, model);
        return json(textResponse(model, content));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return json({ error: { message: msg, type: "hvm_error" } }, 502);
      }
    }

    return json({ error: { message: `not found: ${path}` } }, 404);
  },
});

console.log(
  `xbreed-hvm-proxy listening on http://${server.hostname}:${server.port}/v1`,
);
console.log(
  `  transport=${USE_XBREED ? "xbreed ask gemma" : GEMMA_BIN} model=${DEFAULT_MODEL}`,
);
