# JC-290 recovery error preservation

## Problem and authority

The strict contract preserves possible provider contact until checkpoint-D evidence resolves it. Read errors and rejected provider evidence cannot establish a decline or advance business dunning.

At local checkpoint `97c38fd`, two isolated database reproductions violated that rule. A Stripe GET returning HTTP 503 and a success body missing its provider ID both left the collection financially unresolved but marked the attempt failed, made the source past due and incremented dunning to one. The error codes remained `PAYMENT_PROVIDER_DOWN` and `PAYMENT_EVENT_UNVERIFIED`. The migrated negative-evidence facade test independently exposed the same failure.

The generic classifier also exists at reference base `6001f015ff3cc19d47ca123e6c0273a688c9ab91`. This is a pre-existing acceptance gap exposed by recovery-test migration.

## Correction

Keep the original error and exact collection identity. Narrow the reached-result classifier so only the `PAYMENT_FAILED` result produced from canonical `verified_terminal_non_success` enters business failure settlement. Return other observation/application errors directly. Inspect the complete call graph to ensure an adapter read error cannot supply that terminal result. Retain explicit authentication handling and existing stale/no-op branches. Fresh missing-method failure before any prepared collection keeps its existing contract.

No provider capability, new request, new collection, schema, dependency, queue or notification behavior is added. The correction performs no new query or allocation of a persistent resource.

## Work and verification

1. Add permanent strict-dispatch regressions for the two observed error paths before changing production. Assert the original error, unchanged attempt/source dunning and periods, unresolved exact collection/PaymentIntent and no financial application or new request identity. Use realistic order amounts and only sanctioned Stripe stubs.
2. Observe those regressions fail, then make the smallest classifier correction in `lib/store/subscriptions/facade.ex`.
3. Run strict tests and both migrated facade/monotonicity suites. Preserve certified canceled/authentication coverage and fresh missing-method behavior. Run static/types checks, obtain independent spec then quality review, and append a focused checkpoint commit.

Root owns Mix, DevCore databases, Git and external state. The migration worker's two files stay frozen during this correction. PR #216 stays draft and on hold, with no merge or push as part of this checkpoint. Broader lifecycle migration, parent/descendant propagation, final whole-PR validation and exact-head CI remain pending.

## Checkpoint evidence

Both isolated database probes failed before the fix. Both permanent regressions also failed at the unchanged-source assertion because dunning advanced. After the classifier correction, the strict, authority-gate, runtime-config, facade and monotonicity modules passed 76 tests. The existing unused optional-default warning in the monotonicity helper remains unchanged.

The canonical collection retains its exact PaymentIntent link, stored provider ID and reservation generation. The attempt's legacy PaymentIntent mirror is cleared by the existing checkout-preparation path, so the new regressions verify identity through the collection and reload the PaymentIntent itself. They also verify the attempt stays processing, the source's billing fields stay unchanged, inventory remains held, and no payment application appears.

Independent spec and quality reviews found no actionable defect in this scoped correction. Their reports do not certify the whole PR or its final CI.

`mix check.static` and `mix check.types` passed after the focused tests. The type check reported the existing 144 filtered warnings and two unnecessary skips; this correction adds no filter. No schema changes require another migration check for this checkpoint.
