import { Phone, Reveal } from "../ui.jsx";

export function ProductPreview() {
  return <section className="product-preview" aria-labelledby="product-preview-title">
    <Reveal className="product-preview-heading">
      <p className="label">The real thing</p>
      <h2 className="section-title" id="product-preview-title">See it <em>up close.</em></h2>
      <p>Your Mac’s screen when you need it. Its shortcuts, music and files when you don’t.</p>
    </Reveal>
    <div className="product-preview-grid">
      <Reveal as="figure" className="product-screen">
        <Phone landscape src="shots/stream-xcode.jpg" alt="Xcode running on a Mac, streamed to an iPhone with PocketDesk’s keyboard and touch controls" />
        <figcaption><b>Your whole Mac, in reach.</b><span>See the screen. Touch, type and get on with it.</span></figcaption>
      </Reveal>
      <Reveal as="figure" className="product-home" delay={0.1}>
        <Phone src="shots/home.jpg" alt="PocketDesk’s iPhone home screen with an online MacBook Pro and music controls" />
        <figcaption><b>A home for your Macs.</b><span>One card. The things you reach for most.</span></figcaption>
      </Reveal>
    </div>
  </section>;
}
