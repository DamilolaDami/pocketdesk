import { releaseHistory, latestAvailableMac } from "../../releases/model.mjs";

const files = import.meta.glob("../../releases/*.json", { eager: true, import: "default" });
export const RELEASES = releaseHistory(Object.values(files));
export const latestMac = latestAvailableMac(RELEASES);
export const latestIPhone = RELEASES.find(release => release.changes.some(change => change.platform === "iphone"));
