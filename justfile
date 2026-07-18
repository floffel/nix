# NixOS configuration test suite
#
# Targets:
#   just test         → run all fast checks (evaluation + config assertions)
#   just test-eval    → NixOS module evaluation (option correctness)
#   just test-config  → config integrity assertions (routing, service declarations)
#   just test-full    → everything including VM integration tests (slow)
#   just lint         → static analysis (statix, deadnix, nixpkgs-fmt)

default: test

# Run all fast checks
test: test-eval test-config

# NixOS module evaluation — catches option renames, type mismatches, missing imports
test-eval:
    @echo "=== Module evaluation (15 containers) ==="
    nix flake check --accept-flake-config 2>&1 | grep -E "evaluated to|error|FAIL"

# Config integrity assertions — catches routing misconfigs, missing filter definitions
test-config:
    @echo "=== Config assertions ==="
    nix build .#checks.x86_64-linux.routing-nixnginx --accept-flake-config --no-link --print-out-paths 2>&1
    nix build .#checks.x86_64-linux.services-nixnginx --accept-flake-config --no-link --print-out-paths 2>&1
    nix build .#checks.x86_64-linux.fail2ban-filters-nixnginx --accept-flake-config --no-link --print-out-paths 2>&1

# Full test suite including VM integration tests (requires KVM, Linux host)
test-full: test test-integration

# VM integration tests — boots containers in QEMU, asserts services start
test-integration:
    @echo "=== VM integration tests ==="
    @echo "Not yet implemented. Requires native x86_64-linux with KVM."
    @echo "Run inside the forgejo-runner LXC or a bare-metal NixOS host."

# Static analysis
lint:
    @echo "=== Lint ==="
    statix check --ignore 'scratch/**' .
    deadnix --fail .
    nixpkgs-fmt --check **/*.nix

# Format all .nix files
fmt:
    nixpkgs-fmt **/*.nix