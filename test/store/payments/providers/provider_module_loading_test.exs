defmodule Store.Payments.Providers.ProviderModuleLoadingTest do
  use ExUnit.Case, async: false

  alias Store.Payments.Providers
  alias Store.Payments.Types.ProviderObservation

  test "Paystack renewal reference callback works when its adapter starts unloaded" do
    with_unloaded_adapter(Store.Payments.Providers.Paystack, fn ->
      collection_id = "018f4a1c-7b2d-7a91-8f01-62e0a3c4b5d6"

      assert {:ok, "renewal-018f4a1c7b2d7a918f0162e0a3c4b5d6"} =
               Providers.renewal_collection_request_reference(:paystack, collection_id)
    end)
  end

  test "Stripe finality callback works when its adapter starts unloaded" do
    observation = %ProviderObservation{
      provider: :stripe,
      provider_reference: "pi_1",
      provider_reference_kind: :payment_intent,
      observation_source: :verification,
      normalized_outcome: :authoritative_success,
      raw_provider_status: "succeeded",
      amount_minor: 1,
      currency: "USD",
      observed_at: DateTime.utc_now()
    }

    with_unloaded_adapter(Store.Payments.Providers.Stripe, fn ->
      assert Providers.classify_payment_finality(:stripe, observation) == :authoritative_success
    end)
  end

  defp with_unloaded_adapter(module, fun) do
    :code.purge(module)
    :code.delete(module)

    try do
      assert :code.is_loaded(module) == false
      fun.()
    after
      assert {:module, ^module} = Code.ensure_loaded(module)
    end
  end
end
