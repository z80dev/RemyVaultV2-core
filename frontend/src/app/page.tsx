import Link from 'next/link';

export default function Home() {
  return (
    <main className="landing-page">
      {/* Navbar */}
      <nav className="navbar">
        <div className="navbar-container">
          <div className="navbar-brand">wNFT</div>
          <Link href="/app" className="navbar-button">
            Launch App
          </Link>
        </div>
      </nav>

      {/* Hero Section */}
      <section className="hero">
        <div className="hero-content">
          <span className="hero-badge">Open Source</span>
          <h1 className="hero-title">
            wNFT
          </h1>
          <p className="hero-subtitle">
            DeFi Composability For NFTs
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
                                               <div>
            Just like wETH wraps ETH, wNFT wraps your NFTs
            unlocking the full power of DeFi composability.
                                                      Each NFT becomes a liquid, divisible token that
            can be traded, lent, staked, and integrated into any DeFi protocol.
                                                      </div>
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
                   <div>
                Deposit NFTs and receive ERC20 tokens.
                   </div>
                   <div>
                1 NFT = 1 token.
                   </div>
              </p>
            </div>

            <div className="feature-card">
              <div className="feature-number">2</div>
              <h3>Trade wNFTs</h3>
              <p>
                   <div>
                Trade, lend, or stake your wNFT tokens on any DeFi protocol.
                          </div>
                   <div>
                Provide liquidity on DEXes and earn real yield on your wNFTs.
                          </div>
              </p>
            </div>

            <div className="feature-card">
              <div className="feature-number">3</div>
              <h3>Withdraw NFTs</h3>
              <p>
                   <div>
                Burn tokens to unwrap NFTs at any time.
                          </div>
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
              <h3>🔓 Unlocks Liquidity</h3>
              <p>Transform illiquid NFTs into tradeable tokens with efficient price discovery</p>
            </div>

            <div className="benefit-card">
              <h3>⚡ Gas Efficient</h3>
              <p>Minimalist architecture designed for low gas costs</p>
            </div>

            <div className="benefit-card">
              <h3>🔄 DeFi Compatible</h3>
              <p>Standard ERC20 tokens work with any DeFi protocol out of the box</p>
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
          <p>A Remy Boys Production</p>
        </div>
      </footer>
    </main>
  );
}
