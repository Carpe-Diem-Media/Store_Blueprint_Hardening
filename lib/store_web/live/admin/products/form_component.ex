defmodule StoreWeb.Admin.Products.FormComponent do
  @moduledoc """
  AshPhoenix form component for product create/update.
  """

  use StoreWeb, :live_component

  alias AshPhoenix.Form
  alias Store.Catalog
  alias Store.Catalog.Product

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_form(build_form(assigns))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"product" => params}, socket) do
    ash_form = Form.validate(socket.assigns.ash_form, params)
    {:noreply, assign_form(socket, ash_form)}
  end

  @impl true
  def handle_event("save", %{"product" => params}, socket) do
    case Form.submit(socket.assigns.ash_form, params: params) do
      {:ok, product} ->
        send(self(), {:product_saved, product})
        {:noreply, socket}

      {:error, ash_form} ->
        {:noreply, socket |> put_flash(:error, "Unable to save product") |> assign_form(ash_form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="product-form-component">
      <h2 class="mb-4 text-lg font-semibold">
        {if(@action == :new, do: "Create Product", else: "Edit Product")}
      </h2>

      <.form
        for={@form}
        id="product-form"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:slug]} type="text" label="Slug" required />
        <.input field={@form[:title]} type="text" label="Title" required />
        <.input field={@form[:subtitle]} type="text" label="Subtitle" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <.input
          field={@form[:product_kind]}
          type="select"
          label="Product type"
          options={[
            {"Physical", :simple},
            {"Digital download", :digital},
            {"Subscription", :subscription}
          ]}
        />

        <div :if={@action == :new} class="mt-4 space-y-3 rounded-xl border border-base-300 p-4">
          <p class="text-sm font-medium">Default Variant</p>
          <.input field={@form[:base_variant_sku]} type="text" label="SKU" required />
          <.input field={@form[:base_variant_title]} type="text" label="Variant Title" />
          <.input
            field={@form[:base_variant_currency_code]}
            type="text"
            label="Currency Code"
            required
          />
          <.input
            field={@form[:base_variant_price_minor]}
            type="number"
            label="Price (minor)"
            required
          />
          <.input
            field={@form[:base_variant_compare_at_price_minor]}
            type="number"
            label="Compare At Price (minor)"
          />
          <.input
            field={@form[:base_variant_stock_on_hand]}
            type="number"
            label="Stock On Hand"
            required
          />
          <.input
            field={@form[:base_variant_allow_oversell]}
            type="checkbox"
            label="Allow Oversell"
          />
        </div>

        <div class="mt-4 flex gap-2">
          <.button id="save-product" type="submit">Save Product</.button>
          <.button id="cancel-product" type="button" patch={@patch} class="btn btn-soft">
            Cancel
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp build_form(%{action: :new, current_user: current_user}) do
    Form.for_create(Product, :create_draft,
      actor: current_user,
      domain: Catalog,
      as: "product",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(%{action: :edit, product: product, current_user: current_user})
       when not is_nil(product) do
    Form.for_update(product, :update_draft,
      actor: current_user,
      domain: Catalog,
      as: "product",
      warn_on_unhandled_errors?: false
    )
  end

  defp build_form(assigns), do: build_form(Map.put(assigns, :action, :new))

  defp assign_form(socket, ash_form) do
    socket
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end
end
