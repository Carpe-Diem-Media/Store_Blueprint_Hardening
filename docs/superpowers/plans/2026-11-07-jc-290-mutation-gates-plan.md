# JC-290 mutation authority gates implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Make every payment-method mutation participate in the same binding-then-method lock order and expose the committed-claim observation needed by the following dispatch proof.

**Architecture:** Resource changes acquire bounded PostgreSQL transaction advisory locks before row writes. The payment-method success transaction takes the binding gate before its upsert, so the later Subscription update remains reentrant. Dispatch coordination is the next implementation task in this ticket.

**Tech Stack:** Elixir, Ash 3.37.2, Phoenix, Ecto SQL, PostgreSQL, ExUnit, Stripe API stub, telemetry.

---

## File map

Create the shared mutation helper and its two Ash changes. Modify StoredPaymentMethod actions, the Subscription binding action, and the payment-method success callback. Add focused helper and cross-owner regression tests. Add an IDs-only post-claim observation event for the later dispatch proof. Dispatch session gates and request/response splitting are a separate follow-up plan in this ticket.

## Task 1: Add shared binding and method mutation gates

**Files:**
- Create: `lib/store/subscriptions/payment_method_authority_gate.ex`
- Create: `lib/store/subscriptions/changes/acquire_stored_payment_method_authority.ex`
- Create: `lib/store/subscriptions/changes/acquire_subscription_binding_authority.ex`
- Modify: `lib/store/subscriptions/stored_payment_method.ex`
- Modify: `lib/store/subscriptions/subscription.ex`
- Modify: `lib/store/subscriptions/facade.ex`
- Create: `test/store/subscriptions/payment_method_authority_gate_test.exs`
- Modify: `test/store/subscriptions/stored_payment_method_revocation_test.exs`

- [ ] **Step 1: Add failing key and transaction-context tests.** Add these tests to `payment_method_authority_gate_test.exs`. They establish stable namespace separation, length-delimited values, UUID binary input, and fail-closed transaction behavior before production code exists.

```elixir
defmodule Store.Subscriptions.PaymentMethodAuthorityGateTest do
  use Store.DataCase, async: false

  alias Store.Subscriptions.PaymentMethodAuthorityGate

  test "binding keys use UUID bytes and differ by provider" do
    user_id = Ecto.UUID.generate()

    assert PaymentMethodAuthorityGate.binding_key(user_id, :stripe) !=
             PaymentMethodAuthorityGate.binding_key(user_id, :paystack)
  end

  test "method keys distinguish values that would collide under naive concatenation" do
    assert PaymentMethodAuthorityGate.method_key(:stripe, "ab", "c") !=
             PaymentMethodAuthorityGate.method_key(:stripe, "a", "bc")
  end

  test "transaction locks fail closed outside a Repo transaction" do
    user_id = Ecto.UUID.generate()

    assert {:error, :transaction_required} =
             PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, :stripe)
  end
end
```

- [ ] **Step 2: Run the focused test and confirm the missing module failure.**

Run:

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/payment_method_authority_gate_test.exs
```

Expected: compilation fails because `Store.Subscriptions.PaymentMethodAuthorityGate` does not exist.

- [ ] **Step 3: Implement the gate helper.** Use SHA-256 only to map a canonical key to PostgreSQL's signed 64-bit advisory-lock argument. Collisions may add serialization but must never skip any identity fields. Serialize each field with a 32-bit byte length. Decode user UUIDs to their raw 16-byte form before encoding.

```elixir
defmodule Store.Subscriptions.PaymentMethodAuthorityGate do
  @moduledoc """
  Coordinates Subscription payment-method binding and StoredPaymentMethod writes.

  Advisory locks serialize callers. Subscription and StoredPaymentMethod rows remain
  authoritative, so callers re-read them after acquiring the matching gates.
  """

  alias Store.Repo

  @namespace "store:subscription-payment-method-authority:v1"
  @mutation_query_timeout_ms 5_000

  @type lock_error :: :transaction_required | :lock_unavailable

  @doc "Returns the binding gate key using raw UUID bytes and the provider namespace."
  @spec binding_key(Ecto.UUID.t(), atom()) :: integer()
  def binding_key(user_id, provider) when is_binary(user_id) and is_atom(provider) do
    advisory_key([@namespace, "binding", Ecto.UUID.dump!(user_id), Atom.to_string(provider)])
  end

  @doc "Returns the gate key for the existing global provider method identity."
  @spec method_key(atom(), String.t(), String.t()) :: integer()
  def method_key(provider, customer_ref, payment_method_ref)
      when is_atom(provider) and is_binary(customer_ref) and is_binary(payment_method_ref) do
    advisory_key([
      @namespace,
      "method",
      Atom.to_string(provider),
      customer_ref,
      payment_method_ref
    ])
  end

  @doc "Acquires the binding gate until the current transaction ends; fails outside a transaction."
  @spec lock_binding_for_transaction(Ecto.UUID.t(), atom()) :: :ok | {:error, lock_error()}
  def lock_binding_for_transaction(user_id, provider) do
    with :ok <- require_transaction(),
         :ok <- acquire_xact(binding_key(user_id, provider)) do
      :ok
    end
  end

  @doc "Acquires the method gate inside a transaction after its owner binding gate."
  @spec lock_method_for_transaction(atom(), String.t(), String.t()) ::
          :ok | {:error, lock_error()}
  def lock_method_for_transaction(provider, customer_ref, payment_method_ref) do
    with :ok <- require_transaction(),
         :ok <- acquire_xact(method_key(provider, customer_ref, payment_method_ref)) do
      :ok
    end
  end

  @doc "Checks ownership while the caller holds the binding and global method gates."
  @spec ensure_identity_owner(Ecto.UUID.t(), atom(), String.t(), String.t()) ::
          :ok | {:error, :foreign_identity_owner | lock_error()}
  def ensure_identity_owner(user_id, provider, customer_ref, payment_method_ref) do
    query = """
    SELECT user_id::text
    FROM stored_payment_methods
    WHERE provider = $1
      AND provider_customer_ref = $2
      AND provider_payment_method_ref = $3
    LIMIT 1
    """

    with :ok <- require_transaction() do
      case Repo.query(query, [Atom.to_string(provider), customer_ref, payment_method_ref],
             timeout: @mutation_query_timeout_ms
           ) do
        {:ok, %{rows: []}} -> :ok
        {:ok, %{rows: [[^user_id]]}} -> :ok
        {:ok, %{rows: [[_foreign_user_id]]}} -> {:error, :foreign_identity_owner}
        {:error, _reason} -> {:error, :lock_unavailable}
      end
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
  end

  defp advisory_key(parts) do
    encoded =
      Enum.map(parts, fn part ->
        <<byte_size(part)::unsigned-big-32, part::binary>>
      end)

    <<key::signed-big-64, _rest::binary>> =
      :crypto.hash(:sha256, IO.iodata_to_binary(encoded))

    key
  end

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
  end

  defp acquire_xact(key) do
    case Repo.query("SELECT pg_advisory_xact_lock($1)", [key],
           timeout: @mutation_query_timeout_ms
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :lock_unavailable}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :lock_unavailable}
  end
end
```

The query timeout bounds lock waits. A query/connection failure fails the action and rolls back its transaction. No session setting changes or session locks are introduced by this task. The later dispatch plan owns session cleanup. Do not add a pool, retry loop, migration, dependency, or service.

- [ ] **Step 4: Add resource change modules that return Ash errors rather than raising.** `AcquireStoredPaymentMethodAuthority` branches on `changeset.action_type` and uses persisted `changeset.data` fields on updates. On create, it locks the requested binding and then global method identity, reads the existing identity's `user_id` while the method gate is held, and returns an `Ash.Changeset.add_error/2` if that owner differs. It must not mutate a foreign owner's row. For each successful hook, return the changeset unchanged.

```elixir
defmodule Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority do
  @moduledoc false

  use Ash.Resource.Change

  alias Store.Subscriptions.PaymentMethodAuthorityGate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case changeset.action_type do
        :create -> lock_create(changeset)
        :update -> lock_persisted(changeset)
      end
    end)
  end

  defp lock_create(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    provider = Ash.Changeset.get_attribute(changeset, :provider)
    customer_ref = Ash.Changeset.get_attribute(changeset, :provider_customer_ref)
    payment_method_ref = Ash.Changeset.get_attribute(changeset, :provider_payment_method_ref)

    with :ok <- PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, provider),
         :ok <-
           PaymentMethodAuthorityGate.lock_method_for_transaction(
             provider,
             customer_ref,
             payment_method_ref
           ),
         :ok <-
           PaymentMethodAuthorityGate.ensure_identity_owner(
             user_id,
             provider,
             customer_ref,
             payment_method_ref
           ) do
      changeset
    else
      {:error, :foreign_identity_owner} ->
        Ash.Changeset.add_error(changeset, "provider payment method belongs to another user")

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset, "payment method authority gate unavailable")
    end
  end

  defp lock_persisted(changeset) do
    method = changeset.data

    with :ok <-
           PaymentMethodAuthorityGate.lock_binding_for_transaction(
             method.user_id,
             method.provider
           ),
         :ok <-
           PaymentMethodAuthorityGate.lock_method_for_transaction(
             method.provider,
             method.provider_customer_ref,
             method.provider_payment_method_ref
           ) do
      changeset
    else
      {:error, _reason} ->
        Ash.Changeset.add_error(changeset, "payment method authority gate unavailable")
    end
  end
end
```

`ensure_identity_owner/4` queries `user_id::text`, because Postgrex decodes UUID columns to 16-byte binaries while the input UUID is a string. It returns `:ok` when the identity is absent or owned by the requested user, and `{:error, :foreign_identity_owner}` otherwise. The query uses exactly `(provider, provider_customer_ref, provider_payment_method_ref)`. Keep those identity attributes immutable in update actions.

`AcquireSubscriptionBindingAuthority` reads `user_id` and `provider` from the persisted Subscription on update, acquires the transaction-level binding key in a before-action hook, and adds a generic Ash error if the transaction is missing or the bounded query fails. Do not derive this lock from mutable provider refs in action arguments.

```elixir
defmodule Store.Subscriptions.Changes.AcquireSubscriptionBindingAuthority do
  @moduledoc false

  use Ash.Resource.Change

  alias Store.Subscriptions.PaymentMethodAuthorityGate

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      subscription = changeset.data

      case PaymentMethodAuthorityGate.lock_binding_for_transaction(
             subscription.user_id,
             subscription.provider
           ) do
        :ok -> changeset
        {:error, _reason} ->
          Ash.Changeset.add_error(
            changeset,
            "subscription payment method authority gate unavailable"
          )
      end
    end)
  end
end
```

- [ ] **Step 5: Attach the changes to the four StoredPaymentMethod actions and Subscription binding action.** All hooks run before their data-layer row writes. The upsert must stay transaction-backed, and update actions must keep `require_atomic?(false)`.

```elixir
create :create_or_reuse do
  accept([:user_id, :provider, :provider_customer_ref, :provider_payment_method_ref, :status, :fingerprint])
  upsert?(true)
  upsert_identity(:unique_provider_customer_payment_method)
  upsert_fields([:status, :fingerprint])
  upsert_condition(expr(status != :revoked))
  return_skipped_upsert?(true)
  transaction?(true)
  change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
end

update :mark_active do
  require_atomic?(false)
  accept([])
  change(filter(expr(status != :revoked)))
  change(set_attribute(:status, :active))
  change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
end

update :mark_inactive do
  require_atomic?(false)
  accept([])
  change(filter(expr(status != :revoked)))
  change(set_attribute(:status, :inactive))
  change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
end

update :mark_revoked do
  require_atomic?(false)
  accept([])
  change(set_attribute(:status, :revoked))
  change(Store.Subscriptions.Changes.AcquireStoredPaymentMethodAuthority)
end
```

Add `change(Store.Subscriptions.Changes.AcquireSubscriptionBindingAuthority)` to `set_provider_billing_reference` before the existing optimistic aggregate lock. Keep the existing accepted fields and transition rules.

- [ ] **Step 6: Lock the callback binding before upsert.** In `persist_updated_payment_method/2`, after entering `Repo.transaction/1`, call `PaymentMethodAuthorityGate.lock_binding_for_transaction(subscription.user_id, subscription.provider)` before `persist_updated_payment_method_tx/2`. This duplicates the resource hook's binding gate by design. PostgreSQL transaction advisory locks on the same backend/key are reentrant. The first acquisition must precede the method gate. Map any helper error to the existing normalized `STALE_RECORD` domain error; never expose driver details or change renewal failure state.

Add `PaymentMethodAuthorityGate` to the existing facade aliases. Replace only the transaction callback body in `persist_updated_payment_method/2` with:

```elixir
case PaymentMethodAuthorityGate.lock_binding_for_transaction(
       subscription.user_id,
       subscription.provider
     ) do
  :ok -> persist_updated_payment_method_tx(subscription, payment_intent)
  {:error, _reason} ->
    Repo.rollback(Error.new("STALE_RECORD", "payment method authority gate is unavailable"))
end
```

The existing notification collection and post-commit delivery remain outside this callback.

- [ ] **Step 7: Add behavior tests for every action.** Extend `stored_payment_method_revocation_test.exs` with assertions that same-owner create/reuse, mark-active, mark-inactive, and mark-revoked keep their current results. Add this actual regression to the existing `upsert bypass protection` describe block, using its current helpers. Run it before changing production code and observe that the old upsert wrongly accepts the foreign user. This is the meaningful ownership regression, independent of missing-module compilation.

```elixir
test "another owner cannot reuse or mutate the global provider identity", %{user: user} do
  original = create_spm!(user)
  foreign = TestFixtures.register_user!(email: TestFixtures.unique_email("jc290_foreign"))

  for status <- [:active, :inactive, :revoked] do
    assert {:error, %Ash.Error.Invalid{}} = upsert_spm(foreign, status)
    unchanged = reload_spm!(original.id)
    assert unchanged.user_id == original.user_id
    assert unchanged.status == original.status
    assert unchanged.fingerprint == original.fingerprint
  end

  assert identity_count!() == 1
end
```

Existing legal-transition and revoked-row tests cover all four actions. Keep them. In `payment_method_authority_gate_test.exs`, also prove the transaction function succeeds when actually inside `Repo.transaction/1`:

```elixir
test "binding and method gates are reentrant within one transaction" do
  user_id = Ecto.UUID.generate()

  assert {:ok, :ok} = Repo.transaction(fn ->
    assert :ok = PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, :stripe)
    assert :ok = PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, :stripe)
    assert :ok = PaymentMethodAuthorityGate.lock_method_for_transaction(:stripe, "cus_jc290", "pm_jc290")
  end)
end
```

Add the observation seam after a successful `attach_and_claim_dispatch_for_system/1` in `request_off_session_renewal_charge/6`, before `submit_claimed_renewal_collection/5`. It carries no provider reference or secret and only observes a newly committed claim:

```elixir
if claim.dispatch_claimed? do
  :telemetry.execute(
    [:store, :subscriptions, :renewal_charge_dispatch_claimed],
    %{},
    %{
      source: :fresh_dispatch,
      subscription_id: subscription.id,
      renewal_attempt_id: bound_attempt.id,
      collection_attempt_id: claim.collection_attempt.id,
      payment_intent_id: claim.payment_intent.id
    }
  )
end
```

This event grants no dispatch authority. Task 2 will use it to reproduce the interval between committed claim and request initiation before wiring session gates.

- [ ] **Step 8: Run the focused tests.**

Run:

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/subscriptions/payment_method_authority_gate_test.exs test/store/subscriptions/stored_payment_method_revocation_test.exs test/store/subscriptions/optimistic_aggregate_version_test.exs
```

Expected: all focused tests pass. Format the touched Elixir files, then run:

```bash
STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted lib/store/subscriptions/payment_method_authority_gate.ex lib/store/subscriptions/changes/acquire_stored_payment_method_authority.ex lib/store/subscriptions/changes/acquire_subscription_binding_authority.ex lib/store/subscriptions/stored_payment_method.ex lib/store/subscriptions/subscription.ex lib/store/subscriptions/facade.ex test/store/subscriptions/payment_method_authority_gate_test.exs test/store/subscriptions/stored_payment_method_revocation_test.exs
```

## Task completion

- [ ] Run the ownership regression against old production code first and retain its failure output under ignored `tmp/jc290/`.
- [ ] Run the focused command above, plus existing `renewal_collection_attempts_test.exs` and `cancellation_renewal_authority_test.exs`, after implementation. Do not change their expected financial semantics.
- [ ] Run `git diff --check`, inspect every changed file, and commit only this task's listed production and test files.

```bash
git add lib/store/subscriptions/payment_method_authority_gate.ex lib/store/subscriptions/changes/acquire_stored_payment_method_authority.ex lib/store/subscriptions/changes/acquire_subscription_binding_authority.ex lib/store/subscriptions/stored_payment_method.ex lib/store/subscriptions/subscription.ex lib/store/subscriptions/facade.ex test/store/subscriptions/payment_method_authority_gate_test.exs test/store/subscriptions/stored_payment_method_revocation_test.exs
git commit -m "fix(subscriptions): serialize payment method authority mutations"
```

- [ ] Report exact head, observed RED and GREEN results, files changed, and any uncertainty to the controller. The controller will obtain separate spec and quality reviews before the dispatch implementation begins.

## Root self-review

This bounded task covers the design's shared mutation participation, binary key encoding, lock order, cross-owner protection, callback ordering, existing terminal revocation, and observation seam. It intentionally does not certify provider-start ordering. That requires the following dispatch task and real-connection proof. Every function used in the snippets exists in this task or the current source. The test helpers are the existing revocation module helpers. No historical governance process gate, frontend work, or additional worktree is needed.
