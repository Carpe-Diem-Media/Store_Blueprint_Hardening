defmodule Store.Workers.JC259RenewalRetryAuditTest do
  use Store.DataCase, async: false
  use Oban.Testing, repo: Store.DirectRepo

  import Ash.Expr
  require Ash.Query

  alias Oban.Queues.Executor
  alias Store.DirectRepo
  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions.{Facade, RenewalAttempt, Subscription}
  alias Store.SubscriptionsFixtures
  alias Store.TestSupport.StripeAPIStub
  alias Store.Workers.{ProcessSubscriptionRenewalWorker, RunDueSubscriptionRenewalsWorker}

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("JC259 retry audit must not call the provider")
    :ok
  end

  test "acknowledged early technical retry completes and blocks later due fan-out" do
    fixture = fixture!([1, 24, 72])
    job = insert_job!(fixture.args)

    assert %{state: :failure, result: {:error, %{code: "PAYMENT_METHOD_REQUIRED"}}} =
             execute!(job)

    assert DirectRepo.get!(Oban.Job, job.id).state == "retryable"
    failed = subscription!(fixture.subscription.id)
    assert failed.status == :past_due
    assert failed.dunning_attempt_count == 1
    assert DateTime.compare(failed.next_retry_at, DateTime.utc_now()) == :gt
    assert collection_count(failed.id) == 0

    assert %{state: :success, result: :ok} = execute!(DirectRepo.get!(Oban.Job, job.id))
    completed = DirectRepo.get!(Oban.Job, job.id)
    assert completed.state == "completed"
    assert completed.attempt == 2
    assert %DateTime{} = completed.completed_at
    assert subscription!(failed.id).next_retry_at == failed.next_retry_at
    assert subscription!(failed.id).dunning_attempt_count == 1

    assert {:ok, due_jobs} =
             Facade.list_due_renewal_jobs_for_system(now: failed.next_retry_at, limit: 500)

    assert Enum.any?(
             due_jobs,
             &(&1.subscription_id == failed.id and &1.renewal_key == fixture.args["renewal_key"])
           )

    assert {:ok, conflict} =
             fixture.args |> ProcessSubscriptionRenewalWorker.new() |> Oban.insert()

    assert conflict.conflict?
    assert conflict.id == completed.id

    # The production fan-out uses wall time. Move only this fixture's deadline to
    # the past to select the later business state without sleeping for an hour.
    make_retry_due!(failed.id)
    assert :ok = RunDueSubscriptionRenewalsWorker.perform(%Oban.Job{args: %{"limit" => 500}})
    assert [%Oban.Job{id: id, state: "completed"}] = jobs(fixture.args)
    assert id == completed.id
    refute_enqueued(worker: ProcessSubscriptionRenewalWorker, args: fixture.args)
    assert subscription!(failed.id).dunning_attempt_count == 1
    assert collection_count(failed.id) == 0
  end

  test "retained completed rows conflict below, at and above the configured retention age" do
    reference = DateTime.utc_now() |> DateTime.truncate(:second)

    for age <- [86_340, 86_400, 90_000] do
      args = %{
        "subscription_id" => Ecto.UUID.generate(),
        "renewal_key" => "jc259-retained-#{age}"
      }

      timestamp = DateTime.add(reference, -age, :second)

      assert {:ok, retained} =
               args
               |> ProcessSubscriptionRenewalWorker.new(
                 state: "completed",
                 inserted_at: timestamp,
                 scheduled_at: timestamp,
                 completed_at: timestamp
               )
               |> Oban.insert()

      assert {:ok, conflict} = args |> ProcessSubscriptionRenewalWorker.new() |> Oban.insert()
      assert conflict.conflict?
      assert conflict.id == retained.id
      assert DateTime.diff(reference, retained.scheduled_at, :second) == age
      assert [%Oban.Job{state: "completed"}] = jobs(args)
    end
  end

  test "successful local payment-method repair cannot enqueue past a retained completed job" do
    fixture = fixture!([1, 24, 72])
    job = insert_job!(fixture.args)
    assert %{state: :failure} = execute!(job)
    assert %{state: :success} = execute!(DirectRepo.get!(Oban.Job, job.id))
    assert DirectRepo.get!(Oban.Job, job.id).state == "completed"
    failed = subscription!(fixture.subscription.id)
    assert DateTime.compare(failed.next_retry_at, DateTime.utc_now()) == :gt
    method_ref = "pm_jc259_repaired_#{fixture.subscription.id}"
    intent = succeeded_setup_intent!(fixture, method_ref)

    assert :ok = Facade.handle_payment_method_update_succeeded_for_system(intent.id)
    repaired = subscription!(failed.id)
    assert repaired.provider_billing_ref == method_ref
    assert is_binary(repaired.stored_payment_method_id)
    assert repaired.status == :past_due
    assert repaired.dunning_attempt_count == 1
    assert is_nil(repaired.retry_suppressed_at)
    assert DateTime.compare(repaired.next_retry_at, failed.next_retry_at) == :lt
    assert {:ok, due_jobs} = Facade.list_due_renewal_jobs_for_system(limit: 500)

    assert Enum.any?(
             due_jobs,
             &(&1.subscription_id == repaired.id and &1.renewal_key == fixture.args["renewal_key"])
           )

    assert {:ok, conflict} =
             fixture.args |> ProcessSubscriptionRenewalWorker.new() |> Oban.insert()

    assert conflict.conflict?
    assert conflict.id == job.id
    assert [%Oban.Job{state: "completed", id: id}] = jobs(fixture.args)
    assert id == job.id
    refute_enqueued(worker: ProcessSubscriptionRenewalWorker, args: fixture.args)
  end

  test "a seeded final technical attempt is discarded while its due business state is rediscovered" do
    fixture = fixture!([0, 24, 72])
    job = insert_job!(fixture.args)
    # Seed the prior technical counter, not four prior business executions.
    assert {1, _} =
             DirectRepo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [attempt: 4])

    assert %{state: :exhausted, result: {:error, %{code: "PAYMENT_METHOD_REQUIRED"}}} =
             execute!(DirectRepo.get!(Oban.Job, job.id))

    discarded = DirectRepo.get!(Oban.Job, job.id)
    assert discarded.state == "discarded"
    assert discarded.attempt == 5
    assert discarded.max_attempts == 5
    assert length(discarded.errors) == 1
    assert %DateTime{} = discarded.discarded_at
    failed = subscription!(fixture.subscription.id)
    assert failed.status == :past_due
    assert failed.dunning_attempt_count == 1
    assert is_nil(failed.ended_at)
    assert %DateTime{} = failed.failed_payment_boundary_at

    assert [%RenewalAttempt{status: :failed, failure_code: "PAYMENT_METHOD_REQUIRED"}] =
             attempts!(failed.id)

    assert {:ok, due_jobs} = Facade.list_due_renewal_jobs_for_system(limit: 500)

    assert Enum.any?(
             due_jobs,
             &(&1.subscription_id == failed.id and &1.renewal_key == fixture.args["renewal_key"])
           )

    assert :ok = RunDueSubscriptionRenewalsWorker.perform(%Oban.Job{args: %{"limit" => 500}})
    assert [replacement] = Enum.reject(jobs(fixture.args), &(&1.id == job.id))
    assert replacement.state in ["available", "scheduled"]
    assert replacement.attempt == 0
    assert replacement.args == fixture.args
    assert collection_count(failed.id) == 0
  end

  defp fixture!(retry_schedule) do
    customer = SubscriptionsFixtures.create_customer!("jc259_retry")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{retry_schedule_hours: retry_schedule})

    SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    created =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        next_renewal_at: DateTime.add(now, -1, :second)
      })

    assert {:ok, due_jobs} = Facade.list_due_renewal_jobs_for_system(now: now, limit: 500)
    due = Enum.find(due_jobs, &(&1.subscription_id == created.subscription.id))
    assert due
    args = %{"subscription_id" => created.subscription.id, "renewal_key" => due.renewal_key}
    Map.merge(created, %{customer: customer, plan: plan, args: args})
  end

  defp insert_job!(args) do
    assert {:ok, job} = args |> ProcessSubscriptionRenewalWorker.new() |> Oban.insert()
    refute job.conflict?
    job
  end

  defp execute!(job) do
    attempted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Prepare only this identified row as fetched. The actual executor performs
    # the production worker and engine acknowledgement; no producer is running.
    assert {1, _} =
             DirectRepo.update_all(
               from(j in Oban.Job,
                 where: j.id == ^job.id and j.state in ["available", "scheduled", "retryable"]
               ),
               set: [state: "executing", attempted_at: attempted_at],
               inc: [attempt: 1]
             )

    conf = Oban.config()
    assert conf.repo == DirectRepo
    assert conf.engine == Oban.Engines.Basic
    executing = DirectRepo.get!(Oban.Job, job.id)
    conf |> Executor.new(executing, safe: false, ack: true) |> Executor.call()
  end

  defp jobs(args) do
    worker = Oban.Worker.to_string(ProcessSubscriptionRenewalWorker)

    DirectRepo.all(
      from(j in Oban.Job, where: j.worker == ^worker and j.args == ^args, order_by: j.id)
    )
  end

  defp subscription!(id) do
    Subscription
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp attempts!(id) do
    RenewalAttempt
    |> Ash.Query.filter(expr(subscription_id == ^id))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp collection_count(id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM renewal_collection_attempts c JOIN renewal_attempts a ON a.id=c.renewal_attempt_id WHERE a.subscription_id=$1",
        [Ecto.UUID.dump!(id)]
      ).rows

    count
  end

  defp make_retry_due!(id) do
    now = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_naive()

    assert %{num_rows: 1} =
             Repo.query!("UPDATE subscriptions SET next_retry_at=$2 WHERE id=$1", [
               Ecto.UUID.dump!(id),
               now
             ])
  end

  defp succeeded_setup_intent!(fixture, method_ref) do
    PaymentIntent
    |> Ash.Changeset.for_create(
      :create_or_reuse,
      %{
        order_id: fixture.subscription.source_order_id,
        amount_received_minor: fixture.plan.amount_minor,
        currency: fixture.plan.currency,
        provider: :stripe,
        provider_customer_ref: "cus_jc259_#{fixture.customer.id}",
        provider_payment_method_ref: method_ref,
        payment_intent_key: "jc259:repair:#{fixture.subscription.id}",
        purpose: :subscription_payment_method_update,
        subscription_id: fixture.subscription.id
      },
      context: %{system?: true}
    )
    |> Ash.create!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> Ash.Changeset.for_update(:submit, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
    |> Ash.Changeset.for_update(:mark_succeeded, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Payments, authorize?: false, context: %{system?: true})
  end
end
