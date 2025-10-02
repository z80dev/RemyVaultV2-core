import Link from 'next/link';

export default function Home() {
  return (
    <main className="landing-page">
      {/* Hero Section */}
      <section className="hero">
        <div className="hero-content">
          <h1 className="hero-title">
            wNFT
          </h1>
          <p className="hero-subtitle">
            wETH for NFTs — Bring DeFi composability to your digital assets
          </p>
          <p className="hero-description">
            Transform illiquid NFTs into tradeable, fractional tokens with seamless DeFi integration
          </p>
          <Link href="/app" className="cta-button">
            Open App
          </Link>
        </div>
      </section>

      {/* What is wNFT Section */}
      <section className="feature-section">
        <div className="feature-container">
          <h2 className="section-title">What is wNFT?</h2>
          <p className="section-description">
            Just as wETH wraps ETH to make it ERC-20 compatible, wNFT wraps your NFTs into fungible tokens,
            unlocking the full power of DeFi composability. Each NFT becomes a liquid, divisible asset that
            can be traded, lent, borrowed, and integrated into any DeFi protocol.
          </p>
        </div>
      </section>

      {/* How It Works */}
      <section className="how-it-works">
        <div className="feature-container">
          <h2 className="section-title">How It Works</h2>
          <div className="features-grid">
            <div className="feature-card">
              <div className="feature-number">1</div>
              <h3>Deposit NFTs</h3>
              <p>
                Lock your NFTs in a vault and receive fungible ERC-20 tokens.
                Each NFT = 1×10¹⁸ tokens, making them divisible and tradeable.
              </p>
            </div>

            <div className="feature-card">
              <div className="feature-number">2</div>
              <h3>Trade Fractions</h3>
              <p>
                Trade fractional ownership on Uniswap V4 with automated liquidity pools
                and hierarchical fee distribution for derivative collections.
              </p>
            </div>

            <div className="feature-card">
              <div className="feature-number">3</div>
              <h3>Withdraw NFTs</h3>
              <p>
                Burn your tokens to retrieve specific NFTs from the vault anytime.
                Full custody and control over your assets.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Key Features */}
      <section className="feature-section alt-bg">
        <div className="feature-container">
          <h2 className="section-title">Key Features</h2>
          <div className="benefits-grid">
            <div className="benefit-card">
              <h3>🔓 Unlock Liquidity</h3>
              <p>Transform illiquid NFTs into tradeable tokens with instant price discovery</p>
            </div>

            <div className="benefit-card">
              <h3>⚡ Gas Efficient</h3>
              <p>Minimalist architecture designed for low gas costs on Base L2</p>
            </div>

            <div className="benefit-card">
              <h3>🔄 DeFi Compatible</h3>
              <p>Standard ERC-20 tokens work with any DeFi protocol out of the box</p>
            </div>

            <div className="benefit-card">
              <h3>🎨 Create Derivatives</h3>
              <p>Launch new collections with custom tokenomics and automated liquidity</p>
            </div>
          </div>
        </div>
      </section>

      {/* CTA Section */}
      <section className="cta-section">
        <div className="feature-container">
          <h2 className="section-title">Ready to get started?</h2>
          <p className="section-description">
            Start fractionalizing your NFTs and unlock DeFi composability today
          </p>
          <Link href="/app" className="cta-button large">
            Launch App
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="footer">
        <div className="feature-container">
          <p>Built on Base · Powered by Uniswap V4</p>
        </div>
      </footer>
    </main>
  );
}
