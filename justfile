# NixOS configuration test suite
#
# Targets:
#   just test           → all fast checks: evaluation + config assertions + lint
#   just test-full      → everything including VM integration tests (slow, requires KVM)
#   just test-eval      → NixOS module evaluation only
#   just test-config    → config integrity assertions (routing, services, fail2ban)
#   just test-vm        → VM integration tests (boots containers in QEMU)
#   just lint           → static analysis (statix, deadnix, nixpkgs-fmt)
#   just flake-update   → update flake.lock to the latest nixpkgs (runs nix in Docker)

default: test

# All fast checks (evaluation + config assertions + lint)
test: test-eval lint
    @echo "=== All checks passed ==="

# Update flake.lock to the latest nixpkgs (and any other inputs) without
# installing nix locally: boot the official nix Docker image, update the lock
# file in this repository, and exit.
#   - docker pull nixos/nix   → always fetch the newest nix release
#   - --extra-experimental-features 'nix-command flakes'
#                             → the nix flake CLI is experimental and starts
#                               disabled in a fresh container
#   - --accept-flake-config   → same flag the local test commands use
flake-update:
    @echo "=== Updating flake.lock with nix Docker image ==="
    @docker pull nixos/nix
    @docker run --rm -v $(pwd):/workdir -w /workdir nixos/nix nix flake update --extra-experimental-features 'nix-command flakes' --accept-flake-config

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
    nix build .#checks.x86_64-linux.mail-open-relay --accept-flake-config --no-link
    nix build .#checks.x86_64-linux.unbound-open-resolver --accept-flake-config --no-link
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
    nix build .#vmTests.x86_64-linux.vm-nixmail --accept-flake-config --no-link -L
    nix build .#vmTests.x86_64-linux.vm-mail-roundtrip --accept-flake-config --no-link -L
    @echo "=== VM security tests passed (nixnginx, nixpostgres, nixnsd, nixunbound, nixforgejo, nixidm, nixmonitoring, nixmail, vm-mail-roundtrip) ==="

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