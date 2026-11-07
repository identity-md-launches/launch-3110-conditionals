# CONDITIONALS (COND)

An immutable ERC-20 for conditionals.xyz. The entire supply is minted once to the
immediate deployer in the constructor.

| Parameter | Value |
| --- | --- |
| Contract | `src/ConditionalsToken.sol:ConditionalsToken` |
| Name | `CONDITIONALS` |
| Symbol | `COND` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY` |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Intended launch chain | Ethereum, chain ID `1` |

## Behavior and assumptions

The brief's website identifies the project; no additional conditional execution,
oracle, prediction-market, or website integration behavior was specified. This
delivery implements the requested token only. There are no application contracts.

The implementation inherits the vendored OpenZeppelin ERC-20 without changing its
transfer or allowance logic. Transfers deliver the exact amount, including transfers
through a launch factory, distributor, or pool manager. No tax, fee, burn, rebase,
pause, blocklist, owner, minter role, proxy, or upgrade mechanism exists. The only
mint call is in the constructor; there is no external mint or burn function.

`transfer`, `approve`, and `transferFrom` return `true` on success and revert on
failure with ERC-6093 errors. Zero-value transfers are supported. Transfers to the
zero address and approvals to the zero spender revert. Self-transfers preserve
balances. Finite allowances decrease when spent; `type(uint256).max` is treated as
unlimited and is not decreased. `approve` replaces the existing allowance. Even
the holder must have an allowance to call `transferFrom` on their own balance;
holders can instead call `transfer` directly.

The constructor emits one `Transfer` from the zero address for the full supply.
Transfers emit `Transfer`; explicit approvals emit `Approval`. This dependency
version does not emit `Approval` when `transferFrom` consumes allowance, so
integrations should query `allowance` for its current value.

## Build and verify

Install Foundry and provide Solidity `0.8.26`. Every Solidity dependency needed by
this project is already included as ordinary files under `lib/`; no install step,
submodule, RPC endpoint, key, or network access is required to build or test when
that compiler is available.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xc8b14164da9fb30cd6f9ddb7742526178af2312f9edc4dd9d1d0d23269acfc17 forge test
forge fmt --check
```

`foundry.toml` pins Solidity `0.8.26`, Cancun EVM, optimizer with 200 runs,
`bytecode_hash = "none"`, and the same fuzz seed. It enables neither FFI nor
filesystem permissions. Unit fuzz tests run 512 cases each. Stateful invariant
testing runs 128 sequences of up to 64 actions, including successful and rejected
transfers, approvals, and delegated transfers against an independent balance and
allowance model. Tests create their own deployments and actors, read no environment
variables, and use no forks or shared external state.

Unit tests cover metadata and supply, constructor events, CREATE2 factory minting,
exact launch distribution and claim transfers, transfer events and accounting,
zero/self/full-balance transfers, no recipient callbacks, approval replacement and
revocation, finite/unlimited allowances, unauthorized spending, insufficient funds,
invalid addresses, rollback on failure, unsupported administrative calls, and
rejected ETH payments.

The local launch-flow test models the token movements only; it does not deploy a
Uniswap PoolManager or reproduce the full protected launch harness. The supplied
protected tests are for the independent launch verifier, which provides its own
factory, pool, manifest, and supporting contracts.

## Deployment and operational responsibilities

Deploy `ConditionalsToken` directly from the compiled creation bytecode, without
constructor arguments or initialization calls. The creation artifact is
`out/ConditionalsToken.sol/ConditionalsToken.json`. All dependencies are inlined;
there are no linked-library addresses or outside service settings.

The constructor credits `msg.sender`. With the prescribed factory launch, the
factory receives all `10^27` base units; a direct EOA deployment instead credits
that EOA. There is no recipient override and the transaction origin receives no
special treatment. The factory must perform the distribution. The token does not
reserve or distribute allocations itself.

The later launch manifest step records `ConditionalsToken`, the metadata and base
unit supply above, and zero application contracts. That step owns `launch.json`;
it is deliberately not included here. The provided launch terms are:

- The factory sends 10% to its MerkleDistributor, seeds the pool with 70%, and
  forwards the remaining 20% to `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`.
- The pair is IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` on Ethereum.
- Pool fee is `12500` (1.25%), tick spacing `60`, and recorded initial-price
  provenance is `79228162514264337593543950336`.
- The initial market cap is `2500000000000000000000` in the paired token's base
  units. The launch deployer derives the actual pool opening price from these
  economics and the deployed token address.

These are supplied launch terms, not constructor inputs, on-chain dependencies, or
token-level fees. The launch service is responsible for the manifest, chain and
address validation, factory transactions, distributor claims infrastructure, pool
initialization, and explorer verification. This project does not broadcast
transactions or require access to a wallet. Before release, the launch service
should independently review the source and confirm the deployed metadata, total
supply, constructor mint recipient, and final allocation balances.

## After launch

No settings or owner actions are required. No administrator can recover lost
tokens, reverse a transfer, freeze a holder, or fix the deployed code. Tokens sent
to this token contract itself or to an address without a means of sending them
back cannot be rescued. Ordinary native ETH transfers are rejected; forcibly sent
ETH and unrelated tokens also have no recovery path.

Holders control their own balances and allowances. Applications should request
only needed allowances and let users revoke them. To replace an existing nonzero
allowance safely against the usual ERC-20 approval race, revoke it and wait for
confirmation before approving a new amount; revocation cannot undo a spend that
has already executed. Unlimited allowances remain an explicit holder choice.

## Dependencies and review scope

The required OpenZeppelin Contracts v5.0.2 files and forge-std v1.9.7 sources are
vendored unchanged. `DEPENDENCIES.json` records upstream URLs, tags, and exact
commits. Each dependency directory contains its upstream license and `SHA256SUMS`.
OpenZeppelin supplies the production ERC-20 implementation; forge-std is used only
by tests. No external library linking is required.

The security review for this delivery focuses on the single constructor mint,
absence of privileged entry points, standard allowance authorization, exact
transfers, conservation of supply, and atomic failure behavior. The token makes
no external calls and has no oracle, randomness, signature, or upgrade path.
Local Foundry checks are not an independent security audit. Slither, Mythril, and
the network's protected deployment harness are not part of the local test results.
