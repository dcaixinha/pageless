defmodule PagelessWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PagelessWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :socket, :map, default: nil, doc: "the LiveView socket, used to render the sticky player"

  attr :active, :atom,
    default: nil,
    values: [nil, :home, :library, :series, :collections, :playlists, :settings, :stats, :account]

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[color:var(--pg-bg)] text-base-content">
      <header class="sticky top-0 z-30 border-b border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] shadow-sm backdrop-blur">
        <div class="flex h-16 items-center gap-4 px-4 sm:px-6 lg:px-8">
          <a
            navigate={~p"/"}
            href={~p"/"}
            class="flex shrink-0 items-center gap-2"
          >
            <img
              src={~p"/images/pageless-icon.svg"}
              width="32"
              height="32"
              alt="Pageless"
              class="rounded-xl shadow-sm"
            />
            <span class="pg-brand-wordmark text-xl font-bold">Pageless</span>
          </a>

          <div class="flex-1" />

          <div class="flex shrink-0 items-center gap-2">
            <%= if @current_scope && @current_scope.user do %>
              <.link
                navigate={~p"/users/stats"}
                title="Your Stats"
                class={[
                  "flex items-center gap-2 rounded-xl px-3 py-2 text-sm transition-colors",
                  if(@active == :stats,
                    do: "bg-[color:var(--pg-tab-active)] text-primary",
                    else: "hover:bg-[color:var(--pg-tab-active)]"
                  )
                ]}
              >
                <.icon name="hero-chart-bar" class="size-5" />
                <span class="hidden sm:inline">Stats</span>
              </.link>
              <.link
                navigate={~p"/users/settings"}
                title="Account"
                class={[
                  "flex max-w-56 items-center gap-2 rounded-xl px-3 py-2 text-sm transition-colors",
                  if(@active == :account,
                    do: "bg-[color:var(--pg-tab-active)] text-primary",
                    else: "hover:bg-[color:var(--pg-tab-active)]"
                  )
                ]}
              >
                <.icon name="hero-user-circle" class="size-5" />
                <span class="hidden truncate sm:inline">
                  {Pageless.Accounts.User.display_name(@current_scope.user)}
                </span>
              </.link>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                title="Log out"
                class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm transition-colors hover:bg-[color:var(--pg-tab-active)]"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
                <span class="hidden sm:inline">Log out</span>
              </.link>
            <% end %>
          </div>
        </div>

        <nav class="flex overflow-x-auto border-t border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] sm:justify-center">
          <.nav_link navigate={~p"/"} icon="hero-home" active={@active == :home}>Home</.nav_link>
          <.nav_link navigate={~p"/library"} icon="hero-rectangle-stack" active={@active == :library}>Library</.nav_link>
          <.nav_link navigate={~p"/series"} icon="hero-book-open" active={@active == :series}>
            Series
          </.nav_link>
          <.nav_link
            navigate={~p"/collections"}
            icon="hero-squares-2x2"
            active={@active == :collections}
          >
            Collections
          </.nav_link>
          <.nav_link navigate={~p"/playlists"} icon="hero-queue-list" active={@active == :playlists}>
            Playlists
          </.nav_link>
          <%= if @current_scope && @current_scope.user && Pageless.Accounts.User.admin?(@current_scope.user) do %>
            <.nav_link
              navigate={~p"/settings/users"}
              icon="hero-cog-6-tooth"
              active={@active == :settings}
            >
              Settings
            </.nav_link>
          <% end %>
        </nav>
      </header>

      <main class="px-4 py-6 pb-40 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>
    </div>

    <%= if @socket && @current_scope && @current_scope.user do %>
      {live_render(@socket, PagelessWeb.PlayerLive, id: "player-live", sticky: true)}
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex min-h-16 items-center justify-center gap-2 border-b-2 px-4 py-3 text-sm font-medium text-primary transition-colors sm:min-w-40 sm:flex-col sm:gap-1",
        if(@active,
          do: "border-primary bg-[color:var(--pg-tab-active)]",
          else: "border-transparent hover:bg-[color:var(--pg-tab-active)]"
        )
      ]}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :active, :atom, required: true
  slot :inner_block, required: true

  def settings_shell(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl">
      <div class="grid gap-6 md:grid-cols-[14rem_1fr]">
        <aside class="md:sticky md:top-20 md:self-start">
          <div class="rounded-2xl border border-[color:var(--pg-border)] bg-[color:var(--pg-surface)] p-2 shadow-sm">
            <div class="px-3 py-3">
              <p class="text-xs font-semibold uppercase tracking-wide text-primary">Settings</p>
            </div>
            <nav class="flex gap-1 overflow-x-auto md:flex-col md:overflow-visible">
              <.settings_nav_link
                navigate={~p"/settings/users"}
                icon="hero-users"
                active={@active == :users}
              >
                Users
              </.settings_nav_link>
              <.settings_nav_link
                navigate={~p"/settings/libraries"}
                icon="hero-rectangle-stack"
                active={@active == :libraries}
              >
                Libraries
              </.settings_nav_link>
              <.settings_nav_link
                navigate={~p"/settings/listening-sessions"}
                icon="hero-chart-bar"
                active={@active == :listening_sessions}
              >
                Listening Sessions
              </.settings_nav_link>
            </nav>
          </div>
        </aside>

        <div class="min-w-0">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp settings_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex shrink-0 items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary text-primary-content shadow-sm",
          else: "text-base-content/75 hover:bg-[color:var(--pg-tab-active)] hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  attr :labels, :boolean, default: false

  def theme_toggle(assigns) do
    ~H"""
    <div class={[
      "relative grid w-full grid-cols-3 overflow-hidden rounded-full border border-[color:var(--pg-border)] bg-[color:var(--pg-tab)] shadow-inner",
      if(@labels, do: "h-12", else: "h-10")
    ]}>
      <div class="absolute inset-y-0 left-0 w-1/3 rounded-full border border-primary/45 bg-[color:var(--pg-toggle-active)] shadow-[0_0_0_1px_rgba(139,92,246,0.22),0_10px_24px_rgba(0,0,0,0.18)] transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        type="button"
        class="relative z-10 flex h-full w-full cursor-pointer items-center justify-center px-3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <span class="inline-block whitespace-nowrap leading-none">
          <.icon
            name="hero-computer-desktop-micro"
            class="inline-block size-4 align-middle opacity-75 hover:opacity-100"
          />
          <span
            :if={@labels}
            class="inline-block text-sm font-medium leading-none"
          >System</span>
        </span>
      </button>

      <button
        type="button"
        class="relative z-10 flex h-full w-full cursor-pointer items-center justify-center px-3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <span class="inline-block whitespace-nowrap leading-none">
          <.icon
            name="hero-sun-micro"
            class="inline-block size-4 align-middle opacity-75 hover:opacity-100"
          />
          <span
            :if={@labels}
            class="inline-block text-sm font-medium leading-none"
          >Light</span>
        </span>
      </button>

      <button
        type="button"
        class="relative z-10 flex h-full w-full cursor-pointer items-center justify-center px-3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <span class="inline-block whitespace-nowrap leading-none">
          <.icon
            name="hero-moon-micro"
            class="inline-block size-4 align-middle opacity-75 hover:opacity-100"
          />
          <span
            :if={@labels}
            class="inline-block text-sm font-medium leading-none"
          >Dark</span>
        </span>
      </button>
    </div>
    """
  end
end
