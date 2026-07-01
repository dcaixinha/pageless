defmodule PagelessWeb.UserLive.Settings do
  use PagelessWeb, :live_view

  on_mount {PagelessWeb.UserAuth, :require_sudo_mode}

  alias Pageless.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:account}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your profile, theme, email address, and password settings</:subtitle>
        </.header>
      </div>

      <div class="mx-auto max-w-xl space-y-8">
        <section class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
          <h2 class="text-lg font-semibold">Profile</h2>
          <.form
            for={@profile_form}
            id="profile_form"
            phx-submit="update_profile"
            phx-change="validate_profile"
            class="mt-4 space-y-4"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@profile_form[:first_name]}
                type="text"
                label="First name"
                autocomplete="given-name"
              />
              <.input
                field={@profile_form[:last_name]}
                type="text"
                label="Last name"
                autocomplete="family-name"
              />
            </div>
            <.button variant="primary" phx-disable-with="Saving...">Save Profile</.button>
          </.form>
        </section>

        <section class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
          <h2 class="text-lg font-semibold">Appearance</h2>
          <p class="mt-1 text-sm text-base-content/60">
            Choose how Pageless should look and organize your library.
          </p>
          <div class="mt-4 space-y-5">
            <div class="max-w-xs">
              <Layouts.theme_toggle labels />
            </div>

            <.form
              for={@appearance_form}
              id="appearance_form"
              phx-change="validate_appearance"
              phx-submit="update_appearance"
              class="space-y-3"
            >
              <.input
                field={@appearance_form[:cover_size]}
                type="number"
                label="Default cover size"
                min={@cover_size_min}
                max={@cover_size_max}
                step="20"
              />
              <p class="text-xs text-base-content/50">
                Used by Home and Library cover grids. Range: {@cover_size_min}-{@cover_size_max}.
              </p>
              <.input
                field={@appearance_form[:ignore_prefixes_when_sorting]}
                type="checkbox"
                label="Ignore prefixes when sorting"
              />
              <p class="text-xs text-base-content/50">
                Sort titles without the leading articles "A", "An", or "The".
              </p>
              <div class="grid gap-4 sm:grid-cols-2">
                <.input
                  field={@appearance_form[:date_format]}
                  type="select"
                  label="Date format"
                  options={@date_formats}
                />
                <.input
                  field={@appearance_form[:time_format]}
                  type="select"
                  label="Time format"
                  options={@time_formats}
                />
              </div>
              <.button variant="primary" phx-disable-with="Saving...">Save Appearance</.button>
            </.form>
          </div>
        </section>

        <section class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
          <h2 class="text-lg font-semibold">Email</h2>
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            class="mt-4 space-y-4"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
          </.form>
        </section>

        <section class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
          <h2 class="text-lg font-semibold">Password</h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="mt-4 space-y-4"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button variant="primary" phx-disable-with="Saving...">
              Save Password
            </.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    settings = Accounts.get_player_settings(user)
    profile_changeset = Accounts.change_user_profile(user)
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:cover_size_min, Accounts.PlayerSettings.cover_size_min())
      |> assign(:cover_size_max, Accounts.PlayerSettings.cover_size_max())
      |> assign(:date_formats, Accounts.PlayerSettings.date_formats())
      |> assign(:time_formats, Accounts.PlayerSettings.time_formats())
      |> assign(
        :appearance_form,
        to_form(appearance_params(settings), as: "player_settings")
      )
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_appearance", %{"player_settings" => params}, socket) do
    {:noreply, assign(socket, appearance_form: to_form(params, as: "player_settings"))}
  end

  def handle_event("update_appearance", %{"player_settings" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_player_settings(user, params) do
      {:ok, updated_user} ->
        settings = Accounts.get_player_settings(updated_user)
        scope = %{socket.assigns.current_scope | user: updated_user}

        {:noreply,
         socket
         |> assign(
           current_scope: scope,
           appearance_form: to_form(appearance_params(settings), as: "player_settings")
         )
         |> put_flash(:info, "Appearance updated successfully.")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(appearance_form: to_form(params, as: "player_settings"))
         |> put_flash(
           :error,
           "Check the appearance settings and try again."
         )}
    end
  end

  def handle_event("validate_profile", %{"user" => user_params}, socket) do
    profile_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: profile_form)}
  end

  def handle_event("update_profile", %{"user" => user_params}, socket) do
    case Accounts.update_user_profile(socket.assigns.current_scope.user, user_params) do
      {:ok, user} ->
        scope = %{socket.assigns.current_scope | user: user}

        {:noreply,
         socket
         |> assign(
           current_scope: scope,
           profile_form: to_form(Accounts.change_user_profile(user))
         )
         |> put_flash(:info, "Profile updated successfully.")}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp appearance_params(settings) do
    %{
      "cover_size" => settings.cover_size,
      "ignore_prefixes_when_sorting" => settings.ignore_prefixes_when_sorting,
      "date_format" => settings.date_format,
      "time_format" => settings.time_format
    }
  end
end
