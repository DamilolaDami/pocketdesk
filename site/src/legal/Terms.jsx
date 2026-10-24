import { LegalPage } from "./LegalPage.jsx";
import { REPO } from "../ui.jsx";

export const UPDATED = "October 24, 2026";

const SUMMARY = [
  ["It's free", "PocketDesk costs nothing, and its source code is yours to use under the Apache License 2.0."],
  ["Use it on your own Macs", "Only control computers you own or have permission to use, and use PocketDesk lawfully."],
  ["Your things stay yours", "Your screen, files and clipboard never pass through us, and we claim no rights to them."],
  ["Provided as is", "We work hard on PocketDesk, but we can't promise it will never have bugs or interruptions."],
];

const SECTIONS = [
  {
    id: "agreement",
    title: "Agreeing to these terms",
    body: (
      <>
        <p>
          These terms cover your use of PocketDesk for iPhone, PocketDesk for Mac, and this website,
          made by the PocketDesk developers ("we" and "us"). By downloading or using PocketDesk, you
          agree to them. If you don't agree, please don't use it.
        </p>
        <p>
          How PocketDesk handles information is described in our <a href="privacy.html">Privacy Policy</a>,
          which is part of these terms.
        </p>
      </>
    ),
  },
  {
    id: "license",
    title: "Your license to use PocketDesk",
    body: (
      <>
        <p>
          PocketDesk is free. You may install and use it on devices you own or control, for personal
          or work use.
        </p>
        <p>
          If you get PocketDesk for iPhone from the App Store, your use of that copy is also governed
          by <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Apple's Licensed Application End User License Agreement</a>.
          If anything in these terms conflicts with it for an App Store copy, Apple's agreement comes
          first.
        </p>
        <p>
          PocketDesk's source code is available under the <a href={`${REPO}/blob/main/LICENSE`}>Apache License 2.0</a>.
          You may use, change and share the code under that license, which applies to the code
          itself. The PocketDesk name and icon identify our official builds: please don't use them in
          a way that suggests your version is ours.
        </p>
      </>
    ),
  },
  {
    id: "responsibility",
    title: "Your Macs, your responsibility",
    body: (
      <>
        <p>
          PocketDesk gives a paired iPhone real control of a Mac. Please only pair PocketDesk with
          computers you own or have permission to control, and keep your iPhone and its passcode
          secure. Anyone holding an unlocked, paired iPhone can use the Macs it's paired with, unless
          you've locked them with Face ID.
        </p>
        <p>
          You're responsible for what you do on your Macs through PocketDesk, and for keeping copies of
          anything important, as you would when using them directly.
        </p>
      </>
    ),
  },
  {
    id: "acceptable-use",
    title: "Acceptable use",
    body: (
      <>
        <p>When you use PocketDesk, please don't:</p>
        <ul>
          <li>Access or control a computer without the permission of its owner.</li>
          <li>Use it to break the law, or to harm, harass, spy on or deceive anyone.</li>
          <li>Try to get around copy protection, such as streaming protected video that macOS keeps out of screen capture.</li>
          <li>Interfere with or attack other people's devices or networks.</li>
        </ul>
      </>
    ),
  },
  {
    id: "content",
    title: "Your content",
    body: (
      <p>
        Your screen, sound, clipboard, files and shortcuts go directly between your own devices. They
        never pass through us, and we claim no ownership of or rights to any of them. You're
        responsible for having the right to send and use what you move between your devices.
      </p>
    ),
  },
  {
    id: "third-parties",
    title: "Other services",
    body: (
      <p>
        PocketDesk can open websites and apps on your Mac, and works with Apple services like Siri,
        widgets and TestFlight. Those services have their own terms and privacy policies, and we're not
        responsible for their content or how they work. Netflix, YouTube and other names shown in
        PocketDesk belong to their owners, and their use doesn't mean they endorse PocketDesk.
      </p>
    ),
  },
  {
    id: "beta",
    title: "Test versions",
    body: (
      <p>
        Test versions of PocketDesk, such as builds on TestFlight, are for trying out new things. They
        may have bugs, change often, or stop working when a test ends.
      </p>
    ),
  },
  {
    id: "changes-to-app",
    title: "Changes to PocketDesk",
    body: (
      <p>
        We may add, change or remove features, and we may stop offering PocketDesk at any time. Because
        the apps run on your own devices and their code is open, you can keep using a version you
        already have.
      </p>
    ),
  },
  {
    id: "warranty",
    title: "No warranty",
    body: (
      <p>
        PocketDesk is provided "as is" and "as available", without warranties of any kind, whether
        express or implied, including warranties of merchantability, fitness for a particular purpose
        and non-infringement. We don't promise that PocketDesk will be uninterrupted, error-free or
        compatible with every device or network.
      </p>
    ),
  },
  {
    id: "liability",
    title: "Limits on liability",
    body: (
      <>
        <p>
          To the fullest extent the law allows, we aren't liable for any indirect, incidental, special,
          consequential or punitive damages, or for lost data, profits or revenue, arising from your
          use of PocketDesk or your inability to use it. Since PocketDesk is free, our total liability
          for any claim relating to it is limited to zero, or the smallest amount the law permits.
        </p>
        <p>
          Some places don't allow these limits, so they may not all apply to you. Nothing in these
          terms takes away rights you have under the law where you live that can't be waived.
        </p>
      </>
    ),
  },
  {
    id: "apple",
    title: "About Apple",
    body: (
      <>
        <p>For copies of PocketDesk you get from the App Store:</p>
        <ul>
          <li>These terms are between you and us, not Apple. We, not Apple, are responsible for PocketDesk and its content.</li>
          <li>Apple has no obligation to provide maintenance or support for PocketDesk.</li>
          <li>If PocketDesk fails to meet a warranty that applies to it, you may notify Apple, and Apple will refund the purchase price, if any. To the extent the law allows, Apple has no other warranty obligation for PocketDesk.</li>
          <li>We, not Apple, are responsible for any claims about PocketDesk, including product liability claims, claims that it doesn't meet legal or regulatory requirements, and consumer protection claims.</li>
          <li>If someone claims PocketDesk infringes their intellectual property, we, not Apple, are responsible for dealing with that claim.</li>
          <li>Apple and its subsidiaries are third-party beneficiaries of these terms and may enforce them against you.</li>
        </ul>
        <p>Mac and iPhone are trademarks of Apple Inc. PocketDesk isn't made, sponsored or endorsed by Apple.</p>
      </>
    ),
  },
  {
    id: "ending",
    title: "Stopping",
    body: (
      <p>
        You can stop using PocketDesk at any time by forgetting your devices and deleting the apps. If
        you seriously break these terms, we may stop offering PocketDesk to you. The sections on
        warranties, liability and Apple continue to apply after you stop.
      </p>
    ),
  },
  {
    id: "changes",
    title: "Changes to these terms",
    body: (
      <p>
        We may update these terms. When we do, we'll change the date at the top of this page, and the
        history of every change is public in <a href={`${REPO}/commits/main/site/src/legal/Terms.jsx`}>the repository</a>.
        If you keep using PocketDesk after an update, you accept the new terms.
      </p>
    ),
  },
  {
    id: "contact",
    title: "Contact",
    body: (
      <p>
        Questions about these terms are welcome on <a href={`${REPO}/issues`}>GitHub</a>.
      </p>
    ),
  },
];

export function Terms() {
  return (
    <LegalPage
      eyebrow="Terms of Use"
      title={<>The ground rules,<br /><em>kept short.</em></>}
      intro="The terms for using PocketDesk for iPhone and Mac, and this website. Written to be read, not skimmed past."
      updated={UPDATED}
      summary={SUMMARY}
      sections={SECTIONS}
    />
  );
}
