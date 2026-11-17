defmodule Store.Orders.AllocationRuntimeContractTest do
  use Store.DataCase, async: false

  alias Store.Operations.AllocationRuntimeContract

  test "schema owner runtime is rejected instead of treated as restricted" do
    %{rows: [[role]]} = Store.Repo.query!("SELECT current_user::text")

    assert_raise RuntimeError, ~r/allocation runtime preflight failed/, fn ->
      AllocationRuntimeContract.check!(Store.Repo, [role, role])
    end
  end

  test "unknown runtime principals fail closed" do
    assert_raise RuntimeError, ~r/allocation runtime preflight failed/, fn ->
      AllocationRuntimeContract.check!(Store.Repo, ["jc382_absent_role", "jc382_absent_direct"])
    end
  end

  test "invalid connection URLs fail without echoing their contents" do
    assert_raise RuntimeError,
                 "allocation runtime preflight failed: invalid_connection_config",
                 fn ->
                   AllocationRuntimeContract.migrate!(
                     [[url: "invalid-secret-marker"]],
                     [],
                     "unused_owner"
                   )
                 end
  end
end
