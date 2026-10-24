import { LegalPage } from "./LegalPage.jsx";
import { REPO } from "../ui.jsx";

export const UPDATED = "October 24, 2026";

const SUMMARY = [
  ["No account, no servers", "There's nothing to sign up for, and PocketDesk runs no servers. Your iPhone talks straight to your Mac."],
  ["Nothing is collected", "No analytics, no advertising, no tracking and no crash reporting of our own. We never see your data, so we can't sell or share it."],
  ["Encrypted end to end", "Everything between your iPhone and Mac is encrypted with TLS 1.3, and each side only trusts the device it paired with."],
  ["It stays on your devices", "What PocketDesk keeps, like paired Macs, keys, shortcuts and settings, is stored on your own iPhone and Mac."],
  ["You're in control", "Forget a Mac, delete the app, or turn off a permission at any time, and what PocketDesk kept goes with it."],
];

const SECTIONS = [
  {
    id: "about",
    title: "About this policy",
    body: (
      <>
        <p>
          This policy covers PocketDesk for iPhone, PocketDesk for Mac, and this website. It explains
          what information the apps handle, where it goes, and the choices you have. We've tried to
          write it plainly. If anything is unclear, <a href={`${REPO}/issues`}>ask us</a>.
        </p>
        <p>
          PocketDesk is free and open source. Everything this policy says about how the apps behave
          can be checked in <a href={REPO}>their code</a>.
        </p>
      </>
    ),
  },
  {
    id: "collect",
    title: "What we collect",
    body: (
      <>
        <p>
          Nothing. PocketDesk has no accounts, no servers of its own, and no analytics, advertising or
          tracking code. The apps don't send us information about you, your devices or how you use
          them, and they include no third-party code that does.
        </p>
        <p>
          Because none of your information reaches us, we have nothing to sell, share, rent or hand
          over, and we don't use your information to train any kind of model.
        </p>
      </>
    ),
  },
  {
    id: "between",
    title: "What travels between your iPhone and Mac",
    body: (
      <>
        <p>
          To let you use your Mac from your iPhone, the two apps exchange information directly with
          each other, and only with devices you've paired:
        </p>
        <ul>
          <li><b>Your Mac's screen and sound,</b> while you're viewing it on your iPhone. They're streamed live and never recorded or saved by PocketDesk.</li>
          <li><b>Your taps, typing and gestures,</b> which your Mac turns into clicks and keystrokes.</li>
          <li><b>The clipboard,</b> only while Share Clipboard is on and a session is open, or when you choose Paste or Copy from Mac.</li>
          <li><b>Photos and files you choose to send,</b> which go to that Mac's Downloads folder, and files you choose to bring back from it.</li>
          <li><b>What helps the iPhone app show your Mac:</b> its name, whether it's awake, its battery level, its desktop picture, the menus of the app in front, its list of apps and their icons, its Shortcuts, what's playing, and the network details your iPhone needs to wake it from sleep.</li>
        </ul>
        <p>
          All of it travels over your own network, encrypted with TLS 1.3. When you pair, both devices
          show the same six-digit code and remember each other's key. After that, each side only
          talks to the exact device it paired with, so someone else on the same Wi-Fi can't watch or
          join. Details are in our <a href={`${REPO}/blob/main/SECURITY.md`}>security notes</a>.
        </p>
      </>
    ),
  },
  {
    id: "stored",
    title: "What's stored, and where",
    body: (
      <>
        <p>PocketDesk keeps a small amount of information so it works the next time you open it. All of it stays on your own devices.</p>
        <p><b>On your iPhone:</b></p>
        <ul>
          <li>The Macs you've paired, with their names, the public keys confirmed when you paired, and the details needed to wake them.</li>
          <li>The iPhone's own private key, in its Keychain.</li>
          <li>Your shortcuts and settings, which the widgets and Control Center can also read.</li>
          <li>A copy of each Mac's desktop picture, and cached app icons and website icons, so the app opens quickly.</li>
        </ul>
        <p><b>On your Mac:</b></p>
        <ul>
          <li>The iPhones you've paired and their public keys.</li>
          <li>The Mac's own private key, in its Keychain.</li>
          <li>PocketDesk's settings.</li>
          <li>Files you send from your iPhone, in your Downloads folder, where they stay until you delete them.</li>
        </ul>
        <p>
          Each device's private key is locked to that device: it isn't synced to iCloud and doesn't
          move to another device through a backup. Your device's normal backups may include the rest
          of the app's data, as they do for any app.
        </p>
      </>
    ),
  },
  {
    id: "internet",
    title: "When the apps use the internet",
    body: (
      <>
        <p>
          PocketDesk works on your local network and doesn't connect to any PocketDesk server. There's
          one time the iPhone app reaches the internet on its own: when you make a shortcut for a
          website, it asks that website for its icon, the way a browser does, so the tile can show it.
          That website sees an ordinary request from your iPhone, including its IP address, and
          nothing about you or your Macs. The icon is then kept on your iPhone.
        </p>
        <p>
          When a shortcut opens a website, it opens on your Mac, in your Mac's browser. What happens
          there is between you and that website, under its own privacy policy.
        </p>
        <p>
          We're working on a way to reach your Mac when you're away from home. If that needs a
          service run by us, it will only pass along traffic that's already encrypted between your
          devices, and we'll update this policy before it ships.
        </p>
      </>
    ),
  },
  {
    id: "permissions",
    title: "Permissions, and why we ask",
    body: (
      <>
        <p><b>On your Mac:</b></p>
        <ul>
          <li><b>Screen Recording,</b> so your iPhone can see the screen. Nothing is captured unless a paired iPhone is connected and viewing it.</li>
          <li><b>Accessibility,</b> so your taps and typing can control the Mac, and so the iPhone can show the menus of the app in front.</li>
          <li><b>Local Network,</b> so your iPhone can find and reach your Mac.</li>
        </ul>
        <p><b>On your iPhone:</b></p>
        <ul>
          <li><b>Local Network,</b> to find your Macs.</li>
          <li><b>Camera,</b> only to scan a pairing code. No pictures are taken or kept.</li>
          <li><b>Photos,</b> through Apple's photo picker, so PocketDesk only ever sees the photos you choose to send.</li>
          <li><b>Face ID,</b> if you lock a Mac. iOS checks your face or passcode, and PocketDesk only learns whether it was you.</li>
        </ul>
        <p>You can turn any of these off in System Settings on your Mac or Settings on your iPhone.</p>
      </>
    ),
  },
  {
    id: "apple",
    title: "Apple services",
    body: (
      <>
        <p>
          PocketDesk is distributed through Apple. If you use Siri to run a shortcut, what you say is
          handled by Apple under Apple's privacy policy. If you test PocketDesk through TestFlight,
          Apple may share your email address and, if you choose to send them, crash reports and
          feedback with us, under the TestFlight terms. We use these only to fix problems and reply to
          you. Apple's own handling of your information is covered
          by <a href="https://www.apple.com/legal/privacy/">Apple's privacy policy</a>.
        </p>
      </>
    ),
  },
  {
    id: "website",
    title: "This website",
    body: (
      <>
        <p>
          This website uses no cookies, no analytics and no tracking. Its fonts and images are served
          with the site itself, so your browser doesn't contact any font or advertising service when
          you visit. Like any website, the service that hosts it may keep standard server logs, such
          as IP addresses and the pages requested, to keep it running and secure. Links to GitHub,
          Apple and other sites lead to services with their own privacy policies.
        </p>
      </>
    ),
  },
  {
    id: "children",
    title: "Children",
    body: (
      <p>
        PocketDesk isn't directed at children and doesn't knowingly collect information from anyone,
        including children.
      </p>
    ),
  },
  {
    id: "choices",
    title: "Your choices",
    body: (
      <>
        <ul>
          <li><b>Forget a Mac</b> from its card on your iPhone to remove what PocketDesk kept about it.</li>
          <li><b>Forget an iPhone</b> in PocketDesk's menu on your Mac to stop it connecting.</li>
          <li><b>Turn off Share Clipboard</b> in Settings to stop sharing the clipboard automatically.</li>
          <li><b>Delete the apps</b> to remove everything they stored, apart from files you've sent to your Downloads folder.</li>
        </ul>
        <p>
          Since we don't hold any of your information, there's nothing for us to look up, correct or
          delete on our side. If you have a question about your privacy, we're still happy to help.
        </p>
      </>
    ),
  },
  {
    id: "changes",
    title: "Changes to this policy",
    body: (
      <p>
        If we change how PocketDesk handles information, we'll update this page and the date at the
        top before the change takes effect. The history of every change is public
        in <a href={`${REPO}/commits/main/site/src/legal/PrivacyPolicy.jsx`}>the repository</a>.
      </p>
    ),
  },
  {
    id: "contact",
    title: "Contact",
    body: (
      <p>
        For questions about this policy, open an issue on <a href={`${REPO}/issues`}>GitHub</a>. To
        report a security problem privately, use the repository's Security tab and
        choose <b>Report a vulnerability</b>, as described in <a href={`${REPO}/blob/main/SECURITY.md`}>SECURITY.md</a>.
      </p>
    ),
  },
];

export function PrivacyPolicy() {
  return (
    <LegalPage
      eyebrow="Privacy Policy"
      title={<>What's on your Mac<br /><em>stays yours.</em></>}
      intro="PocketDesk is built so your Mac and everything on it stay between your Mac and your iPhone. Here's exactly what that means."
      updated={UPDATED}
      summary={SUMMARY}
      sections={SECTIONS}
    />
  );
}
