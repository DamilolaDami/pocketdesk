import { releaseHistory } from "../../releases/model.mjs";

const files = import.meta.glob("../../releases/*.json", { eager: true, import: "default" });
export const RELEASES = releaseHistory(Object.values(files));
export const latestMac = RELEASES.find(release => release.macURL);
export const latestIPhone = RELEASES.find(release => release.changes.some(change => change.platform === "iphone"));
