import { smoothLink } from "../smooth.js";
import { REPO } from "../ui.jsx";

const COLUMNS = [
  ["Product", [["How it works", "#how"], ["Shortcuts", "#shortcuts"], ["Features", "#features"], ["Releases", `${REPO}/releases`]]],
  ["Trust", [["Privacy Policy", "privacy.html"], ["Terms of Use", "terms.html"], ["Security", `${REPO}/blob/main/SECURITY.md`], ["License", `${REPO}/blob/main/LICENSE`]]],
  ["Open source", [["GitHub", REPO], ["How it's built", "how-its-built.html"], ["Report a problem", `${REPO}/issues`]]],
];

export function Footer({ home = "" }) {
  return (
    <footer className="footer">
      <div className="footer-cols">
        {COLUMNS.map(([title, links]) => (
          <div key={title}>
            <p className="label">{title}</p>
            {links.map(([label, href]) => (
              <a key={label} href={href.startsWith("#") ? home + href : href} onClick={href.startsWith("#") && !home ? smoothLink : undefined}>{label}</a>
            ))}
          </div>
        ))}
      </div>
      <div className="footer-base">
        <p className="label">Made with Swift, for people who'd rather be on the sofa</p>
        <p className="footer-note">PocketDesk is not affiliated with Apple. Mac and iPhone are trademarks of Apple Inc.</p>
      </div>
    </footer>
  );
}
