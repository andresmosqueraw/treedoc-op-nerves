defmodule Doc.Net do
  @moduledoc """
  Watches this node's IPv4 address and reacts to network (re)connection (p_dist P5, reused from a_dist).

  When the address appears or changes, the whole network stack (`Doc.Stack`:
  distribution and discovery) is (re)started with the new
  address; when it disappears the stack is stopped. The node name contains the IP,
  so a new IP means a new node name.

  The address source is a backend (`:net` in the app env):

    * `Doc.Net.VintageNet` on Nerves (subscribes to `wlan0`/`eth0` addresses);
    * `Doc.Net.Inet` on the host (polls `:inet.getifaddrs/0`, or a fixed `:ip`).
  """
  use GenServer
  require Logger

  @callback init(pid()) :: :ok
  @callback current_ip() :: :inet.ip4_address() | nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The address the stack is running with (nil when offline). Read from
  `:persistent_term`, NOT with a call: Net itself starts the stack synchronously
  and `Doc.Dist.init/1` needs the IP, so a call would deadlock.
  """
  def ip, do: :persistent_term.get({__MODULE__, :ip}, nil)

  defp put_ip(ip), do: :persistent_term.put({__MODULE__, :ip}, ip)

  @doc "Called by the backends when something about the addresses changed."
  def changed, do: send(__MODULE__, :check)

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, Application.get_env(:opdoc, :net, Doc.Net.Inet))
    :ok = backend.init(self())
    send(self(), :check)
    {:ok, %{backend: backend, ip: nil}}
  end

  @impl true
  def handle_call(:restart_stack, _from, s) do
    stop_stack()
    if s.ip, do: start_stack()
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:check, s) do
    new_ip = s.backend.current_ip()

    cond do
      new_ip == s.ip ->
        {:noreply, s}

      new_ip == nil ->
        Logger.warning("[opdoc] network lost (was #{fmt(s.ip)}), stopping stack")
        stop_stack()
        put_ip(nil)
        {:noreply, %{s | ip: nil}}

      true ->
        Logger.info("[opdoc] network up: #{fmt(s.ip)} -> #{fmt(new_ip)}, (re)starting stack")
        s = %{s | ip: new_ip}
        stop_stack()
        put_ip(new_ip)
        start_stack()
        {:noreply, s}
    end
  end

  # VintageNet property notifications ({VintageNet, ...}) and similar: re-check.
  def handle_info(_msg, s) do
    send(self(), :check)
    {:noreply, s}
  end

  # The stack is added to Doc.NetSup dynamically, after Net, so with the
  # supervisor's :rest_for_one strategy a crash of Net also restarts the stack.
  defp start_stack do
    result =
      case Supervisor.restart_child(Doc.NetSup, Doc.Stack) do
        {:error, :not_found} -> Supervisor.start_child(Doc.NetSup, Doc.Stack)
        other -> other
      end

    case result do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.error("[opdoc] cannot start stack: #{inspect(reason)}")
    end
  end

  defp stop_stack, do: Supervisor.terminate_child(Doc.NetSup, Doc.Stack)

  @doc "Restart the stack with the current IP (used after `Doc.set_domain/1`)."
  def restart_stack, do: GenServer.call(__MODULE__, :restart_stack)

  def fmt(nil), do: "nil"
  def fmt(ip), do: ip |> :inet.ntoa() |> to_string()
end

defmodule Doc.Net.Inet do
  @moduledoc """
  Host backend: fixed IP from config (`:ip`, e.g. `ADHOC_IP=172.30.0.11`) or the
  first IPv4 of an interface that is up (optionally `:ifname`). Polled every 3 s.
  """
  @behaviour Doc.Net
  @ignored ~w(lo docker0 virbr0)

  @impl true
  def init(_pid) do
    {:ok, _} = :timer.apply_interval(3_000, Doc.Net, :changed, [])
    :ok
  end

  @impl true
  def current_ip do
    case Application.get_env(:opdoc, :ip) do
      ip when is_binary(ip) ->
        {:ok, addr} = :inet.parse_ipv4_address(String.to_charlist(ip))
        addr

      _ ->
        first_ipv4(Application.get_env(:opdoc, :ifname))
    end
  end

  defp first_ipv4(wanted) do
    {:ok, ifs} = :inet.getifaddrs()

    ifs
    |> Enum.filter(fn {name, opts} ->
      name = to_string(name)
      up = :up in Keyword.get(opts, :flags, [])

      up and
        if(wanted,
          do: name == wanted,
          else: name not in @ignored and not String.starts_with?(name, "br-")
        )
    end)
    |> Enum.flat_map(fn {_, opts} -> for {:addr, {_, _, _, _} = a} <- opts, do: a end)
    |> List.first()
  end
end

if Code.ensure_loaded?(VintageNet) do
  defmodule Doc.Net.VintageNet do
    @moduledoc "Nerves backend: subscribes to the IPv4 addresses of wlan0 and eth0."
    @behaviour Doc.Net
    @ifaces ["wlan0", "eth0"]

    @impl true
    def init(_pid) do
      for i <- @ifaces, do: VintageNet.subscribe(["interface", i, "addresses"])
      :ok
    end

    @impl true
    def current_ip do
      Enum.find_value(@ifaces, fn i ->
        VintageNet.get(["interface", i, "addresses"], [])
        |> Enum.find_value(fn
          %{family: :inet, address: a} -> a
          _ -> nil
        end)
      end)
    end
  end
end
