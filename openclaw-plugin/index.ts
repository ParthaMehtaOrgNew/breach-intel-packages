/**
 * Breach Intel — OpenClaw Plugin
 *
 * Registers two tools into any OpenClaw agent:
 *   - breach_emit: send any event to the policy agent for classification
 *   - breach_query: query the breach log
 *
 * Configuration (openclaw.json or environment):
 *   plugins.breach-intel.policyAgentUrl  — URL of the policy agent (default: http://localhost:8080)
 *   plugins.breach-intel.agentId         — this agent's registered ID
 *   plugins.breach-intel.apiToken        — optional bearer token
 *   plugins.breach-intel.vertical        — domain vertical (default: fintech)
 *   plugins.breach-intel.tenantId        — optional default tenant ID
 *   plugins.breach-intel.silent          — if true, never surface errors to the model (default: true)
 *   plugins.breach-intel.autoWatch       — if true, passively tail the session transcript and
 *                                          auto-emit every tool_call/llm_response WITHOUT the
 *                                          agent needing to call breach_emit explicitly (default: false)
 *   plugins.breach-intel.transcriptPath  — path to the OpenClaw session transcript .jsonl file.
 *                                          Auto-detected from OPENCLAW_TRANSCRIPT_PATH env var
 *                                          if not set. Required when autoWatch=true.
 */

import * as http from "http";
import * as https from "https";
import * as fs from "fs";
import * as readline from "readline";
import { URL } from "url";
import { randomUUID } from "crypto";

// ─── Config ──────────────────────────────────────────────────────────────────

interface PluginConfig {
  policyAgentUrl: string;
  agentId: string;
  apiToken: string;
  vertical: string;
  tenantId: string;
  silent: boolean;
  autoWatch: boolean;
  transcriptPath: string;
}

function autoAgentId(): string {
  const hostname = require("os").hostname() || "unknown";
  return `openclaw-${hostname}-${process.pid}`;
}

function loadConfig(pluginCfg: Record<string, unknown> = {}): PluginConfig {
  return {
    policyAgentUrl:
      (pluginCfg.policyAgentUrl as string) ||
      process.env.BREACH_INTEL_URL ||
      "http://localhost:8080",
    agentId:
      (pluginCfg.agentId as string) ||
      process.env.BREACH_INTEL_AGENT_ID ||
      autoAgentId(),
    apiToken:
      (pluginCfg.apiToken as string) ||
      process.env.BREACH_INTEL_TOKEN ||
      "",
    vertical:
      (pluginCfg.vertical as string) ||
      process.env.BREACH_INTEL_VERTICAL ||
      "fintech",
    tenantId:
      (pluginCfg.tenantId as string) ||
      process.env.BREACH_INTEL_TENANT_ID ||
      "",
    silent:
      pluginCfg.silent !== undefined
        ? Boolean(pluginCfg.silent)
        : process.env.BREACH_INTEL_SILENT !== "false",
    autoWatch:
      pluginCfg.autoWatch !== undefined
        ? Boolean(pluginCfg.autoWatch)
        : process.env.BREACH_INTEL_AUTO_WATCH === "true",
    transcriptPath:
      (pluginCfg.transcriptPath as string) ||
      process.env.OPENCLAW_TRANSCRIPT_PATH ||
      "",
  };
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

function httpRequest(
  method: "GET" | "POST",
  url: string,
  body: unknown,
  token: string
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const isHttps = parsed.protocol === "https:";
    const lib = isHttps ? https : http;

    const bodyStr = body ? JSON.stringify(body) : "";
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Accept: "application/json",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;
    if (bodyStr) headers["Content-Length"] = Buffer.byteLength(bodyStr).toString();

    const req = lib.request(
      {
        hostname: parsed.hostname,
        port: parsed.port || (isHttps ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method,
        headers,
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          try {
            resolve(JSON.parse(data));
          } catch {
            resolve(data);
          }
        });
      }
    );

    req.on("error", reject);
    req.setTimeout(5000, () => {
      req.destroy(new Error("Request timeout"));
    });

    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

// ─── Passive transcript watcher ───────────────────────────────────────────────

/**
 * Tails an OpenClaw session transcript (.jsonl) and auto-emits every tool_call
 * and llm_response to the Policy Agent without the LLM needing to call
 * breach_emit explicitly.
 *
 * How it works:
 *   OpenClaw appends newline-delimited JSON entries to the transcript file as
 *   the session progresses. This watcher tracks the byte offset it has already
 *   read, wakes up on fs.watch() events, reads only new lines, and for each
 *   tool_call / llm_response entry posts an event to the Policy Agent.
 *
 * This is purely passive — zero LLM overhead, zero model token cost.
 */
async function startTranscriptWatcher(config: PluginConfig): Promise<void> {
  const transcriptPath = config.transcriptPath;

  if (!transcriptPath) {
    console.warn(
      "[breach-intel] autoWatch=true but no transcriptPath configured. " +
      "Set plugins.breach-intel.transcriptPath or OPENCLAW_TRANSCRIPT_PATH."
    );
    return;
  }

  if (!fs.existsSync(transcriptPath)) {
    console.warn(
      `[breach-intel] autoWatch: transcript not found at ${transcriptPath} — will retry when it appears.`
    );
    // Wait for the file to be created (e.g. session just starting)
    await waitForFile(transcriptPath, 30_000);
    if (!fs.existsSync(transcriptPath)) return;
  }

  let fileOffset = 0;
  let processing = false;

  async function processNewLines(): Promise<void> {
    if (processing) return;
    processing = true;
    try {
      const stat = fs.statSync(transcriptPath);
      if (stat.size <= fileOffset) return;

      await new Promise<void>((resolve, reject) => {
        const stream = fs.createReadStream(transcriptPath, {
          start: fileOffset,
          end: stat.size - 1,
          encoding: "utf8",
        });
        const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

        rl.on("line", (line) => {
          if (!line.trim()) return;
          try {
            const entry = JSON.parse(line);
            if (entry.type === "message") {
              handleTranscriptMessage(entry, config);
            }
          } catch {
            // Malformed line — skip silently
          }
        });

        rl.on("close", resolve);
        rl.on("error", reject);
      });

      fileOffset = stat.size;
    } catch (err) {
      if (!config.silent) {
        console.error("[breach-intel] autoWatch read error:", err);
      }
    } finally {
      processing = false;
    }
  }

  // Initial pass — catch up on anything already in the file
  await processNewLines();

  // Watch for new appends
  fs.watch(transcriptPath, (_event) => {
    processNewLines().catch(() => {});
  });

  console.log(`[breach-intel] autoWatch active — tailing ${transcriptPath}`);
}

function handleTranscriptMessage(entry: any, config: PluginConfig): void {
  const msg = entry.message;
  if (!msg || msg.role !== "assistant") return;

  const content = msg.content;
  if (!Array.isArray(content)) return;

  for (const item of content) {
    if (item.type === "toolCall") {
      // Auto-emit tool_call
      const event = buildEvent("tool_call", {
        tool: item.name,
        args: item.arguments || {},
      }, config);
      silentPost(event, config);
    } else if (item.type === "text" && item.text && item.text.length > 0) {
      // Auto-emit llm_response for non-trivial text
      if (item.text.trim().length > 20) {
        const event = buildEvent("llm_response", { text: item.text }, config);
        silentPost(event, config);
      }
    }
  }
}

function buildEvent(
  eventType: string,
  payload: Record<string, unknown>,
  config: PluginConfig
): Record<string, unknown> {
  return {
    event_id: randomUUID(),
    agent_id: config.agentId,
    vertical: config.vertical,
    event_type: eventType,
    payload,
    tenant_id: config.tenantId || undefined,
    timestamp: new Date().toISOString(),
    context: { source: "openclaw-autowatch" },
  };
}

let _serverReachable = true;
let _retryTimer: ReturnType<typeof setTimeout> | null = null;

function silentPost(event: Record<string, unknown>, config: PluginConfig): void {
  if (!_serverReachable && _retryTimer) return; // skip while in backoff

  httpRequest("POST", `${config.policyAgentUrl}/events`, event, config.apiToken)
    .then(() => {
      if (!_serverReachable) {
        _serverReachable = true;
        console.log("[breach-intel] policy agent reconnected");
      }
    })
    .catch((err) => {
      if (_serverReachable) {
        _serverReachable = false;
        console.warn(
          `[breach-intel] policy agent unreachable (${err.message}) — will retry every 30s`
        );
        // Retry health check every 30s
        _retryTimer = setInterval(async () => {
          try {
            await httpRequest("GET", `${config.policyAgentUrl}/health`, null, "");
            _serverReachable = true;
            if (_retryTimer) { clearInterval(_retryTimer); _retryTimer = null; }
            console.log("[breach-intel] policy agent reconnected");
          } catch { /* still down */ }
        }, 30_000);
      }
    });
}

function waitForFile(filePath: string, timeoutMs: number): Promise<void> {
  return new Promise((resolve) => {
    const start = Date.now();
    const interval = setInterval(() => {
      if (fs.existsSync(filePath) || Date.now() - start > timeoutMs) {
        clearInterval(interval);
        resolve();
      }
    }, 1000);
  });
}


// ─── Plugin entry point ───────────────────────────────────────────────────────

export default function breachIntelPlugin(pluginCfg: Record<string, unknown>) {
  const config = loadConfig(pluginCfg);

  // ─── Tool: breach_emit ────────────────────────────────────────────────────

  async function breach_emit(args: {
    event_type: string;
    payload: Record<string, unknown>;
    tenant_id?: string;
  }): Promise<string> {
    const event = {
      event_id: randomUUID(),
      agent_id: config.agentId,
      vertical: config.vertical,
      event_type: args.event_type,
      payload: args.payload,
      tenant_id: args.tenant_id || config.tenantId || undefined,
      timestamp: new Date().toISOString(),
    };

    try {
      const result = await httpRequest(
        "POST",
        `${config.policyAgentUrl}/events`,
        event,
        config.apiToken
      );
      return JSON.stringify(result);
    } catch (err) {
      const msg = `breach-intel: emit failed — ${(err as Error).message}`;
      if (config.silent) return JSON.stringify({ error: msg, is_breach: false });
      throw new Error(msg);
    }
  }

  // ─── Tool: breach_query ───────────────────────────────────────────────────

  async function breach_query(args: {
    action: "list" | "summary" | "get";
    breach_id?: string;
    severity?: string;
    limit?: number;
  }): Promise<string> {
    try {
      let url: string;
      if (args.action === "summary") {
        url = `${config.policyAgentUrl}/summary`;
      } else if (args.action === "get") {
        if (!args.breach_id) throw new Error("breach_id required for action=get");
        url = `${config.policyAgentUrl}/breaches/${args.breach_id}`;
      } else {
        // list
        const params = new URLSearchParams();
        if (config.agentId) params.set("agent_id", config.agentId);
        if (args.severity) params.set("severity", args.severity);
        params.set("limit", String(args.limit || 10));
        url = `${config.policyAgentUrl}/breaches?${params}`;
      }

      const result = await httpRequest("GET", url, null, config.apiToken);
      return JSON.stringify(result);
    } catch (err) {
      const msg = `breach-intel: query failed — ${(err as Error).message}`;
      if (config.silent) return JSON.stringify({ error: msg });
      throw new Error(msg);
    }
  }

  // ─── Auto-watch (passive instrumentation) ────────────────────────────────

  console.log(`[breach-intel] agent_id=${config.agentId} vertical=${config.vertical} autoWatch=${config.autoWatch}`);

  if (config.autoWatch) {
    // Fire-and-forget — watcher runs in background, never blocks the agent
    startTranscriptWatcher(config).catch((err) => {
      if (!config.silent) console.error("[breach-intel] autoWatch failed to start:", err);
    });
  }

  // ─── Return tool map ──────────────────────────────────────────────────────

  return {
    breach_emit,
    breach_query,
  };
}
