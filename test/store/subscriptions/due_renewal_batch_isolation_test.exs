defmodule Store.Subscriptions.DueRenewalBatchIsolationTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import ExUnit.CaptureLog

  alias Store.Repo
  alias Store.Subscriptions.Facade
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.ProcessSubscriptionRenewalWorker
  alias Store.Workers.RunDueSubscriptionRenewalsWorker

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("invalid due contracts must not call Stripe")
    :ok
  end

  for invalid_first? <- [true, false] do
    test "an invalid timezone only rejects its source when invalid_first=#{invalid_first?}" do
      now = now()
      invalid_first? = unquote(invalid_first?)

      invalid =
        due_fixture!(
          "batch_invalid_#{invalid_first?}",
          now,
          if(invalid_first?, do: -30, else: -10)
        )

      valid =
        due_fixture!("batch_valid_#{invalid_first?}", now, if(invalid_first?, do: -10, else: -30))

      corrupt_revision_timezone!(invalid.revision.id)
      before = lifecycle_snapshot([invalid, valid])

      log =
        capture_log(fn ->
          assert {:ok, [job]} = Facade.list_due_renewal_jobs_for_system(now: now, limit: 50)
          assert job.subscription_id == valid.subscription.id

          assert {:error, %{code: "INVALID_BILLING_TIMEZONE"}} =
                   Facade.process_due_subscription_renewal_for_system(invalid.subscription.id,
                     now: now
                   )

          assert :ok =
                   perform_job(RunDueSubscriptionRenewalsWorker, %{
                     "now" => DateTime.to_iso8601(now),
                     "limit" => 50
                   })

          assert :ok =
                   perform_job(RunDueSubscriptionRenewalsWorker, %{
                     "now" => DateTime.to_iso8601(now),
                     "limit" => 50
                   })
        end)

      assert log =~ invalid.subscription.id
      assert log =~ invalid.revision.id
      assert log =~ "INVALID_BILLING_TIMEZONE"
      assert length(all_enqueued(worker: ProcessSubscriptionRenewalWorker)) == 1

      assert_enqueued(
        worker: ProcessSubscriptionRenewalWorker,
        args: %{"subscription_id" => valid.subscription.id}
      )

      refute_enqueued(
        worker: ProcessSubscriptionRenewalWorker,
        args: %{"subscription_id" => invalid.subscription.id}
      )

      assert lifecycle_snapshot([invalid, valid]) == before
    end
  end

  test "a full invalid prefix advances through real continuation jobs and reaches the valid source" do
    now = now()

    invalid_sources =
      for index <- 1..3 do
        fixture = due_fixture!("batch_prefix_#{index}", now, index * -10)
        corrupt_revision_timezone!(fixture.revision.id)
        fixture
      end

    valid = due_fixture!("batch_prefix_valid", now, -1)
    before = lifecycle_snapshot(invalid_sources ++ [valid])

    assert {:ok, %{jobs: [], cursor: first_page_cursor, now: ^now}} =
             Facade.list_due_renewal_job_page_for_system(now: now, limit: 1)

    assert first_page_cursor.id == List.last(invalid_sources).subscription.id

    assert :ok =
             perform_job(RunDueSubscriptionRenewalsWorker, %{
               "now" => DateTime.to_iso8601(now),
               "limit" => 1
             })

    assert [first_continuation] = all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
    assert first_continuation.args["now"] == DateTime.to_iso8601(now)
    assert first_continuation.args["after_id"] == first_page_cursor.id

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, first_continuation.args)
    [second_continuation | _] = all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
    assert second_continuation.args["after_id"] != first_continuation.args["after_id"]

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, second_continuation.args)
    [third_continuation | _] = all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
    assert third_continuation.args["after_id"] != second_continuation.args["after_id"]

    continuation_count = length(all_enqueued(worker: RunDueSubscriptionRenewalsWorker))
    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, third_continuation.args)
    [terminal_continuation | _] = all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
    assert terminal_continuation.args["after_id"] != third_continuation.args["after_id"]

    assert_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => valid.subscription.id}
    )

    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, terminal_continuation.args)

    assert length(all_enqueued(worker: RunDueSubscriptionRenewalsWorker)) ==
             continuation_count + 1

    assert_enqueued(
      worker: ProcessSubscriptionRenewalWorker,
      args: %{"subscription_id" => valid.subscription.id}
    )

    assert length(all_enqueued(worker: ProcessSubscriptionRenewalWorker)) == 1

    assert :ok =
             perform_job(RunDueSubscriptionRenewalsWorker, %{
               "now" => DateTime.to_iso8601(now),
               "limit" => 1
             })

    assert length(all_enqueued(worker: RunDueSubscriptionRenewalsWorker)) ==
             continuation_count + 1

    for continuation <- [
          first_continuation,
          second_continuation,
          third_continuation,
          terminal_continuation
        ] do
      assert continuation.args["now"] == DateTime.to_iso8601(now)
      assert continuation.args["limit"] == 1
      assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, continuation.args)
    end

    assert length(all_enqueued(worker: ProcessSubscriptionRenewalWorker)) == 1
    assert lifecycle_snapshot(invalid_sources ++ [valid]) == before
  end

  test "paged reads use native UUID order for timestamp ties and nullable retry timestamps" do
    now = now()
    tied = [due_fixture!("batch_tied_a", now, -10), due_fixture!("batch_tied_b", now, -10)]

    null_rows = [
      past_due_fixture!("batch_null_retry_a", now),
      past_due_fixture!("batch_null_retry_b", now)
    ]

    ordered_ids = native_id_order(tied ++ null_rows)

    assert {:ok, %{jobs: [first], cursor: cursor, now: ^now}} =
             Facade.list_due_renewal_job_page_for_system(now: now, limit: "1")

    assert first.subscription_id == hd(ordered_ids)
    assert cursor.id == hd(ordered_ids)

    assert {:ok, %{jobs: [second], cursor: second_cursor}} =
             Facade.list_due_renewal_job_page_for_system(
               now: now,
               limit: 1,
               after_renewal_at: cursor.timestamp,
               after_id: cursor.id
             )

    assert second.subscription_id == Enum.at(ordered_ids, 1)

    assert {:ok, %{jobs: [null_job], cursor: null_cursor}} =
             Facade.list_due_renewal_job_page_for_system(
               now: now,
               limit: 1,
               after_renewal_at: second_cursor.timestamp,
               after_id: second_cursor.id
             )

    assert null_job.subscription_id == Enum.at(ordered_ids, 2)
    assert null_cursor.timestamp == nil
    assert null_cursor.id == null_job.subscription_id

    assert {:ok, %{jobs: [last_null_job], cursor: last_null_cursor}} =
             Facade.list_due_renewal_job_page_for_system(
               now: now,
               limit: 1,
               after_renewal_at: nil,
               after_id: null_cursor.id
             )

    assert last_null_job.subscription_id == Enum.at(ordered_ids, 3)
    assert last_null_cursor.timestamp == nil

    assert {:ok, %{jobs: [], cursor: nil}} =
             Facade.list_due_renewal_job_page_for_system(
               now: now,
               limit: 1,
               after_renewal_at: nil,
               after_id: last_null_cursor.id
             )

    assert :ok =
             perform_job(RunDueSubscriptionRenewalsWorker, %{
               "now" => DateTime.to_iso8601(now),
               "after_id" => null_cursor.id,
               "limit" => 1
             })

    assert [continuation] = all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
    assert continuation.args["after_id"] == last_null_cursor.id
    refute Map.has_key?(continuation.args, "after_renewal_at")
    assert :ok = perform_job(RunDueSubscriptionRenewalsWorker, continuation.args)
    assert [job] = all_enqueued(worker: ProcessSubscriptionRenewalWorker)
    assert job.args["subscription_id"] == last_null_job.subscription_id
  end

  test "the facade rejects malformed timestamps and UUID cursor combinations" do
    now = now()

    for opts <- [
          [now: "invalid"],
          [after_renewal_at: "invalid", after_id: Ecto.UUID.generate()],
          [after_renewal_at: now, after_id: "not-a-uuid"],
          [after_renewal_at: now]
        ] do
      assert {:error, %{code: "VALIDATION_ERROR"}} =
               Facade.list_due_renewal_job_page_for_system(
                 Keyword.merge([now: now, limit: 1], opts)
               )
    end
  end

  test "the tick worker discards malformed page cursors without enqueuing work" do
    for args <- [
          %{"now" => "invalid"},
          %{"after_renewal_at" => "invalid", "after_id" => Ecto.UUID.generate()},
          %{"after_renewal_at" => DateTime.to_iso8601(now()), "after_id" => "bad"},
          %{"after_renewal_at" => DateTime.to_iso8601(now())}
        ] do
      assert {:discard, _} =
               perform_job(RunDueSubscriptionRenewalsWorker, Map.put(args, "limit", 1))
    end

    assert [] == all_enqueued(worker: ProcessSubscriptionRenewalWorker)
    assert [] == all_enqueued(worker: RunDueSubscriptionRenewalsWorker)
  end

  defp due_fixture!(suffix, now, offset_seconds) do
    customer = SubscriptionsFixtures.create_customer!(suffix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        started_at: DateTime.add(now, -40 * 86_400, :second),
        next_renewal_at: DateTime.add(now, offset_seconds, :second),
        provider_billing_ref: "pm_#{suffix}"
      })

    Map.merge(fixture, %{customer: customer, variant: variant, plan: plan, now: now})
  end

  defp past_due_fixture!(suffix, now) do
    customer = SubscriptionsFixtures.create_customer!(suffix)
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    fixture =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        status: :past_due,
        past_due_since_at: DateTime.add(now, -86_400, :second),
        failed_payment_boundary_at: DateTime.add(now, -86_400, :second),
        next_renewal_at: nil,
        next_retry_at: nil,
        provider_billing_ref: "pm_#{suffix}"
      })

    Map.merge(fixture, %{customer: customer, variant: variant, plan: plan, now: now})
  end

  defp corrupt_revision_timezone!(revision_id) do
    Repo.query!("UPDATE plan_revisions SET billing_timezone = 'Not/A_Real_Zone' WHERE id = $1", [
      Ecto.UUID.dump!(revision_id)
    ])
  end

  defp lifecycle_snapshot(fixtures) do
    Enum.map(fixtures, fn fixture ->
      subscription_id = Ecto.UUID.dump!(fixture.subscription.id)

      %{
        subscription:
          Repo.query!("SELECT * FROM subscriptions WHERE id = $1", [subscription_id]).rows,
        revision:
          Repo.query!("SELECT * FROM plan_revisions WHERE id = $1", [
            Ecto.UUID.dump!(fixture.revision.id)
          ]).rows,
        attempts:
          Repo.query!("SELECT * FROM renewal_attempts WHERE subscription_id = $1", [
            subscription_id
          ]).rows,
        collection_attempts: collection_attempt_rows(subscription_id),
        contract_changes:
          Repo.query!("SELECT * FROM contract_changes WHERE subscription_id = $1 ORDER BY id", [
            subscription_id
          ]).rows,
        orders: Repo.query!("SELECT * FROM orders ORDER BY id").rows,
        payment_intents: Repo.query!("SELECT * FROM payment_intents ORDER BY id").rows,
        access_effects:
          Repo.query!("SELECT * FROM access_effects WHERE subscription_id = $1 ORDER BY id", [
            subscription_id
          ]).rows
      }
    end)
  end

  defp collection_attempt_rows(subscription_id) do
    query = """
    SELECT collection_attempts.* FROM renewal_collection_attempts collection_attempts
    JOIN renewal_attempts attempts ON attempts.id = collection_attempts.renewal_attempt_id
    WHERE attempts.subscription_id = $1
    ORDER BY collection_attempts.id
    """

    Repo.query!(query, [subscription_id]).rows
  end

  defp native_id_order(fixtures) do
    ids = Enum.map(fixtures, &Ecto.UUID.dump!(&1.subscription.id))
    placeholders = Enum.map_join(1..length(ids), ",", &"$#{&1}")

    Repo.query!(
      "SELECT id FROM subscriptions WHERE id IN (#{placeholders}) ORDER BY next_renewal_at ASC NULLS LAST, id ASC",
      ids
    ).rows
    |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
