# PoC: Unsigned call resolver lets anyone front-run a solver execution and steal the solver's spread

Relay bug bounty report R-03. Run with Foundry (tested with forge 1.9.0):

```
forge test -vv
```

No setup, no network, no fork needed. All dependencies are vendored under `lib/`
(the settlement contracts are the unmodified sources from
`relayprotocol/relay-settlement` at commit `b2f3e0e`).

## What it proves (2/2 tests pass)

- **MAIN** `testFrontrunStealsSolverSpread`: an oracle-signed
  `ExecuteAndWithdrawRequest` (100 input tokens, 90 minimum out) is executed
  first by a frontrunner with their own resolver. The frontrunner keeps the
  full 100 input as spread, returning exactly the 90 minimum; the
  90-minimum withdrawal still settles to the receiver. The solver's identical
  execution then reverts with `RequestAlreadyExecuted`, and the solver earns
  0. The victim is the solver, not the user — the oracle-signed minimum is
  still honored.
- **SECOND** `testBasicCallResolverRetainedFundsAreDrainable`: an unrelated
  EOA drains 50 tokens retained in a `BasicCallResolver` via a direct
  permissionless `execute()` call with an empty call list and a sweep to the
  attacker. This test is the reproduction for a separate finding (R-05,
  `BasicCallResolver.execute` is permissionless); it is kept in this file
  as-is because it shares the same test setup, not because it is part of
  R-03.

## Setup notes

- The test deploys the real `RelayHub`, `RelayAllocator`, and
  `RelayExecutor`, wires the production roles (executor/allocator as hub
  operators, oracle key as `ORACLE_ROLE`), and signs the request with the
  oracle key via `executor.hashExecuteAndWithdrawRequest`.
- The frontrunner's and solver's resolvers are minimal `ICallResolver`
  implementations holding output-token inventory and returning exactly the
  signed minimum.
- Local test only; nothing here touches mainnet.
