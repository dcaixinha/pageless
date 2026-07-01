defmodule PagelessWeb.Router do
  use PagelessWeb, :router

  import PagelessWeb.UserAuth
  import PagelessWeb.ApiAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PagelessWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_api_user
  end

  pipeline :api_authenticated do
    plug :require_api_user
  end

  ## Mobile JSON API
  #
  # `POST /api/session` is public (exchanges credentials for a bearer token).
  # Everything else requires the `Authorization: Bearer <token>` header, which
  # `fetch_api_user`/`require_api_user` resolve into `current_scope`.
  scope "/api", PagelessWeb.API do
    pipe_through :api

    post "/session", SessionController, :create
  end

  scope "/api", PagelessWeb.API do
    pipe_through [:api, :api_authenticated]

    delete "/session", SessionController, :delete

    get "/me", MeController, :show

    get "/home", HomeController, :index

    get "/libraries", LibraryController, :index

    get "/series", SeriesController, :index
    get "/series/:id", SeriesController, :show

    get "/collections", CollectionController, :index
    get "/collections/:id", CollectionController, :show

    get "/playlists", PlaylistController, :index
    get "/playlists/:id", PlaylistController, :show

    get "/books", BookController, :index
    get "/books/:id", BookController, :show
    get "/books/:id/download", BookController, :download
    get "/books/:id/cover", BookController, :cover
    get "/books/:book_id/bookmarks", BookmarkController, :index_for_book

    get "/progress", ProgressController, :index
    post "/progress/:book_id", ProgressController, :update
    post "/listening-history", ListeningHistoryController, :create

    get "/bookmarks", BookmarkController, :index
    put "/bookmarks/:id", BookmarkController, :update
    delete "/bookmarks/:id", BookmarkController, :delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pageless, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PagelessWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PagelessWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PagelessWeb.UserAuth, :require_authenticated}] do
      live "/", HomeLive, :index
      live "/library", LibraryLive.Index, :index
      live "/series", LibraryLive.Series, :index
      live "/series/:id", LibraryLive.Series, :show
      live "/collections", LibraryLive.Collections, :index
      live "/collections/:id", LibraryLive.Collections, :show
      live "/playlists", LibraryLive.Playlists, :index
      live "/playlists/:id", LibraryLive.Playlists, :show
      live "/books/:id", LibraryLive.Show, :show

      live "/users/stats", UserLive.Stats, :index
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    get "/books/:id/cover", CoverController, :show

    post "/users/update-password", UserSessionController, :update_password
  end

  # Audio streaming authorizes via the current session OR a signed token, so it
  # uses the plain browser pipeline (the controller enforces access itself).
  scope "/", PagelessWeb do
    pipe_through [:browser]

    get "/books/:id/audio", AudioController, :stream
  end

  ## Admin routes

  scope "/", PagelessWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_user]

    live_session :require_admin_user,
      on_mount: [{PagelessWeb.UserAuth, :require_admin}] do
      live "/settings/users", SettingsLive.Users, :index
      live "/settings/libraries", SettingsLive.Libraries, :index
      live "/settings/listening-sessions", SettingsLive.ListeningSessions, :index
    end
  end

  scope "/", PagelessWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PagelessWeb.UserAuth, :mount_current_scope}] do
      live "/setup", UserLive.Setup, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
