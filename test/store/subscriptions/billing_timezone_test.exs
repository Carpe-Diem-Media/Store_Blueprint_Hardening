defmodule Store.Subscriptions.BillingTimezoneTest do
  use ExUnit.Case, async: true

  alias Store.Subscriptions.BillingTimezone

  test "accepts zones supported by the configured timezone database" do
    assert :ok = BillingTimezone.validate("Africa/Johannesburg")
    assert :ok = BillingTimezone.validate("Etc/UTC")
  end

  test "rejects missing and unsupported timezone values with a stable error" do
    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      assert {:error, error} = BillingTimezone.validate(timezone)
      assert error.code == "INVALID_BILLING_TIMEZONE"
    end
  end

  test "rejects a named zone unsupported by an explicitly supplied database" do
    assert {:error, error} =
             BillingTimezone.validate("Africa/Johannesburg", Calendar.UTCOnlyTimeZoneDatabase)

    assert error.code == "INVALID_BILLING_TIMEZONE"
  end
end
