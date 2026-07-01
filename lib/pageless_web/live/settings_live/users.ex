defmodule PagelessWeb.SettingsLive.Users do
  use PagelessWeb, :live_view

  alias Pageless.Accounts
  alias Pageless.Accounts.User
  alias Pageless.Format
  alias Pageless.Library

  @impl true
  def mount(_params, _session, socket) do
    settings = Accounts.get_player_settings(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(page_title: "Manage Users")
     |> assign(date_format: settings.date_format, time_format: settings.time_format)
     |> assign(mode: :new, selected_user: nil, selected_library_ids: [], show_user_modal: false)
     |> assign(libraries: Library.list_libraries())
     |> assign_users()
     |> assign_new_form()}
  end

  defp assign_users(socket) do
    assign(socket, users: Accounts.list_users(socket.assigns.current_scope))
  end

  defp assign_new_form(socket) do
    changeset = Accounts.change_managed_user(socket.assigns.current_scope, %User{})

    socket
    |> assign(mode: :new, selected_user: nil, selected_library_ids: [])
    |> assign(form: to_form(changeset, as: "user"))
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    user = socket.assigns.selected_user || %User{}

    changeset =
      socket.assigns.current_scope
      |> Accounts.change_managed_user(user, params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset, as: "user"))
     |> assign(selected_library_ids: selected_library_ids(params))}
  end

  def handle_event("save", %{"user" => params}, %{assigns: %{mode: :new}} = socket) do
    case Accounts.create_managed_user(socket.assigns.current_scope, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created.")
         |> assign(show_user_modal: false)
         |> assign_users()
         |> assign_new_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: "user"))
         |> assign(selected_library_ids: selected_library_ids(params))}
    end
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_managed_user(
           socket.assigns.current_scope,
           socket.assigns.selected_user,
           params
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> assign(show_user_modal: false)
         |> assign_users()
         |> assign_new_form()}

      {:error, reason} when reason in [:cannot_disable_self, :last_admin] ->
        {:noreply, put_flash(socket, :error, safety_message(reason))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: "user"))
         |> assign(selected_library_ids: selected_library_ids(params))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    user = Accounts.get_managed_user!(socket.assigns.current_scope, id)
    changeset = Accounts.change_managed_user(socket.assigns.current_scope, user)

    {:noreply,
     socket
     |> assign(mode: :edit, selected_user: user)
     |> assign(show_user_modal: true)
     |> assign(selected_library_ids: Enum.map(user.libraries, & &1.id))
     |> assign(form: to_form(changeset, as: "user"))}
  end

  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign_new_form() |> assign(show_user_modal: true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(show_user_modal: false) |> assign_new_form()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_managed_user!(socket.assigns.current_scope, id)

    case Accounts.delete_managed_user(socket.assigns.current_scope, user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User deleted.")
         |> assign_users()
         |> assign_new_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, safety_message(reason))}
    end
  end

  defp selected_library_ids(%{"library_ids" => ids}), do: Enum.reject(ids, &(&1 == ""))
  defp selected_library_ids(_), do: []

  defp safety_message(:cannot_disable_self), do: "You cannot disable your own account."
  defp safety_message(:cannot_delete_self), do: "You cannot delete your own account."
  defp safety_message(:last_admin), do: "At least one enabled admin account is required."

  defp selected?(ids, id), do: id in ids

  defp role_label("admin"), do: "Admin"
  defp role_label(_), do: "User"

  defp format_datetime(nil, _date_format, _time_format), do: "Never"

  defp format_datetime(datetime, date_format, time_format),
    do: Format.datetime(datetime, date_format, time_format)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:settings}>
      <Layouts.settings_shell active={:users}>
        <div class="space-y-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h1 class="text-3xl font-bold tracking-tight">Users</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Create accounts, assign roles, and control library access.
              </p>
            </div>
            <button
              type="button"
              id="add-user-button"
              phx-click="new"
              class="inline-flex items-center justify-center gap-2 rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:opacity-90"
            >
              <.icon name="hero-plus" class="size-4" /> Add user
            </button>
          </div>

          <div>
            <section class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
              <div class="flex items-center justify-between border-b border-base-300 px-5 py-4">
                <h2 class="font-semibold">Accounts</h2>
                <span class="rounded-full bg-base-200 px-2.5 py-1 text-xs font-medium">{length(@users)}</span>
              </div>

              <div id="users-list" class="divide-y divide-base-300">
                <div
                  :for={user <- @users}
                  id={"user-#{user.id}"}
                  class="grid gap-3 px-5 py-4 md:grid-cols-[1fr_auto] md:items-center"
                >
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={[
                        "size-2.5 rounded-full",
                        if(user.enabled, do: "bg-success", else: "bg-base-content/30")
                      ]} />
                      <span class="truncate font-medium">{User.display_name(user)}</span>
                      <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs">{role_label(
                        user.role
                      )}</span>
                    </div>
                    <p class="text-xs text-base-content/60">
                      {user.email} · Last seen: {format_datetime(
                        user.last_seen_at,
                        @date_format,
                        @time_format
                      )} · Created: {format_datetime(
                        user.inserted_at,
                        @date_format,
                        @time_format
                      )}
                    </p>
                  </div>

                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="edit"
                      phx-value-id={user.id}
                      class="rounded-lg border border-base-300 px-3 py-2 text-sm hover:bg-base-200"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={user.id}
                      data-confirm="Delete this user and all of their progress/bookmarks?"
                      class="rounded-lg border border-error/40 px-3 py-2 text-sm text-error hover:bg-error/10"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div
            :if={@show_user_modal}
            id="user-modal"
            class="fixed inset-0 z-50 flex items-center justify-center p-4"
            phx-window-keydown="cancel"
            phx-key="escape"
          >
            <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="cancel" />
            <section class="relative max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-5 shadow-2xl">
              <div class="mb-4 flex items-center justify-between gap-4">
                <h2 class="text-lg font-semibold">
                  {if @mode == :new, do: "Add user", else: "Edit user"}
                </h2>
                <button
                  type="button"
                  phx-click="cancel"
                  aria-label="Close"
                  class="rounded-full p-2 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>

              <.form
                for={@form}
                id="user-form"
                phx-change="validate"
                phx-submit="save"
                class="mt-4 space-y-4"
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
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email"
                  required
                  autocomplete="username"
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label={if @mode == :new, do: "Password", else: "New password"}
                  required={@mode == :new}
                  autocomplete="new-password"
                />
                <.input
                  field={@form[:role]}
                  type="select"
                  label="Account type"
                  options={[{"User", "user"}, {"Admin", "admin"}]}
                />
                <.input field={@form[:enabled]} type="checkbox" label="Enabled" />

                <.inputs_for :let={permissions} field={@form[:permissions]}>
                  <div class="rounded-xl border border-base-300 p-4">
                    <h3 class="text-sm font-semibold">Permissions</h3>
                    <div class="mt-3 space-y-2">
                      <.input field={permissions[:can_download]} type="checkbox" label="Can download" />
                      <.input
                        field={permissions[:can_update]}
                        type="checkbox"
                        label="Can update metadata"
                      />
                      <.input field={permissions[:can_delete]} type="checkbox" label="Can delete" />
                      <.input field={permissions[:can_upload]} type="checkbox" label="Can upload" />
                      <.input
                        field={permissions[:can_access_all_libraries]}
                        type="checkbox"
                        label="Can access all libraries"
                      />
                    </div>
                  </div>
                </.inputs_for>

                <div class="rounded-xl border border-base-300 p-4">
                  <h3 class="text-sm font-semibold">Library access</h3>
                  <p class="mt-1 text-xs text-base-content/60">
                    Used when “Can access all libraries” is disabled.
                  </p>
                  <input type="hidden" name="user[library_ids][]" value="" />
                  <div class="mt-3 space-y-2">
                    <label :for={library <- @libraries} class="flex items-center gap-2 text-sm">
                      <input
                        type="checkbox"
                        name="user[library_ids][]"
                        value={library.id}
                        checked={selected?(@selected_library_ids, library.id)}
                        class="checkbox checkbox-sm"
                      />
                      <span>{library.name}</span>
                    </label>
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    type="submit"
                    class="rounded-xl bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90"
                  >
                    {if @mode == :new, do: "Create user", else: "Save changes"}
                  </button>
                  <button
                    type="button"
                    phx-click="cancel"
                    class="rounded-xl border border-base-300 px-4 py-2 text-sm hover:bg-base-200"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            </section>
          </div>
        </div>
      </Layouts.settings_shell>
    </Layouts.app>
    """
  end
end
