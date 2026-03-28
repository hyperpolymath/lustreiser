# SPDX-License-Identifier: PMPL-1.0-or-later
# lustreiser — Generate formally verified real-time embedded code via Lustre

# Default: build and test
default: build test

# Build release binary
build:
    cargo build --release

# Run all tests
test:
    cargo test

# Run clippy lints
lint:
    cargo clippy -- -D warnings

# Format code
fmt:
    cargo fmt

# Check formatting without modifying
fmt-check:
    cargo fmt -- --check

# Build documentation
doc:
    cargo doc --no-deps --open

# Clean build artifacts
clean:
    cargo clean

# Run the CLI
run *ARGS:
    cargo run -- {{ARGS}}

# Full quality check (lint + test + fmt-check)
quality: fmt-check lint test
    @echo "All quality checks passed"

# Install locally
install:
    cargo install --path .

# Run panic-attacker pre-commit scan
assail:
    @command -v panic-attack >/dev/null 2>&1 && panic-attack assail . || echo "panic-attack not found — install from https://github.com/hyperpolymath/panic-attacker"

# --- Domain-Specific Recipes (lustreiser) ---

# Generate Lustre code from a manifest\ngenerate MANIFEST:\n    cargo run -- generate {{MANIFEST}}\n\n# Validate a lustreiser manifest\nvalidate MANIFEST:\n    cargo run -- validate {{MANIFEST}}\n\n# Run WCET analysis on generated code\nwcet TARGET:\n    cargo run -- wcet {{TARGET}}

# Run contractile checks
contractile-check:
    @echo "Running contractile validation..."
    @test -f .machine_readable/contractiles/must/Mustfile.a2ml && echo "Mustfile: OK" || echo "Mustfile: MISSING"
    @test -f .machine_readable/contractiles/trust/Trustfile.a2ml && echo "Trustfile: OK" || echo "Trustfile: MISSING"
    @test -f .machine_readable/contractiles/dust/Dustfile.a2ml && echo "Dustfile: OK" || echo "Dustfile: MISSING"
    @test -f .machine_readable/contractiles/intend/Intendfile.a2ml && echo "Intendfile: OK" || echo "Intendfile: MISSING"

# RSR compliance check
rsr-check: quality contractile-check
    @echo "RSR compliance check complete"

# Self-diagnostic — checks dependencies, permissions, paths
doctor:
    @echo "Running diagnostics for lustreiser..."
    @echo "Checking required tools..."
    @command -v just >/dev/null 2>&1 && echo "  [OK] just" || echo "  [FAIL] just not found"
    @command -v git >/dev/null 2>&1 && echo "  [OK] git" || echo "  [FAIL] git not found"
    @echo "Checking for hardcoded paths..."
    @grep -rn '$HOME\|$ECLIPSE_DIR' --include='*.rs' --include='*.ex' --include='*.res' --include='*.gleam' --include='*.sh' . 2>/dev/null | head -5 || echo "  [OK] No hardcoded paths"
    @echo "Diagnostics complete."

# Auto-repair common issues
heal:
    @echo "Attempting auto-repair for lustreiser..."
    @echo "Fixing permissions..."
    @find . -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    @echo "Cleaning stale caches..."
    @rm -rf .cache/stale 2>/dev/null || true
    @echo "Repair complete."

# Guided tour of key features
tour:
    @echo "=== lustreiser Tour ==="
    @echo ""
    @echo "1. Project structure:"
    @ls -la
    @echo ""
    @echo "2. Available commands: just --list"
    @echo ""
    @echo "3. Read README.adoc for full overview"
    @echo "4. Read EXPLAINME.adoc for architecture decisions"
    @echo "5. Run 'just doctor' to check your setup"
    @echo ""
    @echo "Tour complete! Try 'just --list' to see all available commands."

# Open feedback channel with diagnostic context
help-me:
    @echo "=== lustreiser Help ==="
    @echo "Platform: $(uname -s) $(uname -m)"
    @echo "Shell: $SHELL"
    @echo ""
    @echo "To report an issue:"
    @echo "  https://github.com/hyperpolymath/lustreiser/issues/new"
    @echo ""
    @echo "Include the output of 'just doctor' in your report."
