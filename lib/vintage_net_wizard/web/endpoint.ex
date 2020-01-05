defmodule VintageNetWizard.Web.Endpoint do
  @moduledoc """
  Supervisor for the Web part of the VintageNet Wizard.
  """
  alias VintageNetWizard.{Backend, Callbacks, Web.Router, Web.RedirectRouter}
  use DynamicSupervisor

  @type opt :: {:ssl, :ssl.tls_server_option()} | {:on_exit, {module(), atom(), list()}}

  @doc false
  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  Start the web server

  If the web server is started then `{:error, already_started}` is returned.

  Only one server can be running at a time.
  """
  @spec start_server([opt]) ::
          :ok | {:error, :already_started | :no_keyfile | :no_certfile}
  def start_server(opts \\ []) do
    use_ssl? = Keyword.has_key?(opts, :ssl)
    backend = Application.get_env(:vintage_net_wizard, :backend, VintageNetWizard.Backend.Default)
    callbacks = Keyword.take(opts, [:on_exit])

    with spec <- maybe_use_ssl(use_ssl?, opts),
         {:ok, _pid} <- maybe_with_redirect(spec),
         {:ok, _pid} <- DynamicSupervisor.start_child(__MODULE__, {Backend, backend}),
         {:ok, _pid} <- DynamicSupervisor.start_child(__MODULE__, {Callbacks, callbacks}) do
      :ok
    else
      {:error, :max_children} -> {:error, :already_started}
      error -> error
    end
  end

  @doc """
  Stop the web server
  """
  @spec stop_server() :: :ok | {:error, :not_found}
  def stop_server() do
    case DynamicSupervisor.which_children(__MODULE__) do
      [{_, cowboy, _, _}, {_, redirector, _, _}, {_, backend, _, _}, {_, callbacks, _, _}] ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, redirector)
        _ = DynamicSupervisor.terminate_child(__MODULE__, cowboy)
        _ = DynamicSupervisor.terminate_child(__MODULE__, backend)

        _ = VintageNetWizard.Callbacks.on_exit()
        _ = DynamicSupervisor.terminate_child(__MODULE__, callbacks)

      [{_, cowboy, _, _}, {_, backend, _, _}, {_, callbacks, _, _}] ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, cowboy)
        _ = DynamicSupervisor.terminate_child(__MODULE__, backend)

        _ = VintageNetWizard.Callbacks.on_exit()
        _ = DynamicSupervisor.terminate_child(__MODULE__, callbacks)

      _ ->
        {:error, :not_found}
    end
  end

  @impl DynamicSupervisor
  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 3)
  end

  defp dispatch do
    [
      {:_,
       [
         {:_, Plug.Cowboy.Handler, {Router, []}}
       ]}
    ]
  end

  defp maybe_with_redirect([main, redirector]) do
    with {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__, main),
         {:ok, _pid} <- DynamicSupervisor.start_child(__MODULE__, redirector) do
      {:ok, pid}
    else
      error -> error
    end
  end

  defp maybe_with_redirect(spec), do: DynamicSupervisor.start_child(__MODULE__, spec)

  defp maybe_use_ssl(_use_ssl = true, opts) do
    dns_name = Application.get_env(:vintage_net_wizard, :dns_name, "wifi.config")
    port = Application.get_env(:vintage_net_wizard, :port, 443)
    ssl_options = Keyword.get(opts, :ssl)
    options = [dispatch: dispatch(), port: port]
    redirect_options = [scheme: :https, dns_name: dns_name, port: port]

    [
      Plug.Cowboy.child_spec(
        plug: Router,
        scheme: :https,
        options: Keyword.merge(ssl_options, options)
      ),
      Plug.Cowboy.child_spec(
        plug: {RedirectRouter, redirect_options},
        scheme: :http,
        options: [
          port: 80
        ]
      )
    ]
  end

  defp maybe_use_ssl(_no_ssl, _opts) do
    dns_name = Application.get_env(:vintage_net_wizard, :dns_name, "wifi.config")
    port = Application.get_env(:vintage_net_wizard, :port, 80)
    redirect_options = [scheme: :http, dns_name: dns_name, port: port]

    if port != 80 do
      [
        Plug.Cowboy.child_spec(
          plug: Router,
          scheme: :http,
          options: [
            dispatch: dispatch(),
            port: port
          ]
        ),
        Plug.Cowboy.child_spec(
          plug: {RedirectRouter, redirect_options},
          scheme: :http,
          options: [
            port: 80
          ]
        )
      ]
    else
      Plug.Cowboy.child_spec(
        plug: Router,
        scheme: :http,
        options: [
          dispatch: dispatch(),
          port: port
        ]
      )
    end
  end
end
