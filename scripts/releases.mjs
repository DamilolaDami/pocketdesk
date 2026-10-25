#!/usr/bin/env node
import { readdir, readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { releaseHistory, releaseNotes } from "../releases/model.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const directory = new URL("../releases/", import.meta.url);

async function run() {
  const [command, argument, buildArg] = process.argv.slice(2);
  const files = (await readdir(directory)).filter(name => name.endsWith(".json"));
  const entries = await Promise.all(files.map(async name => JSON.parse(await readFile(new URL(name, directory), "utf8"))));
  const history = releaseHistory(entries);
  if (command === "check") {
    if (!history.some(r => r.macURL) || !history.some(r => r.iphoneStatus)) throw new Error("History needs a published Mac and iPhone entry");
    console.log(`Validated ${entries.length} entries (${history.length} published).`);
  } else if (command === "new") {
    const version = argument || (await readFile(new URL("../project.yml", import.meta.url), "utf8")).match(/MARKETING_VERSION:\s*"?([\d.]+)/)?.[1];
    const build = buildArg || execFileSync("git", ["rev-list", "--count", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
    const entry = { id: `${version.replaceAll(".", "-")}-${build}`, version, build,
      date: new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Lagos", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date()),
      status: "draft", title: "", summary: "", iphoneStatus: "awaiting-review", changes: [] };
    releaseHistory([...entries, entry]);
    await writeFile(new URL(`${entry.id}.json`, directory), `${JSON.stringify(entry, null, 2)}\n`, { flag: "wx" });
    console.log(`Created releases/${entry.id}.json (draft; hidden from website). Confirm the build number against the shipped archive before publishing.`);
  } else if (command === "notes") {
    const entry = entries.find(r => r.id === argument);
    if (!entry) throw new Error("Pass an existing release id, e.g. notes 1-0-74");
    if (!entry.title?.trim() || !entry.summary?.trim() || !entry.changes.length) throw new Error("Finish the release notes first");
    process.stdout.write(releaseNotes(entry));
  } else {
    throw new Error("Usage: node scripts/releases.mjs check | new [version] [build] | notes <id>");
  }
}
run().catch(error => { console.error(error.message); process.exitCode = 1; });
