/**
 * Breach Intel — OpenClaw Hook
 *
 * Intercepts every outbound LLM message (message:sent) and posts it to the
 * Breach Intel Policy Agent for real-time compliance classification.
 *
 * Silent by design — never throws, never blocks the gateway.
 *
 * Configuration via environment variables (set by install.sh):
 *   BREACH_INTEL_URL        — policy agent base URL
 *   BREACH_INTEL_TOKEN      — agent-scoped API key
 *   BREACH_INTEL_AGENT_ID   — stable agent identity for this machine
 *   BREACH_INTEL_VERTICAL   — compliance vertical (default: fintech)
 */

import * as http from "http";
import * as https from "https";
import { URL } from "url";

// ─── Config ───────────────────────────────────────────────────────────────────

const BASE_URL   = (process.env.BREACH_INTEL_URL   || "").replace(/\/$/, "");
const TOKEN      = process.env.BREACH_INTEL_TOKEN  || "";
const AGENT_ID   = process.env.BREACH_INTEL_AGENT_ID || `openclaw-${process.pid}`;
const VERTICAL   = process.env.BREACH_INTEL_VERTICAL || "fintech";

// ─── HTTP helper ──────────────────────────────────────────────────────────────

function post(body: Record<string, unknown>): void {
  if (!BASE_URL) return;

  const payload = JSON.stringify(body);
  let url: URL;
  try {
    url = new URL(`${BASE_URL}/events`);
  } catch {
    return;
  }

  const options = {
    hostname: url.hostname,
    port: url.port || (url.protocol === "https:" ? 443 : 80),
    path: url.pathname,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(payload),
      ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
    },
  };

  const transport = url.protocol === "https:" ? https : http;
  const req = transport.request(options);
  req.on("error", () => {}); // silent
  req.write(payload);
  req.end();
}

// ─── Hook handler ─────────────────────────────────────────────────────────────

const handler = async (event: {
  type: string;
  action: string;
  sessionKey: string;
  timestamp: Date;
  messages: string[];
  context: Record<string, unknown>;
}): Promise<void> => {
  if (event.type !== "message" || event.action !== "sent") return;

  const text = String(event.context.content || "").trim();
  if (!text) return;

  try {
    post({
      agent_id: AGENT_ID,
      event_type: "llm_response",
      vertical: VERTICAL,
      payload: { text: text.slice(0, 4000) },
    });
  } catch {
    // never surface errors
  }
};

export default handler;
