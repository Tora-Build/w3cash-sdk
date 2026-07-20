#!/usr/bin/env bash
# Verify the W3Cash core on X Layer mainnet (196) via OKLink.
#
# Prereq: an OKLink API key (free) — apply at https://www.oklink.com/account/my-api
#   export OKLINK_API_KEY=<your key>
#   bash script/verify-xlayer-mainnet.sh
#
# Compiler settings (solc 0.8.28, optimizer 200, via_ir) are read from foundry.toml
# and must match the deployed bytecode (they do — same repo/commit that deployed).
set -euo pipefail

: "${OKLINK_API_KEY:?set OKLINK_API_KEY (apply at oklink.com)}"

VERIFIER_URL="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER"
DEPLOYER=0xEfdB15EE6e7C7C7906cb230AfF1EDb75CcBaA74F
REGISTRY=0x58F35BE6A5e3D2be4C3575853043322B02FEeD84
PROCESSOR=0x3C06E44bD4d09328a4c374174b8e325c0C674b6E

verify() { # <address> <path:name> <ctor-arg-address>
  echo "── verifying $2 @ $1 (ctor arg $3)"
  forge verify-contract "$1" "$2" \
    --verifier oklink --verifier-url "$VERIFIER_URL" --api-key "$OKLINK_API_KEY" \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$3")" \
    --watch
}

# registry(initialOwner=deployer); processor(registry); each adapter(processor)
verify "$REGISTRY"                                     src/w3cash/AdapterRegistry.sol:AdapterRegistry     "$DEPLOYER"
verify "$PROCESSOR"                                    src/w3cash/W3CashProcessorLegacy.sol:W3CashProcessorLegacy     "$REGISTRY"
verify 0xbc7b155057Bb78BB8bF9c9F9Fa6bFCc931aEAF38      src/w3cash/adapters/TransferAdapter.sol:TransferAdapter   "$PROCESSOR"
verify 0x1aF3cB8B270Db3e71fC979543c32B87709EA191f      src/w3cash/adapters/ApproveAdapter.sol:ApproveAdapter     "$PROCESSOR"
verify 0x8629b9ca457F4088ec8346FAED61DA858FDB498d      src/w3cash/adapters/WaitAdapter.sol:WaitAdapter           "$PROCESSOR"
verify 0x50293aD4e42593A8b081960c991c198729E81192      src/w3cash/adapters/QueryAdapter.sol:QueryAdapter         "$PROCESSOR"
verify 0x12A38bc9E3bD2359265cE70451777eDe2fd875A3      src/w3cash/adapters/GasPriceAdapter.sol:GasPriceAdapter   "$PROCESSOR"
verify 0xBE566c267A0D350e1D647Ccb621cC657FA3a1d50      src/w3cash/adapters/TimeRangeAdapter.sol:TimeRangeAdapter "$PROCESSOR"
verify 0xaa3Ffae62A8Af00d08Ac395e9551776b0A01E492      src/w3cash/adapters/SignatureAdapter.sol:SignatureAdapter "$PROCESSOR"

echo "✅ all 9 contracts submitted for verification on OKLink (X Layer mainnet 196)"
