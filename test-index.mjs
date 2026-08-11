// Runs index.html's inline script against stubbed fetches and asserts what it
// renders. No framework: node test-index.mjs
//
// Expectations for the live repo files are DERIVED from those files, so shipping
// a release never breaks this. The tricky logic (version ordering, escaping,
// fallback) is pinned against fixed synthetic fixtures instead.
import { readFileSync, existsSync } from "node:fs";
import assert from "node:assert";

const REPO = new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const code = readFileSync(`${REPO}/index.html`, "utf8").match(/<script>([\s\S]*?)<\/script>/)[1];

// Minimal DOM: enough for the script's getElementById / querySelector / innerHTML.
function run(serve) {
  const el = (id) => ({
    id, innerHTML: "", textContent: "", hidden: true, dateTime: "",
    insertAdjacentHTML(_, s) { this.innerHTML += s; },
  });
  const nodes = ["pkg-grid", "pkg-note", "last-updated", "updated"].reduce((o, id) => (o[id] = el(id), o), {});
  const cards = new Map();

  globalThis.document = {
    getElementById: (id) => nodes[id],
    querySelector: (sel) => {
      const id = sel.match(/\[data-pkg="(.+)"\]/)[1];
      if (!cards.has(id)) cards.set(id, el(id));
      return cards.get(id);
    },
  };
  globalThis.CSS = { escape: (s) => s };
  globalThis.location = { href: "https://ios.jjolano.me/" };
  globalThis.fetch = async (path) => {
    const body = serve(path);
    if (body === undefined) return { ok: false, status: 404 };
    return { ok: true, status: 200, text: async () => body, json: async () => JSON.parse(body) };
  };

  new Function(code)();
  return new Promise((r) => setTimeout(() => r({ nodes, cards, grid: nodes["pkg-grid"].innerHTML }), 150));
}

const fromDisk = (path) => existsSync(`${REPO}/${path}`) ? readFileSync(`${REPO}/${path}`, "utf8") : undefined;
const tagsIn = (s) => [...new Set([...s.matchAll(/<\/?([a-z][a-z0-9]*)/gi)].map((m) => m[1].toLowerCase()))].sort();

// ---- 1. the live index, with expectations derived from the file itself ----
{
  const raw = fromDisk("Packages");
  const ids = [...new Set([...raw.matchAll(/^Package: (.+)$/gm)].map((m) => m[1].trim()))].sort();
  const builds = [...raw.matchAll(/^Package: /gm)].length;

  const { grid, nodes, cards } = await run(fromDisk);
  assert.deepStrictEqual([...grid.matchAll(/data-pkg="([^"]+)"/g)].map((m) => m[1]), ids, "one card per package, sorted");
  assert.strictEqual(
    nodes["pkg-note"].textContent,
    `${ids.length} package${ids.length === 1 ? "" : "s"}, ${builds} builds indexed. Sources are on GitHub.`,
    "counts match the index",
  );

  for (const id of ids) {
    const card = grid.split("</article>").find((c) => c.includes(`data-pkg="${id}"`));
    const version = card.match(/class="pkg-ver">([^<]+)</)[1];
    const known = [...raw.matchAll(new RegExp(`^Package: ${id.replace(/\./g, "\\.")}\\n(?:.*\\n)*?Version: (.+)$`, "gm"))].map((m) => m[1].trim());
    assert.ok(known.includes(version), `${id}: rendered version ${version} exists in the index`);
    // every chip links to a real .deb for that package's newest version
    for (const [, href] of card.matchAll(/class="chip" href="([^"]+)"/g)) {
      assert.ok(raw.includes(`Filename: ${href}`), `${id}: chip links to an indexed deb`);
      assert.match(href, /^https:\/\/github\.com\/jjolano\/[^/]+\/releases\/download\/[^/]+\/[^/]+\.deb$/, "chip href shape");
    }
    assert.match(card, /<a class="src-link" href="https:\/\/github\.com\/jjolano\/[^/"]+">/, `${id}: source link is a repo root`);
  }

  // packages carrying a SileoDepiction get their latest release notes inlined
  for (const id of ids) {
    if (!raw.includes(`SileoDepiction: https://ios.jjolano.me/depictions/ios/${id}.json`)) continue;
    const notes = cards.get(id)?.innerHTML || "";
    assert.match(notes, /<summary>What's new in .+<\/summary>/, `${id}: changelog rendered`);
    assert.deepStrictEqual(tagsIn(notes).filter((t) => !["details", "summary", "p", "ul", "li", "strong", "code"].includes(t)), [], `${id}: only whitelisted tags`);
  }

  const date = fromDisk("Release").match(/^Date:[ \t]*(.+)$/m)[1].trim();
  assert.strictEqual(nodes["last-updated"].textContent, new Date(date).toISOString().replace(/\.\d+Z$/, "Z"), "footer date comes from Release");
  assert.strictEqual(nodes["updated"].hidden, false, "footer revealed");
}

// ---- 2. version ordering (fixed fixture: numeric, not lexicographic) ----
{
  const stanza = (v, a) => `Package: t.pkg\nVersion: ${v}\nArchitecture: ${a}\nName: T\nDescription: d\nSize: 1024\nFilename: https://github.com/jjolano/T/releases/download/v${v}/t_${v}_${a}.deb\n`;
  const packages = [stanza("3.9", "iphoneos-arm"), stanza("3.10", "iphoneos-arm"), stanza("3.10", "iphoneos-arm64"), stanza("3.7.6", "iphoneos-arm")].join("\n");
  const { grid } = await run((p) => (p === "Packages" ? packages : undefined));

  assert.strictEqual(grid.match(/class="pkg-ver">([^<]+)</)[1], "3.10", "3.10 beats 3.9 (lexicographic would pick 3.9)");
  assert.deepStrictEqual([...grid.matchAll(/class="chip"[^>]*><b>(\w+)</g)].map((m) => m[1]), ["rootful", "rootless"], "chips describe the newest version only");
  assert.match(grid, /title="Download iphoneos-arm · 1 KB"/, "size rendered from Size:");
}

// ---- 3. release notes are inert (they reach innerHTML) ----
{
  const packages = `Package: t.pkg\nVersion: 1\nArchitecture: iphoneos-arm\nName: T\nDescription: d\nSize: 1\nFilename: https://github.com/jjolano/T/releases/download/v1/t.deb\nSileoDepiction: https://ios.jjolano.me/depictions/ios/t.pkg.json\n`;
  const depiction = JSON.stringify({ tabs: [{ tabname: "Changelog", views: [
    { class: "DepictionSubheaderView", title: '<img src=x onerror="alert(1)">' },
    { class: "DepictionMarkdownView", markdown: "**bold** <script>alert(1)</script>\r\n\r\n- <b>item</b>\r\n- `code` stays" },
  ] }] });
  const { cards } = await run((p) => (p === "Packages" ? packages : p.includes("depictions") ? depiction : undefined));

  const notes = cards.get("t.pkg").innerHTML;
  assert.deepStrictEqual(tagsIn(notes), ["code", "details", "li", "p", "strong", "summary", "ul"], `injected markup survived: ${notes}`);
  assert.match(notes, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/, "attribute injection neutered");
  assert.match(notes, /<ul><li>&lt;b&gt;item&lt;\/b&gt;<\/li>/, "escaped, still a list");
  assert.match(notes, /<strong>bold<\/strong>/, "real markdown still renders");
  assert.match(notes, /<code>code<\/code>/, "CRLF-separated bullets split correctly");
}

// ---- 4. unreachable index leaves the hand-written cards alone ----
{
  const { nodes } = await run(() => undefined);
  assert.strictEqual(nodes["pkg-grid"].innerHTML, "", "grid untouched when Packages fetch fails");
  assert.strictEqual(nodes["updated"].hidden, true, "no date claimed when Release fetch fails");
}

console.log("all assertions passed");
