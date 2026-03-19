defmodule LostGreenWeb.Router do
  use LostGreenWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LostGreenWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug LostGreenWeb.UserManagement, :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public routes — profile selector/creator and utility
  scope "/", LostGreenWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/users", PageController, :create_user
    post "/users/select", PageController, :select_user

    get "/favicon.ico", PageController, :favicon
    get "/logout", PageController, :logout
    delete "/logout", PageController, :logout

    # Profile editing — requires an active session (checked in controller)
    get "/profile/edit", PageController, :edit_profile
    put "/profile", PageController, :update_profile
  end

  # Authenticated routes — requires a selected profile
  scope "/", LostGreenWeb do
    pipe_through :browser

    live_session :require_current_user,
      on_mount: [{LostGreenWeb.UserManagement, :require_current_user}] do
      live "/dashboard", DashboardLive
    end
  end

  scope "/internal", LostGreenWeb do
    pipe_through :api

    post "/shutdown", InternalController, :shutdown
  end

  # Other scopes may use custom stacks.
  # scope "/api", LostGreenWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:lost_green, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LostGreenWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
