defmodule Store.Subscriptions.Sbh4002DurablePeriodBoundaryTerminalizationTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info
  alias Oban.Job
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo

  alias Store.Subscriptions.{
    AccessEffect,
    Facade,
    PlanRevision,
    RenewalAttempt,
    RenewalCollectionAttempt,
    RenewalCollectionAttempts,
    Subscription
  }

  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.ReachedRenewalFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.RunDueScheduledCancellationsWorker

  setup context do
    StripeAPIStub.setup_default(context)
    :ok
  end

  test "Subscription stores a timestamp or exact renewal attempt as its scheduled target" do
    assert boundary = Info.attribute(Subscription, :cancel_at_period_end_at)
    assert boundary.type == Ash.Type.UtcDatetimeUsec
    assert boundary.allow_nil?
    refute boundary.public?

    assert attempt_id = Info.attribute(Subscription, :cancel_after_renewal_attempt_id)
    assert attempt_id.type == Ash.Type.UUID
    assert attempt_id.allow_nil?
    refute attempt_id.public?

    assert cancellation_flag = Info.attribute(Subscription, :cancel_at_period_end)
    assert cancellation_flag.public?
  end

  test "database rejects a nonexistent current dunning RenewalAttempt" do
    {_customer, subscription} = create_subscription("jc247_missing_dunning_attempt")
    missing_attempt_id = Ecto.UUID.generate()

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :foreign_key_violation,
                constraint: "subscriptions_current_dunning_renewal_attempt_id_fkey"
              }
            }} =
             Repo.query(
               "UPDATE subscriptions SET status = 'past_due', current_dunning_renewal_attempt_id = $2 WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(missing_attempt_id)]
             )
  end

  test "database restricts non-null current dunning identity to past_due and suspended" do
    {_customer, subscription} = create_subscription("jc247_dunning_status_check")
    attempt = create_renewal_attempt(subscription)

    for status <- [:active, :canceled, :expired] do
      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :check_violation,
                  constraint: "subscriptions_current_dunning_renewal_attempt_status_check"
                }
              }} =
               Repo.query(
                 "UPDATE subscriptions SET status = $2, current_dunning_renewal_attempt_id = $3 WHERE id = $1",
                 [
                   Ecto.UUID.dump!(subscription.id),
                   Atom.to_string(status),
                   Ecto.UUID.dump!(attempt.id)
                 ]
               )
    end

    for status <- [:past_due, :suspended] do
      assert {:ok, %{num_rows: 1}} =
               Repo.query(
                 "UPDATE subscriptions SET status = $2, current_dunning_renewal_attempt_id = NULL WHERE id = $1",
                 [Ecto.UUID.dump!(subscription.id), Atom.to_string(status)]
               )
    end
  end

  test "database rejects a scheduled cancellation without exactly one target" do
    {_customer, subscription} = create_subscription("jc242_missing_target")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE subscriptions SET cancel_at_period_end = true WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id)]
             )
  end

  test "database rejects target columns when the compatibility flag is false" do
    {_customer, subscription} = create_subscription("jc242_unflagged_target")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE subscriptions SET cancel_at_period_end_at = $2 WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id), subscription.current_period_end_at]
             )
  end

  test "database rejects both funded and awaiting target forms at once" do
    {_customer, subscription} = create_subscription("jc242_multiple_targets")
    attempt = create_renewal_attempt(subscription)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE subscriptions SET cancel_at_period_end = true, cancel_at_period_end_at = $2, cancel_after_renewal_attempt_id = $3 WHERE id = $1",
               [
                 Ecto.UUID.dump!(subscription.id),
                 subscription.current_period_end_at,
                 Ecto.UUID.dump!(attempt.id)
               ]
             )
  end

  test "scheduled cancellation rejects an attempt owned by another Subscription" do
    {_customer, subscription} = create_subscription("jc242_cross_owner_target")
    {_other_customer, other_subscription} = create_subscription("jc242_other_owner_target")
    other_attempt = create_renewal_attempt(other_subscription)

    assert {:error, _reason} =
             subscription
             |> Ash.Changeset.for_update(
               :cancel_at_period_end_transition,
               %{cancel_after_renewal_attempt_id: other_attempt.id},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :foreign_key_violation,
                constraint: "subscriptions_cancel_after_renewal_attempt_owner_fkey"
              }
            }} =
             Repo.query(
               "UPDATE subscriptions SET cancel_at_period_end = true, cancel_after_renewal_attempt_id = $2 WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(other_attempt.id)]
             )

    unchanged = fetch_subscription!(subscription.id)
    refute unchanged.cancel_at_period_end
    assert is_nil(unchanged.cancel_after_renewal_attempt_id)
  end

  test "migration refuses a legacy cancellation with multiple boundary attempts" do
    boundary_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    subscription_id = Ecto.UUID.generate()

    Repo.query!("""
    CREATE TEMP TABLE subscriptions (
      id uuid PRIMARY KEY,
      cancel_at_period_end boolean NOT NULL,
      current_period_end_at timestamptz,
      status text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TEMP TABLE renewal_attempts (
      id uuid PRIMARY KEY,
      subscription_id uuid NOT NULL,
      period_start_at timestamptz NOT NULL,
      period_end_at timestamptz NOT NULL,
      order_id uuid,
      payment_intent_id uuid,
      status text NOT NULL,
      failure_code text
    )
    """)

    Repo.query!("CREATE TEMP TABLE orders (id uuid PRIMARY KEY, state text NOT NULL)")

    Repo.query!("""
    CREATE TEMP TABLE payment_applications (
      order_id uuid NOT NULL,
      payment_intent_id uuid NOT NULL
    )
    """)

    Repo.query!("CREATE TEMP TABLE payment_intents (id uuid PRIMARY KEY, order_id uuid NOT NULL)")

    Repo.query!(
      "INSERT INTO subscriptions (id, cancel_at_period_end, current_period_end_at, status) VALUES ($1, true, $2, 'active')",
      [Ecto.UUID.dump!(subscription_id), boundary_at]
    )

    for _ <- 1..2 do
      Repo.query!(
        "INSERT INTO renewal_attempts (id, subscription_id, period_start_at, period_end_at, status) VALUES ($1, $2, $3, $4, 'pending')",
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(subscription_id),
          boundary_at,
          DateTime.add(boundary_at, 30, :day)
        ]
      )
    end

    migration = Module.concat(Store.Repo.Migrations, "Jc242DurablePeriodBoundaryTargets")

    assert [migration_path] =
             Path.wildcard(
               Path.expand(
                 "../../../priv/repo/migrations/*_jc242_durable_period_boundary_targets.exs",
                 __DIR__
               )
             )

    unless Code.ensure_loaded?(migration) do
      Code.require_file(migration_path)
    end

    assert Code.ensure_loaded?(migration)
    preflight_sql = migration.legacy_target_preflight_sql()

    assert {:error, %Postgrex.Error{postgres: %{code: :raise_exception}}} =
             Repo.query(preflight_sql)
  end

  test "legacy migration keeps a financial-only application awaiting commercial reconciliation" do
    Repo.query!("""
    CREATE TEMP TABLE subscriptions (
      id uuid PRIMARY KEY,
      cancel_at_period_end boolean NOT NULL,
      current_period_start_at timestamptz NOT NULL,
      current_period_end_at timestamptz NOT NULL,
      next_renewal_at timestamptz NOT NULL,
      current_plan_revision_id uuid NOT NULL,
      subscription_plan_id uuid NOT NULL,
      variant_id uuid NOT NULL,
      quantity integer NOT NULL,
      renewal_amount_minor bigint NOT NULL,
      renewal_currency text NOT NULL,
      membership_key text,
      cancel_at_period_end_at timestamptz,
      cancel_after_renewal_attempt_id uuid
    )
    """)

    Repo.query!("""
    CREATE TEMP TABLE renewal_attempts (
      id uuid PRIMARY KEY,
      subscription_id uuid NOT NULL,
      period_start_at timestamptz NOT NULL,
      period_end_at timestamptz NOT NULL,
      order_id uuid NOT NULL,
      payment_intent_id uuid NOT NULL,
      plan_revision_id uuid NOT NULL,
      variant_id uuid NOT NULL,
      quantity integer NOT NULL,
      amount_minor bigint NOT NULL,
      currency text NOT NULL,
      charged_contract_snapshot jsonb NOT NULL
    )
    """)

    Repo.query!(
      "CREATE TEMP TABLE plan_revisions (id uuid PRIMARY KEY, subscription_plan_id uuid NOT NULL)"
    )

    Repo.query!("CREATE TEMP TABLE orders (id uuid PRIMARY KEY, state text NOT NULL)")
    Repo.query!("CREATE TEMP TABLE payment_intents (id uuid PRIMARY KEY, order_id uuid NOT NULL)")

    Repo.query!(
      "CREATE TEMP TABLE payment_applications (order_id uuid NOT NULL, payment_intent_id uuid NOT NULL)"
    )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    subscription_id = Ecto.UUID.generate()
    attempt_id = Ecto.UUID.generate()
    plan_id = Ecto.UUID.generate()
    revision_id = Ecto.UUID.generate()
    variant_id = Ecto.UUID.generate()
    order_id = Ecto.UUID.generate()
    payment_intent_id = Ecto.UUID.generate()
    period_start_at = DateTime.add(now, -90 * 86_400, :second)
    boundary_at = DateTime.add(now, -60 * 86_400, :second)
    period_end_at = DateTime.add(now, -30 * 86_400, :second)

    Repo.query!(
      "INSERT INTO subscriptions (id, cancel_at_period_end, current_period_start_at, current_period_end_at, next_renewal_at, current_plan_revision_id, subscription_plan_id, variant_id, quantity, renewal_amount_minor, renewal_currency, membership_key) VALUES ($1, true, $2, $3, $3, $4, $5, $6, 1, 1999, 'USD', 'membership:jc242_migration')",
      [
        Ecto.UUID.dump!(subscription_id),
        period_start_at,
        boundary_at,
        Ecto.UUID.dump!(revision_id),
        Ecto.UUID.dump!(plan_id),
        Ecto.UUID.dump!(variant_id)
      ]
    )

    Repo.query!(
      "INSERT INTO plan_revisions (id, subscription_plan_id) VALUES ($1, $2)",
      [Ecto.UUID.dump!(revision_id), Ecto.UUID.dump!(plan_id)]
    )

    Repo.query!(
      "INSERT INTO renewal_attempts (id, subscription_id, period_start_at, period_end_at, order_id, payment_intent_id, plan_revision_id, variant_id, quantity, amount_minor, currency, charged_contract_snapshot) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1, 1999, 'USD', $9::jsonb)",
      [
        Ecto.UUID.dump!(attempt_id),
        Ecto.UUID.dump!(subscription_id),
        boundary_at,
        period_end_at,
        Ecto.UUID.dump!(order_id),
        Ecto.UUID.dump!(payment_intent_id),
        Ecto.UUID.dump!(revision_id),
        Ecto.UUID.dump!(variant_id),
        Jason.encode!(%{
          "entitlement_kind" => "membership_access",
          "entitlement_scope_key" => "membership:jc242_migration"
        })
      ]
    )

    Repo.query!("INSERT INTO orders (id, state) VALUES ($1, 'paid')", [Ecto.UUID.dump!(order_id)])

    Repo.query!("INSERT INTO payment_intents (id, order_id) VALUES ($1, $2)", [
      Ecto.UUID.dump!(payment_intent_id),
      Ecto.UUID.dump!(order_id)
    ])

    Repo.query!(
      "INSERT INTO payment_applications (order_id, payment_intent_id) VALUES ($1, $2)",
      [
        Ecto.UUID.dump!(order_id),
        Ecto.UUID.dump!(payment_intent_id)
      ]
    )

    migration = Module.concat(Store.Repo.Migrations, "Jc242DurablePeriodBoundaryTargets")

    assert [migration_path] =
             Path.wildcard(
               Path.expand(
                 "../../../priv/repo/migrations/*_jc242_durable_period_boundary_targets.exs",
                 __DIR__
               )
             )

    unless Code.ensure_loaded?(migration) do
      Code.require_file(migration_path)
    end

    assert Code.ensure_loaded?(migration)
    assert {:ok, %{num_rows: 1}} = Repo.query(migration.legacy_target_backfill_sql())

    assert [[nil, stored_attempt_id]] =
             Repo.query!(
               "SELECT cancel_at_period_end_at, cancel_after_renewal_attempt_id FROM subscriptions WHERE id = $1",
               [Ecto.UUID.dump!(subscription_id)]
             ).rows

    assert Ecto.UUID.load!(stored_attempt_id) == attempt_id
  end

  test "scheduling before B stores the funded boundary and blocks an already-queued renewal" do
    {customer, subscription} = create_subscription("jc242_before_b")
    boundary_at = subscription.current_period_end_at

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_at_period_end
    assert scheduled.cancel_at_period_end_at == boundary_at
    assert is_nil(scheduled.cancel_after_renewal_attempt_id)

    assert {:ok, duplicate} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert duplicate.cancel_at_period_end_at == boundary_at
    assert is_nil(duplicate.cancel_after_renewal_attempt_id)

    assert {:ok, :noop} =
             Facade.process_due_subscription_renewal_for_system(subscription.id,
               now: DateTime.add(boundary_at, 1, :second)
             )

    assert [] == renewal_attempts(subscription.id)
  end

  test "B-first unpaid occurrence remains the exact awaiting target after its hypothetical end" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_after_b", %{started_at: DateTime.add(now, -80 * 86_400, :second)})

    StripeAPIStub.stub_unexpected!("fresh renewal must not contact Stripe")

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [attempt] = renewal_attempts(subscription.id)
    assert attempt.status == :processing
    assert DateTime.compare(attempt.period_end_at, now) == :lt

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.status == :active
    assert scheduled.cancel_at_period_end
    assert is_nil(scheduled.cancel_at_period_end_at)
    assert scheduled.cancel_after_renewal_attempt_id == attempt.id

    current_attempt = List.first(renewal_attempts(subscription.id))
    assert current_attempt.id == attempt.id
    assert current_attempt.failure_code == nil
  end

  test "suspension preserves an awaiting exact occurrence cancellation target" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_suspend_awaiting", %{
        started_at: DateTime.add(now, -80 * 86_400, :second)
      })

    StripeAPIStub.stub_unexpected!("fresh renewal must not contact Stripe")

    assert {:error, %{code: "RENEWAL_DISPATCH_UNAVAILABLE"}} =
             Facade.process_due_subscription_renewal_for_system(subscription.id, now: now)

    [attempt] = renewal_attempts(subscription.id)

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id

    past_due =
      scheduled
      |> Ash.Changeset.for_update(
        :mark_past_due_transition,
        %{
          billing_status_reason: "PAYMENT_FAILED",
          past_due_since_at: now,
          failed_payment_boundary_at: scheduled.current_period_end_at,
          dunning_attempt_count: 1,
          next_retry_at: nil,
          retry_suppressed_at: nil
        },
        context: %{system?: true}
      )
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    suspended =
      past_due
      |> Ash.Changeset.for_update(:mark_suspended_transition, %{}, context: %{system?: true})
      |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    assert suspended.status == :suspended
    assert suspended.cancel_at_period_end
    assert suspended.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(suspended.cancel_at_period_end_at)
  end

  test "exact paid application promotes the awaiting occurrence to its funded end" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_paid_promotion", %{
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(scheduled.cancel_at_period_end_at)
    assert attempt.failure_code == nil

    payment_intent = reached.payment_intent
    payment_attempt = observe_and_apply_success!(reached)

    collection = collection_for_attempt!(attempt.id)
    assert collection.financial_outcome == :verified_success
    assert collection.payment_attempt_id == payment_attempt.id

    assert {:ok, handoff} = RenewalCollectionAttempts.success_handoff_for_system(collection.id)
    assert handoff.renewal_attempt_id == attempt.id
    assert handoff.payment_intent_id == payment_intent.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id
             )

    promoted = fetch_subscription!(subscription.id)
    assert promoted.status == :active
    assert promoted.cancel_at_period_end
    assert promoted.cancel_at_period_end_at == attempt.period_end_at
    assert is_nil(promoted.cancel_after_renewal_attempt_id)
    assert promoted.current_period_end_at == attempt.period_end_at
    assert fetch_attempt!(attempt.id).status == :succeeded
  end

  test "paid success for a different occurrence leaves the exact target awaiting" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_different_occurrence", %{
        started_at: DateTime.add(now, -40 * 86_400, :second)
      })

    enable_stripe!()
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id

    later_attempt =
      create_renewal_attempt_at(
        subscription,
        attempt.period_end_at,
        "jc242:different-occurrence:#{subscription.id}"
      )

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               "UPDATE subscriptions SET cancel_after_renewal_attempt_id = $2 WHERE id = $1",
               [Ecto.UUID.dump!(subscription.id), Ecto.UUID.dump!(later_attempt.id)]
             )

    payment_intent = reached.payment_intent
    payment_attempt = observe_and_apply_success!(reached)

    collection = collection_for_attempt!(attempt.id)
    assert collection.payment_attempt_id == payment_attempt.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id
             )

    current = fetch_subscription!(subscription.id)
    assert current.status == :active
    assert current.cancel_at_period_end
    assert current.cancel_after_renewal_attempt_id == later_attempt.id
    assert is_nil(current.cancel_at_period_end_at)
    assert current.current_period_end_at == attempt.period_end_at
  end

  test "late exact paid reconciliation cancels at the historical funded boundary" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_late_paid", %{
        started_at: DateTime.add(now, -80 * 86_400, :second)
      })

    _grant = issue_subscription_grant!(subscription)

    enable_stripe!()
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    assert DateTime.compare(attempt.period_end_at, now) == :lt

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_after_renewal_attempt_id == attempt.id

    payment_intent = reached.payment_intent
    payment_attempt = observe_and_apply_success!(reached)

    collection = collection_for_attempt!(attempt.id)
    assert collection.financial_outcome == :verified_success
    assert collection.payment_attempt_id == payment_attempt.id

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id
             )

    canceled = fetch_subscription!(subscription.id)
    assert canceled.status == :canceled
    assert canceled.canceled_reason == "canceled_period_end"
    assert is_nil(canceled.current_dunning_renewal_attempt_id)
    assert canceled.canceled_at == attempt.period_end_at
    assert canceled.ended_at == attempt.period_end_at
    assert canceled.current_period_end_at == attempt.period_end_at
    assert is_nil(canceled.cancel_at_period_end_at)
    assert is_nil(canceled.cancel_after_renewal_attempt_id)
    assert fetch_attempt!(attempt.id).status == :succeeded

    effect = fetch_current_access_effect!(subscription.id)
    assert effect.disposition == :non_effective
    assert effect.source_version == canceled.aggregate_version
    assert effect.status == :applied
    assert count_scheduled_cancellation_outboxes(subscription.id) == 1

    assert %EntitlementGrant{status: :revoked, revoked_reason: "canceled_period_end"} =
             fetch_subscription_grant!(subscription.id)
  end

  test "financial payment application stays awaiting until late exact commercial reconciliation" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {customer, subscription} =
      create_subscription("jc242_payment_before_commercial_application", %{
        started_at: DateTime.add(now, -80 * 86_400, :second)
      })

    enable_stripe!()
    reached = ReachedRenewalFixtures.prepare_reached!(subscription.id, now)
    attempt = reached.attempt
    assert DateTime.compare(attempt.period_end_at, now) == :lt

    payment_intent = reached.payment_intent
    payment_attempt = observe_and_apply_success!(reached)

    collection = collection_for_attempt!(attempt.id)
    assert collection.financial_outcome == :verified_success
    assert collection.payment_attempt_id == payment_attempt.id

    assert {:ok, %{rows: [[1]]}} =
             Repo.query(
               "SELECT count(*) FROM payment_applications WHERE order_id = $1 AND payment_intent_id = $2",
               [Ecto.UUID.dump!(attempt.order_id), Ecto.UUID.dump!(payment_intent.id)]
             )

    assert fetch_subscription!(subscription.id).current_period_end_at ==
             subscription.current_period_end_at

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.status == :active
    assert scheduled.cancel_at_period_end
    assert scheduled.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(scheduled.cancel_at_period_end_at)
    assert scheduled.current_period_end_at == subscription.current_period_end_at

    assert {:ok, %{due_count: 0, canceled_count: 0}} =
             Facade.run_due_scheduled_cancellations_for_system(now: attempt.period_end_at)

    awaiting = fetch_subscription!(subscription.id)
    assert awaiting.status == :active
    assert awaiting.cancel_after_renewal_attempt_id == attempt.id
    assert is_nil(awaiting.cancel_at_period_end_at)
    assert awaiting.current_period_end_at == subscription.current_period_end_at
    assert access_effects(subscription.id) == []
    assert count_scheduled_cancellation_outboxes(subscription.id) == 0

    assert {:ok, :reconciled} =
             Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id
             )

    canceled = fetch_subscription!(subscription.id)
    assert canceled.status == :canceled
    assert canceled.current_period_end_at == attempt.period_end_at
    assert canceled.canceled_at == attempt.period_end_at
    assert canceled.ended_at == attempt.period_end_at
    assert fetch_attempt!(attempt.id).status == :succeeded

    effect = fetch_current_access_effect!(subscription.id)
    assert effect.disposition == :non_effective
    assert effect.status == :applied
    assert effect.source_version == canceled.aggregate_version
    assert length(access_effects(subscription.id)) == 1
    assert count_scheduled_cancellation_outboxes(subscription.id) == 1

    assert {:ok, :noop} =
             Facade.reconcile_paid_subscription_renewal_for_system(attempt.order_id,
               renewal_attempt_id: attempt.id,
               collection_attempt_id: collection.id,
               payment_intent_id: payment_intent.id
             )

    replayed = fetch_subscription!(subscription.id)
    assert replayed.aggregate_version == canceled.aggregate_version
    assert replayed.current_period_end_at == attempt.period_end_at
    assert fetch_current_access_effect!(subscription.id).id == effect.id
    assert length(access_effects(subscription.id)) == 1
    assert count_scheduled_cancellation_outboxes(subscription.id) == 1

    assert {:ok, %{rows: [[1]]}} =
             Repo.query(
               "SELECT count(*) FROM payment_applications WHERE order_id = $1 AND payment_intent_id = $2",
               [Ecto.UUID.dump!(attempt.order_id), Ecto.UUID.dump!(payment_intent.id)]
             )

    assert {:ok, %{rows: [[0]]}} =
             Repo.query("SELECT count(*) FROM refunds WHERE order_id = $1", [
               Ecto.UUID.dump!(attempt.order_id)
             ])
  end

  test "due worker terminalizes with the funded boundary and one effect and email" do
    {customer, subscription} = create_subscription("jc242_due_worker")

    boundary_at = subscription.current_period_end_at

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_at_period_end_at == boundary_at
    worker_now = DateTime.add(boundary_at, 5 * 60, :second)

    assert :ok =
             RunDueScheduledCancellationsWorker.perform(%Job{
               args: %{"now" => DateTime.to_iso8601(worker_now)}
             })

    canceled = fetch_subscription!(subscription.id)
    assert canceled.status == :canceled
    assert canceled.canceled_at == boundary_at
    assert canceled.ended_at == boundary_at
    assert canceled.canceled_at < worker_now
    assert canceled.canceled_reason == "canceled_period_end"

    effect = fetch_current_access_effect!(subscription.id)
    assert effect.disposition == :non_effective
    assert effect.source_version == canceled.aggregate_version
    assert count_scheduled_cancellation_outboxes(subscription.id) == 1

    assert :ok =
             RunDueScheduledCancellationsWorker.perform(%Job{
               args: %{"now" => DateTime.to_iso8601(worker_now)}
             })

    assert count_scheduled_cancellation_outboxes(subscription.id) == 1

    assert {:ok, %{replay_count: 0, failed_count: 0, cursor: nil}} =
             Facade.replay_scheduled_cancellation_notifications_for_system()

    assert {:ok, _} =
             Repo.query(
               "DELETE FROM email_outboxes WHERE subscription_id = $1 AND idempotency_key LIKE $2",
               [
                 Ecto.UUID.dump!(subscription.id),
                 "membership_access_ended:sub:%:reason:canceled_period_end:period_end:%"
               ]
             )

    assert {:ok, %{replay_count: 1, failed_count: 0, cursor: nil}} =
             Facade.replay_scheduled_cancellation_notifications_for_system()

    assert count_scheduled_cancellation_outboxes(subscription.id) == 1
  end

  test "direct due sweep creates the same policy-free boundary target for both policies" do
    for access_on_cancel <- [:remove_immediately, :keep_until_period_end] do
      {customer, subscription} =
        create_subscription(
          "jc247_due_policy_#{access_on_cancel}",
          %{access_on_cancel: access_on_cancel}
        )

      boundary_at = subscription.current_period_end_at
      grant = issue_subscription_grant!(subscription)

      assert {:ok, scheduled} =
               Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

      assert scheduled.status == :active
      assert scheduled.current_plan_revision_id == subscription.current_plan_revision_id
      assert access_effects(subscription.id) == []

      assert {:ok, result} =
               Facade.run_due_scheduled_cancellations_for_system(
                 now: DateTime.add(boundary_at, 1, :second)
               )

      assert Enum.sort(Map.keys(result)) ==
               Enum.sort([:due_count, :canceled_count, :failed_count, :cursor, :now])

      assert result.due_count == 1
      assert result.canceled_count == 1
      assert result.failed_count == 0

      canceled = fetch_subscription!(subscription.id)
      assert canceled.status == :canceled
      assert canceled.canceled_reason == "canceled_period_end"
      assert canceled.canceled_at == boundary_at
      assert canceled.ended_at == boundary_at
      assert canceled.current_plan_revision_id == subscription.current_plan_revision_id
      assert is_nil(canceled.current_dunning_renewal_attempt_id)

      assert [effect] = access_effects(subscription.id)
      assert effect.status == :applied
      assert effect.disposition == :non_effective
      assert is_nil(effect.entitlement_kind)
      assert is_nil(effect.entitlement_scope_key)
      assert is_nil(effect.valid_from_at)
      assert is_nil(effect.valid_until_at)
      assert effect.plan_revision_id == subscription.current_plan_revision_id
      assert effect.source_order_line_item_id == canceled.source_order_line_item_id
      assert effect.contract_change_id == canceled.current_contract_change_id
      assert effect.source_version == canceled.aggregate_version

      assert %EntitlementGrant{status: :revoked, revoked_reason: "canceled_period_end"} =
               fetch_entitlement_grant!(grant.id)

      assert count_scheduled_cancellation_outboxes(subscription.id) == 1

      assert {:ok, replay_result} =
               Facade.run_due_scheduled_cancellations_for_system(
                 now: DateTime.add(boundary_at, 1, :second)
               )

      assert replay_result.due_count == 0
      assert replay_result.canceled_count == 0
      assert access_effects(subscription.id) == [effect]
      assert count_scheduled_cancellation_outboxes(subscription.id) == 1
    end
  end

  test "notification replay requires the exact current boundary effect to be applied" do
    {customer, subscription} = create_subscription("jc247_notification_exact_effect")
    boundary_at = subscription.current_period_end_at

    assert {:ok, _scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert {:ok, %{due_count: 1, canceled_count: 1}} =
             Facade.run_due_scheduled_cancellations_for_system(
               now: DateTime.add(boundary_at, 1, :second)
             )

    canceled = fetch_subscription!(subscription.id)
    assert [current_effect] = access_effects(subscription.id)
    assert current_effect.source_version == canceled.aggregate_version
    assert current_effect.status == :applied

    assert {:ok, _} =
             Repo.query(
               "DELETE FROM email_outboxes WHERE subscription_id = $1 AND idempotency_key LIKE $2",
               [
                 Ecto.UUID.dump!(subscription.id),
                 "membership_access_ended:sub:%:reason:canceled_period_end:period_end:%"
               ]
             )

    historical_version = current_effect.source_version - 1
    assert historical_version > 0

    Repo.query!(
      "UPDATE access_effects SET status = 'required' WHERE id = $1",
      [Ecto.UUID.dump!(current_effect.id)]
    )

    historical_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO access_effects (
        id, subscription_id, source_version, status, disposition,
        entitlement_kind, entitlement_scope_key, valid_from_at, valid_until_at,
        source_order_line_item_id, contract_change_id, plan_revision_id,
        target_fingerprint, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, 'applied', 'non_effective',
        NULL, NULL, NULL, NULL,
        $4, $5, $6, $7, clock_timestamp(), clock_timestamp()
      )
      """,
      [
        Ecto.UUID.dump!(historical_id),
        Ecto.UUID.dump!(subscription.id),
        historical_version,
        Ecto.UUID.dump!(current_effect.source_order_line_item_id),
        current_effect.contract_change_id && Ecto.UUID.dump!(current_effect.contract_change_id),
        Ecto.UUID.dump!(current_effect.plan_revision_id),
        current_effect.target_fingerprint
      ]
    )

    assert {:ok, %{replay_count: 0, failed_count: 0, cursor: nil}} =
             Facade.replay_scheduled_cancellation_notifications_for_system()

    assert current_effect.id == fetch_current_access_effect!(subscription.id).id
    assert fetch_current_access_effect!(subscription.id).status == :required
    assert count_scheduled_cancellation_outboxes(subscription.id) == 0
  end

  test "rescission clears a funded target before the due worker selects it" do
    {customer, subscription} = create_subscription("jc242_rescind")

    boundary_at = subscription.current_period_end_at

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_at_period_end_at == boundary_at

    assert {:ok, rescinded} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :rescind_period_end)

    refute rescinded.cancel_at_period_end
    assert is_nil(rescinded.cancel_at_period_end_at)
    assert is_nil(rescinded.cancel_after_renewal_attempt_id)

    assert {:ok, %{due_count: 0, canceled_count: 0}} =
             Facade.run_due_scheduled_cancellations_for_system(
               now: DateTime.add(boundary_at, 1, :second)
             )

    assert fetch_subscription!(subscription.id).status == :active
    assert count_scheduled_cancellation_outboxes(subscription.id) == 0
  end

  test "scheduled-cancellation selectors reject incomplete keyset cursors" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    id = Ecto.UUID.generate()

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.run_due_scheduled_cancellations_for_system(after_boundary_at: timestamp)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.run_due_scheduled_cancellations_for_system(after_id: id)

    assert {:error, %{code: "VALIDATION_ERROR"}} =
             Facade.replay_scheduled_cancellation_notifications_for_system(
               after_ended_at: timestamp
             )
  end

  test "failed AccessEffect establishment rolls scheduled terminalization back" do
    {customer, subscription} = create_subscription("jc242_effect_rollback")

    boundary_at = subscription.current_period_end_at

    assert {:ok, scheduled} =
             Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

    assert scheduled.cancel_at_period_end_at == boundary_at

    assert {:ok, _} =
             Repo.query(
               "UPDATE subscriptions SET current_plan_revision_id = NULL WHERE id = $1",
               [
                 Ecto.UUID.dump!(subscription.id)
               ]
             )

    assert {:ok, %{due_count: 1, canceled_count: 0, failed_count: 1}} =
             Facade.run_due_scheduled_cancellations_for_system(
               now: DateTime.add(boundary_at, 1, :second)
             )

    still_scheduled = fetch_subscription!(subscription.id)
    assert still_scheduled.status == :active
    assert still_scheduled.cancel_at_period_end
    assert still_scheduled.cancel_at_period_end_at == boundary_at
    assert [] == access_effects(subscription.id)
    assert count_scheduled_cancellation_outboxes(subscription.id) == 0
  end

  defp create_subscription(prefix, overrides \\ %{}) do
    customer = SubscriptionsFixtures.create_customer!(prefix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        access_on_cancel: Map.get(overrides, :access_on_cancel, :remove_immediately),
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:#{prefix}"
      })

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(
        customer.id,
        variant,
        plan,
        Map.merge(
          %{provider_billing_ref: "pm_#{prefix}"},
          Map.drop(Map.new(overrides), [:access_on_cancel])
        )
      )

    {customer, subscription}
  end

  defp renewal_attempts(subscription_id) do
    query = RenewalAttempt |> Ash.Query.filter(expr(subscription_id == ^subscription_id))

    Ash.read!(query,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp collection_for_attempt!(renewal_attempt_id) do
    RenewalCollectionAttempt
    |> Ash.Query.filter(expr(renewal_attempt_id == ^renewal_attempt_id))
    |> Ash.read_one!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_attempt!(id) do
    query = RenewalAttempt |> Ash.Query.filter(expr(id == ^id))

    Ash.read_one!(query,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_subscription!(id) do
    query = Subscription |> Ash.Query.filter(expr(id == ^id))

    Ash.read_one!(query,
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_current_access_effect!(subscription_id) do
    {:ok, effect} =
      Facade.get_current_access_effect_for_system(fetch_subscription!(subscription_id))

    effect
  end

  defp issue_subscription_grant!(%Subscription{} = subscription) do
    revision =
      Ash.get!(PlanRevision, subscription.current_plan_revision_id,
        domain: Store.Subscriptions,
        authorize?: false,
        context: %{system?: true}
      )

    EntitlementGrant
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: subscription.user_id,
        kind: revision.entitlement_kind,
        scope_key: revision.entitlement_scope_key,
        source_kind: :subscription,
        source_id: subscription.id,
        status: :active,
        valid_from_at: subscription.current_period_start_at,
        valid_to_at: subscription.current_period_end_at
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp fetch_entitlement_grant!(grant_id) do
    Ash.get!(EntitlementGrant, grant_id,
      domain: Store.Entitlements,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_subscription_grant!(subscription_id) do
    EntitlementGrant
    |> Ash.Query.filter(expr(source_kind == :subscription and source_id == ^subscription_id))
    |> Ash.read_one!(
      domain: Store.Entitlements,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp access_effects(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp count_scheduled_cancellation_outboxes(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT count(*)
        FROM email_outboxes
        WHERE subscription_id = $1
          AND idempotency_key LIKE $2
        """,
        [
          Ecto.UUID.dump!(subscription_id),
          "membership_access_ended:sub:%:reason:canceled_period_end:period_end:%"
        ]
      )

    count
  end

  defp observe_and_apply_success!(reached) do
    StripeAPIStub.stub_payment_observation(
      reached.payment_intent.provider_payment_id,
      ReachedRenewalFixtures.observation_body(reached, "succeeded")
    )

    input = %Store.Payments.Inputs.ObservePaymentIntentInput{
      payment_intent_id: reached.payment_intent.id
    }

    assert {:ok, observed} = Store.Payments.Facade.observe_payment_intent_for_system(input)

    assert {:ok, %{outcome: :authoritative_success, payment_intent: _intent}} =
             Store.Payments.Facade.apply_observed_payment_outcome_for_system(observed)

    collection = collection_for_attempt!(reached.attempt.id)
    assert collection.financial_outcome == :verified_success
    assert collection.payment_attempt_id == observed.evidence.id
    observed.evidence
  end

  defp create_renewal_attempt(subscription) do
    create_renewal_attempt_at(
      subscription,
      subscription.current_period_end_at,
      "jc242:#{subscription.id}"
    )
  end

  defp create_renewal_attempt_at(subscription, period_start_at, renewal_key) do
    RenewalAttempt
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        subscription_id: subscription.id,
        period_start_at: period_start_at,
        period_end_at: DateTime.add(period_start_at, 30, :day),
        renewal_key: renewal_key
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp enable_stripe! do
    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_store_blueprint",
        publishable_key: "pk_test_store_blueprint",
        request_options: StripeAPIStub.req_options()
      ]
    )
  end
end

defmodule Store.Subscriptions.Sbh4002ScheduledBoundaryPostCommitTest do
  use ExUnit.Case, async: false

  @moduletag :real_connections

  alias Ecto.Adapters.SQL.Sandbox
  alias Store.Entitlements.EntitlementGrant
  alias Store.Repo
  alias Store.Subscriptions.{AccessEffect, Facade}
  alias Store.SubscriptionsFixtures

  import Ash.Expr
  require Ash.Query

  setup_all do
    :ok = Sandbox.mode(Store.Repo, :auto)
    :ok = Sandbox.mode(Store.DirectRepo, :auto)

    on_exit(fn ->
      :ok = Sandbox.mode(Store.Repo, :manual)
      :ok = Sandbox.mode(Store.DirectRepo, :manual)
    end)

    :ok
  end

  test "both policy values commit the exact effect before post-commit F2 runs" do
    for access_on_cancel <- [:remove_immediately, :keep_until_period_end] do
      prefix = "jc247_real_boundary_#{access_on_cancel}_#{Ecto.UUID.generate()}"
      customer = SubscriptionsFixtures.create_customer!(prefix)
      %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

      plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          access_on_cancel: access_on_cancel,
          entitlement_kind: :membership_access,
          entitlement_scope_key: "membership:#{prefix}"
        })

      SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

      %{subscription: subscription, revision: revision} =
        SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
          provider_billing_ref: "pm_#{prefix}"
        })

      grant = issue_grant!(subscription, revision)
      boundary_at = subscription.current_period_end_at

      assert {:ok, scheduled} =
               Facade.cancel_subscription_for_user(customer, subscription.id, :period_end)

      assert scheduled.status == :active
      assert access_effects(subscription.id) == []

      :ok = install_commit_fence!(subscription.id, grant.id)

      assert {:ok, result} =
               Facade.run_due_scheduled_cancellations_for_system(
                 now: DateTime.add(boundary_at, 1, :second)
               )

      assert Enum.sort(Map.keys(result)) ==
               Enum.sort([:due_count, :canceled_count, :failed_count, :cursor, :now])

      canceled = fetch_subscription!(subscription.id)
      assert canceled.status == :canceled
      assert canceled.canceled_reason == "canceled_period_end"
      assert canceled.canceled_at == boundary_at
      assert canceled.current_plan_revision_id == revision.id

      assert [effect] = access_effects(subscription.id)
      assert effect.status == :applied
      assert effect.disposition == :non_effective
      assert is_nil(effect.entitlement_kind)
      assert is_nil(effect.entitlement_scope_key)
      assert is_nil(effect.valid_from_at)
      assert is_nil(effect.valid_until_at)
      assert effect.plan_revision_id == revision.id

      assert %EntitlementGrant{status: :revoked, revoked_reason: "canceled_period_end"} =
               fetch_grant!(grant.id)

      assert scheduled_email_count(subscription.id) == 1
    end
  end

  defp install_commit_fence!(subscription_id, grant_id) do
    function = "jc247_commit_fence_#{System.unique_integer([:positive])}"
    trigger = "#{function}_trigger"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.subscription_id = '#{subscription_id}'::uuid AND (
        NOT EXISTS (
          SELECT 1 FROM access_effects
          WHERE id = NEW.id
            AND status = 'required'
            AND disposition = 'non_effective'
        ) OR NOT EXISTS (
          SELECT 1 FROM entitlement_grants
          WHERE id = '#{grant_id}'::uuid
            AND status = 'active'
            AND revoked_reason IS NULL
        )
      ) THEN
        RAISE EXCEPTION 'scheduled-boundary F2 ran before its source transaction committed';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER #{trigger}
    AFTER INSERT ON access_effects
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION #{function}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON access_effects")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end)

    :ok
  end

  defp issue_grant!(subscription, revision) do
    EntitlementGrant
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: subscription.user_id,
        kind: revision.entitlement_kind,
        scope_key: revision.entitlement_scope_key,
        source_kind: :subscription,
        source_id: subscription.id,
        status: :active,
        valid_from_at: subscription.current_period_start_at,
        valid_to_at: subscription.current_period_end_at
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Entitlements, authorize?: false, context: %{system?: true})
  end

  defp access_effects(subscription_id) do
    AccessEffect
    |> Ash.Query.filter(expr(subscription_id == ^subscription_id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp fetch_subscription!(subscription_id) do
    Store.Subscriptions.Subscription
    |> Ash.Query.filter(expr(id == ^subscription_id))
    |> Ash.read_one!(
      domain: Store.Subscriptions,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp fetch_grant!(grant_id) do
    Ash.get!(EntitlementGrant, grant_id,
      domain: Store.Entitlements,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp scheduled_email_count(subscription_id) do
    {:ok, %{rows: [[count]]}} =
      Repo.query(
        "SELECT count(*) FROM email_outboxes WHERE subscription_id = $1 AND template_kind = 'access_ended'",
        [Ecto.UUID.dump!(subscription_id)]
      )

    count
  end
end
