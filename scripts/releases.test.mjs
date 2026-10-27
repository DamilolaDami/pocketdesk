import test from "node:test";
import assert from "node:assert/strict";
import { releaseHistory, releaseNotes, latestAvailableMac } from "../releases/model.mjs";

const entry = (overrides = {}) => ({ id: "1-0-74", version: "1.0", build: "74", date: "2026-10-25",
  status: "published", title: "Better setup", summary: "Connect more easily.", iphoneStatus: "available",
  changes: [{ platform: "iphone", title: "Setup", text: "Guided first connection." }], ...overrides });

test("new drafts never displace public releases; same-day builds sort numerically", () => {
  const history = releaseHistory([entry(), entry({ id: "1-0-100", build: "100" }),
    entry({ id: "1-0-101", build: "101", status: "draft", title: "", summary: "", changes: [] })]);
  assert.deepEqual(history.map(r => [r.build, r.latest]), [["100", true], ["74", false]]);
});

test("invalid public metadata fails before deployment", () => {
  for (const overrides of [{ date: "2026-02-30" }, { status: "publshed" }, { iphoneStatus: undefined },
    { source: "javascript:alert(1)" }, { changes: [] },
    { changes: [{ platform: "mac", title: "Mac", text: "Update" }] }]) {
    assert.throws(() => releaseHistory([entry(overrides)]));
  }
  assert.throws(() => releaseHistory([entry(), entry()]), /duplicate/);
});

test("awaiting review stays explicit and does not become available", () => {
  assert.equal(releaseHistory([entry({ iphoneStatus: "awaiting-review" })])[0].iphoneStatus, "awaiting-review");
});

test("GitHub notes use the same platform changes as the website", () => {
  const notes = releaseNotes(entry());
  assert.match(notes, /## iPhone\n\n- \*\*Setup\*\* — Guided first connection\./);
  assert.doesNotMatch(notes, /## Mac/);
});

test("a Mac preview never replaces the compatible stable download", () => {
  const stable = entry({ macURL: "https://example.com/stable.dmg" });
  const preview = entry({ id: "1-2-101", version: "1.2", build: "101", macStatus: "preview", iphoneStatus: "awaiting-review", macURL: "https://example.com/preview.dmg" });
  const history = releaseHistory([stable, preview]);
  assert.equal(latestAvailableMac(history).id, stable.id);
  assert.equal(latestAvailableMac(releaseHistory([stable, { ...preview, macStatus: "available", iphoneStatus: "available" }])).id, preview.id);
  assert.throws(() => releaseHistory([entry({ macStatus: "ready-ish" })]), /Mac availability/);
});
