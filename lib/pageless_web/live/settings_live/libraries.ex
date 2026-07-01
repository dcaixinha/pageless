defmodule PagelessWeb.SettingsLive.Libraries do
  use PagelessWeb, :live_view

  alias Pageless.Format
  alias Pageless.Library
  alias Pageless.Library.Library, as: LibrarySchema
  alias Pageless.Library.LibraryFolder
  alias Pageless.Library.ScanCoordinator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pageless.PubSub, "library_scans")

    {:ok,
     socket
     |> assign(page_title: "Manage Libraries")
     |> assign(scan_status: %{})
     |> assign(mode: :new, selected_library: nil)
     |> assign(show_library_modal: false)
     |> assign_libraries()
     |> assign_new_form()}
  end

  defp assign_libraries(socket) do
    libraries = Library.list_libraries()

    counts =
      Map.new(libraries, fn lib -> {lib.id, Library.count_books(lib.id)} end)

    assign(socket, libraries: libraries, book_counts: counts)
  end

  defp assign_new_form(socket) do
    changeset =
      Library.change_library(%LibrarySchema{folders: [%LibraryFolder{}]})

    socket
    |> assign(mode: :new, selected_library: nil)
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"library" => params}, socket) do
    library = socket.assigns.selected_library || %LibrarySchema{}

    changeset =
      library
      |> Library.change_library(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"library" => params}, %{assigns: %{mode: :new}} = socket) do
    case Library.create_library(normalize_folders(params)) do
      {:ok, library} ->
        {:noreply,
         socket
         |> put_flash(:info, "Library created. Scan started.")
         |> assign(show_library_modal: false)
         |> assign_libraries()
         |> assign_new_form()
         |> start_scan(library)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"library" => params}, socket) do
    case Library.update_library(socket.assigns.selected_library, normalize_folders(params)) do
      {:ok, _library} ->
        {:noreply,
         socket
         |> put_flash(:info, "Library updated.")
         |> assign(show_library_modal: false)
         |> assign_libraries()
         |> assign_new_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    library = Library.get_library!(id)

    form_library =
      if library.folders == [], do: %{library | folders: [%LibraryFolder{}]}, else: library

    {:noreply,
     socket
     |> assign(mode: :edit, selected_library: library)
     |> assign(show_library_modal: true)
     |> assign(form: to_form(Library.change_library(form_library)))}
  end

  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign_new_form() |> assign(show_library_modal: true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(show_library_modal: false) |> assign_new_form()}
  end

  def handle_event("scan", %{"id" => id}, socket) do
    library = Library.get_library!(id)
    {:noreply, start_scan(socket, library)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    library = Library.get_library!(id)
    {:ok, _} = Library.delete_library(library)

    {:noreply,
     socket
     |> put_flash(:info, "Library deleted.")
     |> assign_libraries()}
  end

  @impl true
  def handle_info({:scan_started, %{library_id: library_id}}, socket) do
    status =
      Map.put(socket.assigns.scan_status, library_id, %{state: :running, current: 0, total: 0})

    {:noreply, assign(socket, scan_status: status)}
  end

  def handle_info(
        {:scan_progress, %{library_id: library_id, current: current, total: total}},
        socket
      ) do
    current_status = Map.get(socket.assigns.scan_status, library_id, %{state: :running})

    status =
      Map.put(
        socket.assigns.scan_status,
        library_id,
        Map.merge(current_status, %{current: current, total: total})
      )

    {:noreply, assign(socket, scan_status: status)}
  end

  def handle_info({:scan_finished, %{library_id: library_id, result: result}}, socket) do
    status = Map.put(socket.assigns.scan_status, library_id, %{state: :done, result: result})

    {:noreply,
     socket
     |> assign(scan_status: status)
     |> assign_libraries()
     |> put_flash(:info, "Scan complete: #{Format.count(result.scanned, "book")} imported.")}
  end

  def handle_info({:scan_failed, %{library_id: library_id}}, socket) do
    status = Map.put(socket.assigns.scan_status, library_id, %{state: :failed})

    {:noreply,
     socket
     |> assign(scan_status: status)
     |> put_flash(:error, "Library scan failed.")}
  end

  defp normalize_folders(%{"folders" => folders} = params) when is_map(folders) do
    cleaned =
      folders
      |> Map.values()
      |> Enum.reject(&(String.trim(&1["path"] || "") == ""))

    Map.put(params, "folders", cleaned)
  end

  defp normalize_folders(params), do: params

  defp start_scan(socket, library) do
    ScanCoordinator.request_scan(library, :manual)

    status =
      Map.put(socket.assigns.scan_status, library.id, %{state: :running, current: 0, total: 0})

    assign(socket, scan_status: status)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} socket={@socket} active={:settings}>
      <Layouts.settings_shell active={:libraries}>
        <div class="max-w-3xl space-y-8">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h1 class="text-2xl font-bold">Manage Libraries</h1>
              <p class="mt-1 text-base-content/70">
                Create libraries and point them at folders on the server to scan for audiobooks.
              </p>
            </div>
            <button
              type="button"
              id="add-library-button"
              phx-click="new"
              class="inline-flex shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:opacity-90"
            >
              <.icon name="hero-plus" class="size-4" />
              <span>Add library</span>
            </button>
          </div>

          <section class="space-y-4">
            <h2 class="text-lg font-semibold">Your libraries</h2>

            <div
              :if={@libraries == []}
              class="rounded-xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              No libraries yet. Add one to start scanning for audiobooks.
            </div>

            <ul class="space-y-3">
              <li
                :for={library <- @libraries}
                id={"library-#{library.id}"}
                class="rounded-xl border border-base-300 p-4"
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <div class="font-semibold">{library.name}</div>
                    <div class="text-sm text-base-content/60">
                      {Format.count(Map.get(@book_counts, library.id, 0), "book")}
                    </div>
                    <ul class="mt-2 space-y-1">
                      <li
                        :for={folder <- library.folders}
                        class="text-xs text-base-content/50 font-mono truncate"
                      >
                        {folder.path}
                      </li>
                    </ul>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <button
                      type="button"
                      id={"edit-library-#{library.id}"}
                      phx-click="edit"
                      phx-value-id={library.id}
                      class="inline-flex items-center gap-2 rounded-lg border border-base-300 px-3 py-2 text-sm hover:bg-base-200 transition"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                      <span class="sr-only sm:not-sr-only">Edit</span>
                    </button>
                    <button
                      type="button"
                      id={"scan-library-#{library.id}"}
                      phx-click="scan"
                      phx-value-id={library.id}
                      class="inline-flex items-center gap-2 rounded-lg bg-primary px-3 py-2 text-sm font-medium text-primary-content hover:opacity-90 transition disabled:opacity-50"
                      disabled={scanning?(@scan_status, library.id)}
                    >
                      <.icon
                        name="hero-arrow-path"
                        class={["size-4", scanning?(@scan_status, library.id) && "animate-spin"]}
                      />
                      {if scanning?(@scan_status, library.id), do: "Scanning…", else: "Scan"}
                    </button>
                    <button
                      type="button"
                      id={"delete-library-#{library.id}"}
                      phx-click="delete"
                      phx-value-id={library.id}
                      data-confirm="Delete this library and all its books?"
                      class="inline-flex items-center rounded-lg border border-base-300 px-3 py-2 text-sm hover:bg-base-200 transition"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </div>

                <% status = Map.get(@scan_status, library.id) %>
                <div :if={status} class="mt-3 text-sm">
                  <%= case status do %>
                    <% %{state: :running, total: total, current: current} -> %>
                      <div class="text-base-content/70">
                        Scanning {current}/{max(total, 1)}…
                      </div>
                      <div class="mt-1 h-2 w-full overflow-hidden rounded-full bg-base-300">
                        <div
                          class="h-full bg-primary transition-all"
                          style={"width: #{progress_pct(current, total)}%"}
                        >
                        </div>
                      </div>
                    <% %{state: :done, result: result} -> %>
                      <div class="text-success">
                        Imported {Format.count(result.scanned, "book")}{if result.errors > 0,
                          do: ", #{Format.count(result.errors, "error")}"}.
                      </div>
                    <% _ -> %>
                  <% end %>
                </div>
              </li>
            </ul>
          </section>

          <div
            :if={@show_library_modal}
            id="library-modal"
            class="fixed inset-0 z-50 flex items-center justify-center p-4"
            phx-window-keydown="cancel"
            phx-key="escape"
          >
            <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="cancel" />
            <section class="relative w-full max-w-xl rounded-2xl border border-base-300 bg-base-100 p-5 shadow-2xl">
              <div class="mb-4 flex items-center justify-between gap-4">
                <h2 class="text-lg font-semibold">
                  {if @mode == :new, do: "Add library", else: "Edit library"}
                </h2>
                <button
                  type="button"
                  id="close-library-modal"
                  phx-click="cancel"
                  aria-label="Close"
                  class="rounded-full p-2 text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
              <.form
                for={@form}
                id="library-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-4"
              >
                <.input field={@form[:name]} type="text" label="Name" placeholder="My Audiobooks" />
                <input type="hidden" name="library[media_type]" value="book" />

                <.inputs_for :let={folder} field={@form[:folders]}>
                  <.input
                    field={folder[:path]}
                    type="text"
                    label="Folder path"
                    placeholder="/data/audiobooks"
                  />
                </.inputs_for>

                <div class="rounded-xl border border-base-300 p-4">
                  <h3 class="text-sm font-semibold">Automatic scanning</h3>
                  <div class="mt-3 space-y-2">
                    <.input
                      field={@form[:auto_scan_on_file_changes]}
                      type="checkbox"
                      label="Automatically scan for file changes"
                    />
                    <p class="text-xs text-base-content/60">
                      Detect additions, removals, renames, metadata, audio tag, and cover changes.
                    </p>
                  </div>
                </div>

                <div class="rounded-xl border border-base-300 p-4">
                  <h3 class="text-sm font-semibold">Item storage</h3>
                  <p class="mt-1 text-xs text-base-content/60">
                    Choose which generated files are kept alongside each audiobook.
                  </p>
                  <div class="mt-3 space-y-2">
                    <.input
                      field={@form[:store_covers_with_item]}
                      type="checkbox"
                      label="Store covers with item"
                    />
                    <.input
                      field={@form[:store_metadata_with_item]}
                      type="checkbox"
                      label="Store metadata with item"
                    />
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    type="submit"
                    id="save-library-button"
                    class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:opacity-90 transition"
                  >
                    <.icon
                      name={if @mode == :new, do: "hero-plus", else: "hero-check"}
                      class="size-4"
                    />
                    {if @mode == :new, do: "Create and scan", else: "Save changes"}
                  </button>
                  <button
                    type="button"
                    id="cancel-library-button"
                    phx-click="cancel"
                    class="rounded-lg border border-base-300 px-4 py-2 text-sm hover:bg-base-200"
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

  defp scanning?(status, id), do: match?(%{state: :running}, Map.get(status, id))

  defp progress_pct(_current, total) when total in [0, nil], do: 10
  defp progress_pct(current, total), do: min(round(current / total * 100), 100)
end
