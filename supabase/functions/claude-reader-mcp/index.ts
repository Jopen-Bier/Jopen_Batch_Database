// claude-reader-mcp — read-only MCP server for the Jopen Batch Database.
// Used as a custom connector in the company Claude. Connector URL:
//   https://<project>.supabase.co/functions/v1/claude-reader-mcp/<token>
// or the bare URL with header "Authorization: Bearer <token>".
// Deploy with verify_jwt = false: the function checks its own tokens.
//
// Read-only is enforced three times: role claude_reader (SELECT only), READ ONLY
// transaction, and a single-SELECT check here. Every call is logged to
// claude_connector.query_log.
//
// Security phase 4 (20-11-2026):
// - Connects as the dedicated login claude_reader_login (secret READER_DB_URL),
//   which can only read active tokens, write the query log and switch to
//   claude_reader; no longer as postgres. Falls back to SUPABASE_DB_URL only
//   while READER_DB_URL is not set, and says so in the function log.
// - Tokens expire (access_tokens.expires_at); new ones come from
//   claude_connector.issue_token(). Revocation takes effect within 15 seconds.
// - Token cache, request body size and request rate per token are bounded.
// - A failed query-log write is reported in the function log.
// Source of truth is this file in the repo; deploy it from here.

import postgres from "npm:postgres@3.4.5";

const READER_DB_URL = Deno.env.get("READER_DB_URL");
if (!READER_DB_URL) {
  console.warn("claude-reader-mcp: READER_DB_URL not set, falling back to SUPABASE_DB_URL (postgres). Set READER_DB_URL.");
}

const sql = postgres((READER_DB_URL ?? Deno.env.get("SUPABASE_DB_URL"))!, {
  prepare: false,
  max: 3, // also the cap on concurrent queries per function instance
  idle_timeout: 20,
  types: {
    // numeric and bigint as JSON numbers instead of strings (friendlier for Excel)
    numeric: { to: 1700, from: [1700], serialize: (x: unknown) => String(x), parse: (x: string) => Number(x) },
    bigint: { to: 20, from: [20], serialize: (x: unknown) => String(x), parse: (x: string) => Number(x) },
  },
});

const DEFAULT_ROWS = 500;
const MAX_ROWS = 5000;
const MAX_BODY_BYTES = 256 * 1024;      // one MCP request is a few KB at most
const TOKEN_CACHE_TTL_MS = 15_000;      // revocation/expiry takes effect within this time
const TOKEN_CACHE_MAX = 100;
const RATE_LIMIT_PER_MINUTE = 120;      // per token, per function instance
const SUPPORTED_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS = `Read-only access to the Jopen Batch Database (Jopen brewery, Haarlem): recipes, ingredients, batches, brew planning, inventory and process data in Postgres schema "public". Writing is impossible; never suggest that a change was made in the database. People data (users, audit logs) is not available through this connector.
Workflow: list_tables -> describe_table for the tables you need -> query with a single SELECT.
Recipes are versioned: recipes.status 'active' = current version, 'archived' = old versions (same recipe_group_id), 'draft' = not yet released. Unless asked otherwise, report active recipes only. Most recipe_* tables are 1:1 or 1:n on recipe_id.
recipe_ingredients.addition_type is one of malt, boil_hop, dry_hop, yeast, brewhouse_addition, cellar_addition; ingredient names are in ingredients.name.
Hop timing: recipe_ingredients.timing for boil_hop is minutes before end of boil, stored as text (numeric values, occasionally text like 'mash' or 'First runnings'). Boil time of a recipe = the highest numeric timing among its boil_hop rows (there is no separate boil time column). Whirlpool hop = boil_hop rows with timing '0'; whirlpool hop amount = sum of their quantity (mind the unit column). Cast timing safely, e.g. case when timing ~ '^\\\\d+$' then timing::int end.
Select only the columns you need, give every output column a unique alias, and aggregate in SQL where possible - results are capped at ${MAX_ROWS} rows. Always include id columns (e.g. recipe_id, recipe_ingredients.id) in exports so edits can be matched back to the database.`;

const TOOLS = [
  {
    name: "list_tables",
    description: "List all readable tables and views with an approximate row count and description.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
  },
  {
    name: "describe_table",
    description: "Columns (name, type, nullable, comment), primary/unique keys and foreign keys of one table or view.",
    inputSchema: {
      type: "object",
      properties: { table: { type: "string", description: "Table or view name in schema public, e.g. recipe_ingredients" } },
      required: ["table"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "query",
    description: `Run one read-only SQL SELECT (or WITH ... SELECT) against schema public. No semicolons, one statement. Returns columns + rows as arrays. Default ${DEFAULT_ROWS} rows, max ${MAX_ROWS}; 'truncated' is true when more rows exist.`,
    inputSchema: {
      type: "object",
      properties: {
        sql: { type: "string", description: "A single SELECT statement" },
        max_rows: { type: "integer", minimum: 1, maximum: MAX_ROWS, description: `Row cap, default ${DEFAULT_ROWS}` },
      },
      required: ["sql"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
];

// ---------- auth ----------
async function sha256hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Bounded cache: hash -> token id (or null for unknown/revoked/expired).
const tokenCache = new Map<string, { id: number | null; exp: number }>();
function cachePut(hash: string, id: number | null) {
  tokenCache.delete(hash);
  while (tokenCache.size >= TOKEN_CACHE_MAX) {
    tokenCache.delete(tokenCache.keys().next().value!); // oldest entry first (insertion order)
  }
  tokenCache.set(hash, { id, exp: Date.now() + TOKEN_CACHE_TTL_MS });
}

async function resolveToken(tok: string | undefined): Promise<number | null> {
  if (!tok || tok.length < 32 || tok.length > 256) return null;
  const hash = await sha256hex(tok);
  const hit = tokenCache.get(hash);
  if (hit && hit.exp > Date.now()) return hit.id;
  const rows = await sql`
    select id from claude_connector.access_tokens
    where token_sha256 = ${hash} and revoked_at is null
      and (expires_at is null or expires_at > now())`;
  const id = rows.length ? Number(rows[0].id) : null;
  cachePut(hash, id);
  return id;
}

// Token from "Authorization: Bearer <token>", else the last URL path segment.
function tokenFrom(req: Request): string | undefined {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer\s+(\S+)$/i);
  if (m) return m[1];
  const last = new URL(req.url).pathname.split("/").filter(Boolean).pop();
  return last === "claude-reader-mcp" ? undefined : last;
}

// Fixed-window rate limit per token id (per function instance).
const rateWindows = new Map<number, { start: number; count: number }>();
function rateLimited(tokenId: number): boolean {
  const now = Date.now();
  const w = rateWindows.get(tokenId);
  if (!w || now - w.start >= 60_000) {
    rateWindows.set(tokenId, { start: now, count: 1 });
    return false;
  }
  w.count++;
  return w.count > RATE_LIMIT_PER_MINUTE;
}

// ---------- read-only execution ----------
// deno-lint-ignore no-explicit-any
async function readOnly<T>(fn: (tx: any) => Promise<T>): Promise<T> {
  // deno-lint-ignore no-explicit-any
  return await sql.begin("read only", async (tx: any) => {
    await tx`set local role claude_reader`;
    await tx`set local statement_timeout = '20s'`;
    return await fn(tx);
  }) as T;
}

type ToolResult = { text: string; rowCount?: number };

// deno-lint-ignore no-explicit-any
async function runTool(name: string, args: any): Promise<ToolResult> {
  if (name === "list_tables") {
    const rows: unknown[] = await readOnly((tx) => tx`
      select c.relname as name,
             case c.relkind when 'v' then 'view' when 'm' then 'materialized view' else 'table' end as kind,
             greatest(c.reltuples, 0)::bigint as approx_rows,
             obj_description(c.oid, 'pg_class') as description
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r','v','m','p')
        and has_table_privilege(c.oid, 'SELECT')
      order by c.relname`);
    return { text: JSON.stringify(rows), rowCount: rows.length };
  }

  if (name === "describe_table") {
    const table = String(args?.table ?? "").trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(table)) throw new Error("Invalid table name");
    const out = await readOnly(async (tx) => {
      const rel = await tx`select to_regclass(${"public." + table})::oid as oid`;
      const oid = rel[0]?.oid;
      if (!oid) throw new Error(`Unknown table or view: ${table}`);
      const columns = await tx`
        select a.attname as column, format_type(a.atttypid, a.atttypmod) as type,
               not a.attnotnull as nullable, col_description(a.attrelid, a.attnum) as comment
        from pg_attribute a
        where a.attrelid = ${oid} and a.attnum > 0 and not a.attisdropped
        order by a.attnum`;
      const constraints = await tx`
        select conname as name, case contype when 'p' then 'primary key' when 'u' then 'unique' else 'foreign key' end as kind,
               pg_get_constraintdef(oid) as definition
        from pg_constraint where conrelid = ${oid} and contype in ('p','u','f')
        order by contype, conname`;
      const desc = await tx`select obj_description(${oid}::oid, 'pg_class') as d`;
      return { table, description: desc[0]?.d ?? null, columns, constraints };
    });
    return { text: JSON.stringify(out), rowCount: out.columns.length };
  }

  if (name === "query") {
    let q = String(args?.sql ?? "").trim().replace(/;\s*$/, "").trim();
    if (!q) throw new Error("Empty query");
    if (q.includes(";")) throw new Error("Only one statement allowed (no semicolons).");
    if (!/^(select|with)\b/i.test(q)) throw new Error("Only SELECT or WITH ... SELECT queries are allowed.");
    const limit = Math.min(Math.max(parseInt(args?.max_rows ?? DEFAULT_ROWS, 10) || DEFAULT_ROWS, 1), MAX_ROWS);
    const res = await readOnly((tx) => tx.unsafe(`select * from (\n${q}\n) as _q limit ${limit + 1}`).values());
    // deno-lint-ignore no-explicit-any
    const columns = ((res as any).columns ?? []).map((c: any) => c.name);
    const rows = (res as unknown[]).slice(0, limit);
    return {
      text: JSON.stringify({ columns, rows, row_count: rows.length, truncated: (res as unknown[]).length > limit }),
      rowCount: rows.length,
    };
  }

  throw new Error(`Unknown tool: ${name}`);
}

async function callTool(name: string, args: unknown, tokenId: number) {
  const t0 = Date.now();
  let rowCount: number | null = null;
  let error: string | null = null;
  let result;
  try {
    const r = await runTool(name, args);
    rowCount = r.rowCount ?? null;
    result = { content: [{ type: "text", text: r.text }] };
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
    result = { content: [{ type: "text", text: `Error: ${error}` }], isError: true };
  }
  try {
    await sql`insert into claude_connector.query_log (token_id, tool, arguments, row_count, duration_ms, error)
              values (${tokenId}, ${name}, ${sql.json((args ?? {}) as never)}, ${rowCount}, ${Date.now() - t0}, ${error})`;
  } catch (e) {
    // Never break a query over logging, but make the gap visible in the function log.
    console.error("claude-reader-mcp: query_log insert failed:", e instanceof Error ? e.message : String(e));
  }
  return result;
}

// ---------- JSON-RPC / MCP (Streamable HTTP, stateless, JSON responses) ----------
// deno-lint-ignore no-explicit-any
async function handle(msg: any, tokenId: number) {
  const isNotification = msg?.id === undefined || msg?.id === null;
  const reply = (body: object) => (isNotification ? null : { jsonrpc: "2.0", id: msg.id, ...body });
  try {
    switch (msg?.method) {
      case "initialize": {
        const asked = msg.params?.protocolVersion;
        return reply({
          result: {
            protocolVersion: SUPPORTED_VERSIONS.includes(asked) ? asked : SUPPORTED_VERSIONS[0],
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: "jopen-batch-db-reader", version: "1.1.0" },
            instructions: INSTRUCTIONS,
          },
        });
      }
      case "ping":
        return reply({ result: {} });
      case "tools/list":
        return reply({ result: { tools: TOOLS } });
      case "tools/call":
        return reply({ result: await callTool(msg.params?.name, msg.params?.arguments ?? {}, tokenId) });
      default:
        if (isNotification) return null;
        return reply({ error: { code: -32601, message: `Method not found: ${msg?.method}` } });
    }
  } catch (e) {
    return reply({ error: { code: -32603, message: e instanceof Error ? e.message : String(e) } });
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  }

  let tokenId: number | null;
  try {
    tokenId = await resolveToken(tokenFrom(req));
  } catch (e) {
    console.error("claude-reader-mcp: token lookup failed:", e instanceof Error ? e.message : String(e));
    return new Response("Service unavailable", { status: 503 });
  }
  if (tokenId === null) return new Response("Unauthorized", { status: 401 });
  if (rateLimited(tokenId)) {
    return new Response("Too many requests", { status: 429, headers: { "Retry-After": "60" } });
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return new Response("Request too large", { status: 413 });
  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return new Response("Request too large", { status: 413 });

  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }

  if (Array.isArray(body)) {
    if (body.length > 20) return json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Batch too large" } }, 400);
    const out = (await Promise.all(body.map((m) => handle(m, tokenId!)))).filter((x) => x !== null);
    return out.length ? json(out) : new Response(null, { status: 202 });
  }
  const out = await handle(body, tokenId);
  return out ? json(out) : new Response(null, { status: 202 });
});
