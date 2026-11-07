defmodule Store.Subscriptions.PaymentMethodAuthorityGateTest do
  use Store.DataCase, async: false

  alias Store.Repo
  alias Store.Subscriptions.PaymentMethodAuthorityGate

  test "binding keys include raw user identity and provider" do
    user_id = Ecto.UUID.generate()

    assert PaymentMethodAuthorityGate.binding_key(user_id, :stripe) !=
             PaymentMethodAuthorityGate.binding_key(user_id, :adyen)
  end

  test "method keys are length delimited" do
    assert PaymentMethodAuthorityGate.method_key(:stripe, "ab", "c") !=
             PaymentMethodAuthorityGate.method_key(:stripe, "a", "bc")
  end

  test "locking requires a transaction" do
    assert {:error, :transaction_required} =
             PaymentMethodAuthorityGate.lock_binding_for_transaction(
               Ecto.UUID.generate(),
               :stripe
             )
  end

  test "binding and method locks can be acquired together in a transaction" do
    user_id = Ecto.UUID.generate()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert :ok =
                        PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, :stripe)

               assert :ok =
                        PaymentMethodAuthorityGate.lock_binding_for_transaction(user_id, :stripe)

               assert :ok =
                        PaymentMethodAuthorityGate.lock_method_for_transaction(
                          :stripe,
                          "cus_gate_test",
                          "pm_gate_test"
                        )

               :ok
             end)
  end
end
