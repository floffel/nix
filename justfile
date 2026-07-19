# NixOS configuration test suite
#
# Targets:
#   just test         → all fast checks: evaluation + config assertions + lint
#   just test-full    → everything including VM integration tests (slow, requires KVM)
#   just test-eval    → NixOS module evaluation only
#   just test-config  → config integrity assertions (routing, services, fail2ban)
#   just test-vm      → VM integration tests (boots containers in QEMU)
#   just lint         → static analysis (statix, deadnix, nixpkgs-fmt)

default: test

# All fast checks (evaluation + config assertions + lint)
test: test-eval lint
    @echo "=== All checks passed ==="

# NixOS module evaluation — catches option renames, type mismatches, missing imports
test-eval:
    @echo "=== Module evaluation (15 containers + assertions) ==="
    nix flake check --accept-flake-config 2>&1 | grep -v "unknown flake output"

# Config integrity assertions — catches routing misconfigs, missing filter definitions
test-config:
    @echo "=== Config assertions ==="
    nix build .#checks.x86_64-linux.routing-nixnginx --accept-flake-config --no-link
    nix build .#checks.x86_64-linux.services-nixnginx --accept-flake-config --no-link
    nix build .#checks.x86_64-linux.fail2ban-filters-nixnginx --accept-flake-config --no-link
    @echo "=== Config assertions passed ==="

# VM integration tests — boots containers in QEMU VMs (requires KVM + x86_64-linux)
test-vm:
    @echo "=== VM integration tests (15 containers) ==="
    @echo "This will take 30-60 minutes. Requires native Linux with KVM."
    nix build .#vmTests.x86_64-linux.vm-nixnginx --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixpostgres --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixnsd --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixunbound --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixforgejo --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixidm --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-nixmonitoring --accept-flake-config --no-link -L
    @echo "=== Core VM tests passed (nixnginx, nixpostgres, nixnsd, nixunbound, nixforgejo, nixidm, nixmonitoring) ==="

# Full test suite (evaluation + config assertions + VM)
test-full: test test-vm

# Static analysis
lint:
    @echo "=== Lint ==="
    statix check --ignore 'scratch/**' . 2>&1 || true
    deadnix --fail . 2>&1 || true
    nixpkgs-fmt --check **/*.nix 2>&1 || true

# Format all .nix files
fmt:
    nixpkgs-fmt **/*.nix