defmodule PagelessWeb.UserLive.Setup do
  use PagelessWeb, :live_view

  alias Pageless.Accounts
  alias Pageless.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, push_navigate(socket, to: ~p"/users/log-in")}
    else
      {:ok,
       socket
       |> assign(page_title: "Set up Pageless")
       |> assign_form(User.managed_changeset(%User{}, %{}, password_required: false))}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.managed_changeset(params, password_required: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_initial_admin(params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Admin account created. You can now log in.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, :already_setup} ->
        {:noreply, push_navigate(socket, to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6">
        <div class="space-y-2 text-center">
          <img src={~p"/images/pageless-icon.svg"} alt="Pageless" class="mx-auto size-14 rounded-xl" />
          <h1 class="text-3xl font-bold tracking-tight">Set up Pageless</h1>
          <p class="text-sm text-base-content/60">
            Create the first admin account. After this, users can only be managed by admins.
          </p>
        </div>

        <.form
          for={@form}
          id="setup-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:first_name]}
              type="text"
              label="First name"
              autocomplete="given-name"
            />
            <.input
              field={@form[:last_name]}
              type="text"
              label="Last name"
              autocomplete="family-name"
            />
          </div>
          <.input field={@form[:email]} type="email" label="Email" required autocomplete="username" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            required
            autocomplete="new-password"
          />

          <button
            type="submit"
            class="w-full rounded-xl bg-primary px-4 py-3 text-sm font-semibold text-primary-content transition hover:opacity-90"
          >
            Create admin account
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
