import { LegalPage } from "./LegalPage.jsx";
import { REPO } from "../ui.jsx";

const SECTIONS = [
  {
    id: "permissions", title: "Why the Mac asks for access",
    body: <>
      <p>PocketDesk lets a paired phone see and control your Mac. Only pair a phone you trust.</p>
      <ul>
        <li><b>Screen Recording</b> lets PocketDesk stream your Mac’s screen and audio to your phone.</li>
        <li><b>Accessibility</b> lets your phone send clicks and keystrokes, and turns the Mac’s app menus into touch controls.</li>
        <li><b>Local Network</b> lets your devices discover and connect to each other on your network.</li>
      </ul>
      <p>You can change these permissions in macOS System Settings → Privacy &amp; Security. Turning one off disables the features that need it.</p>
    </>,
  },
  {
    id: "pairing", title: "How your devices recognise each other",
    body: <>
      <p>Start pairing from PocketDesk on your Mac, with both devices on the same Wi-Fi. The pairing QR code contains the Mac’s certificate fingerprint and a one-time secret. Your phone can scan it or open the pairing link.</p>
      <p>Compare the six-digit code on both screens before approving the phone on your Mac. That code is tied to both devices’ certificates and the pairing secret. Don’t approve a request you didn’t start, or share a pairing QR code publicly.</p>
      <p>After pairing, the devices remember each other’s certificate fingerprints. Connections use QUIC with TLS 1.3 and check those saved identities. Each device’s private identity key is stored in its own Keychain.</p>
    </>,
  },
  {
    id: "relay", title: "What the relay can see",
    body: <>
      <p>Nearby connections use your local network. Remote Access is optional and must be enabled on both devices. Away from home, the relay helps an already paired phone reach its Mac; it cannot pair a new phone for you.</p>
      <p>Your screen, audio, input, clipboard and transferred files stay encrypted between your iPhone and Mac. The forwarding relay does not have the keys to decrypt that session.</p>
      <p><b>The relay does handle connection metadata:</b> IP addresses, device certificate fingerprints, the Mac’s ID, its allowed phones and traffic volume needed to enforce limits. Encryption does not hide connection timing or traffic size from the relay.</p>
      <p>The relay implementation keeps connection state in memory and does not log session content or device addresses. The hosting provider may retain infrastructure logs. You can also run your own relay and enter its address on both devices.</p>
    </>,
  },
  {
    id: "data", title: "What stays on your devices",
    body: <>
      <p>PocketDesk has no account system and includes no app analytics, advertising trackers or automatic crash-reporting service of its own. Pairing records, shortcuts, settings and cached icons are stored on your devices. Files you transfer remain where you save them.</p>
      <p>When you create a website shortcut, the iPhone app requests the icon from that website. The website receives a normal network request, including your IP address. Opening links to GitHub, TestFlight or other websites also uses those services.</p>
      <p>Apple’s TestFlight diagnostics and feedback, and website hosting, are separate from the app’s own data handling. See the <a href="privacy.html">Privacy Policy</a> for more detail.</p>
    </>,
  },
  {
    id: "revoke", title: "How to stop a phone’s access",
    body: <>
      <p><b>On your Mac:</b> open PocketDesk from the menu bar, find the paired phone, hover over its row and choose <b>Forget</b>. This removes its trust record, ends that phone’s sessions and updates the relay’s allowed-phone list. The phone must pair again before it can connect.</p>
      <p><b>On your iPhone:</b> open Settings → Macs, swipe left on the Mac and choose <b>Forget</b>. This removes the Mac from that iPhone. To revoke a lost phone, use the Mac’s Forget control.</p>
      <p>You can disconnect an active session from the Mac, turn off Remote Access to stop relay connections, or quit the Mac app to stop serving connections. Disconnecting a session leaves the pairing in place.</p>
      <p>An optional Face ID lock adds a check before using a paired Mac from your iPhone. It complements pairing; it does not replace revoking a phone you no longer trust.</p>
    </>,
  },
  {
    id: "source", title: "Inspect the code. Report problems privately.",
    body: <>
      <p>PocketDesk is open source. You can read the <a href={`${REPO}/blob/main/docs/ARCHITECTURE.md#security`}>security design</a>, the <a href={`${REPO}/tree/main/Packages/PocketDeskKit/Sources/PDSecurity`}>pairing and identity code</a>, and the <a href={`${REPO}/tree/main/Services/relay`}>relay implementation</a>.</p>
      <p>If you find a vulnerability, please follow the <a href={`${REPO}/blob/main/SECURITY.md`}>security reporting policy</a> and use GitHub’s private <a href={`${REPO}/security/advisories/new`}>Report a vulnerability</a> form. Include steps to reproduce it and what access an attacker could gain. Please keep sensitive details out of public issues.</p>
    </>,
  },
];

export function Security() {
  return <LegalPage eyebrow="Security" title={<>Your Mac.<br /><em>Your say.</em></>}
    updated="October 25, 2026"
    intro="What you grant, how your devices connect, and how to take access back."
    summary={[
      ["Pair in person", "Compare the code on both devices, then approve the phone on your Mac."],
      ["Encrypted between devices", "The relay forwards your session without decrypting its contents."],
      ["Revoke from your Mac", "Forget a phone to end its sessions and require pairing again."],
    ]}
    sections={SECTIONS} />;
}
