// Shared by the website and release tooling. No browser or Node dependencies.
export function releaseHistory(entries) {
  const ids = new Set();
  for (const r of entries) {
    const fail = (message) => { throw new Error(`Release ${r.id || "(missing id)"}: ${message}`); };
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(r.id || "")) fail("invalid id");
    if (ids.has(r.id)) fail("duplicate id");
    ids.add(r.id);
    if (!/^\d+\.\d+(?:\.\d+)?$/.test(r.version || "")) fail("invalid version");
    if (r.build !== undefined && !/^\d+$/.test(r.build)) fail("invalid build");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(r.date || "") ||
        !Number.isFinite(Date.parse(r.date)) || new Date(r.date).toISOString().slice(0, 10) !== r.date) fail("invalid date");
    if (!["draft", "published"].includes(r.status)) fail("status must be draft or published");
    if (!Array.isArray(r.changes)) fail("changes must be an array");
    for (const c of r.changes) {
      if (!["mac", "iphone"].includes(c.platform) || !c.title?.trim() || !c.text?.trim()) fail("each change needs a platform, title and text");
    }
    for (const key of ["macURL", "source"]) {
      if (r[key]) {
        try { if (new URL(r[key]).protocol !== "https:") fail(`${key} must use HTTPS`); }
        catch { fail(`${key} must be an HTTPS URL`); }
      }
    }
    if (r.status === "draft") continue;
    if (!r.title?.trim() || !r.summary?.trim() || !r.changes.length) fail("published entries need a title, summary and changes");
    if (r.changes.some(c => c.platform === "mac") && !r.macURL) fail("Mac releases need a published download URL");
    if (r.changes.some(c => c.platform === "iphone") && !["available", "awaiting-review"].includes(r.iphoneStatus)) fail("iPhone releases need an availability status");
  }
  return entries.filter(r => r.status === "published")
    .sort((a, b) => b.date.localeCompare(a.date) || Number(b.build || 0) - Number(a.build || 0) || b.id.localeCompare(a.id))
    .map((r, index) => ({ ...r, latest: index === 0 }));
}

export function releaseNotes(release) {
  return `${release.title}\n\n${release.summary}\n\n${["mac", "iphone"].flatMap(platform => {
    const changes = release.changes.filter(c => c.platform === platform);
    return changes.length ? [`## ${platform === "mac" ? "Mac" : "iPhone"}\n\n${changes.map(c => `- **${c.title}** — ${c.text}`).join("\n")}\n`] : [];
  }).join("\n")}\n`;
}
