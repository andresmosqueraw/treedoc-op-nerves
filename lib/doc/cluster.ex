defmodule Doc.Stack do
  @moduledoc """
  Network part that needs an IP: distribution, then discovery (rest_for_one).
  The replica (`Doc.Replica`) is NOT here: editing must keep working offline.
  """
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  def child_spec(arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, type: :supervisor}

  @impl true
  def init(_arg) do
    children =
      [Doc.Dist, Doc.Discovery] ++
        if(Application.get_env(:opdoc, :multicast, true), do: [Doc.Multicast], else: [])

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end

defmodule Doc.Dist do
  @moduledoc """
  Erlang distribution at runtime. If the VM was started with `--name`, that name
  is kept. Otherwise the long name is

      <base>-<epoch>@<IP>     e.g. nerves-1a2b-3f9c07@172.20.10.4

    * `<base>`: `:name` config / `OPDOC_NAME`, by default the hostname (the
      op-based groups use `<hostname>@IP`; any name is valid in the contract).
    * `<epoch>` (OUR, plan v5 §3.0): 6 random hex chars generated ONCE and kept
      in `<data_dir>/opdoc/epoch`, next to the operation log. The name authors
      the operations (`from`, PosIDs) and the vector clock counts per name, so a
      name must never restart its numbering. Reflashing a Pi (`mix burn`) wipes
      `/root`: the log AND the epoch go together, the node comes back with a new
      name and numbers from 1 under it, instead of reusing numbers that the
      others would drop as duplicates. Set `:epoch` to false to omit it.

  Ports (the contract, INTEGRATION.md L1): the distribution listens in
  4218–4228 (`:dist_ports`), so a firewall rule for that range is enough.
  `net_ticktime` 10 s so a Pi that leaves is detected quickly.
  """
  use GenServer
  require Logger

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  def node_name(ip), do: :"#{base_name()}@#{Doc.Net.fmt(ip)}"

  @doc "`<base>-<epoch>` (or just `<base>` with `epoch: false`)."
  def base_name do
    base = Application.get_env(:opdoc, :name) || hostname()
    if Application.get_env(:opdoc, :epoch, true), do: "#{base}-#{epoch()}", else: base
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, h} -> h |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
      _ -> "doc"
    end
  end

  @doc "This installation's epoch: read from disk, or generated and stored (fsync) once."
  def epoch do
    path = Doc.Storage.epoch_path()

    with {:ok, e} <- File.read(path),
         e = String.trim(e),
         true <- Regex.match?(~r/\A[0-9a-f]{6}\z/, e) do
      e
    else
      _ ->
        e = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        File.mkdir_p!(Path.dirname(path))
        {:ok, fd} = :file.open(path, [:write, :binary, :raw])
        :ok = :file.write(fd, e)
        :ok = :file.sync(fd)
        :ok = :file.close(fd)
        Logger.info("[opdoc] new epoch #{e} (stored in #{path})")
        e
    end
  end

  @impl true
  def init(_arg) do
    Process.flag(:trap_exit, true)

    started_here? =
      if Node.alive?() do
        false
      else
        epmd = System.find_executable("epmd") || epmd_in_erts()
        if epmd, do: System.cmd(epmd, ["-daemon"])
        name = node_name(Doc.Net.ip())
        {lo, hi} = Application.get_env(:opdoc, :dist_ports, {4218, 4228})
        Application.put_env(:kernel, :inet_dist_listen_min, lo)
        Application.put_env(:kernel, :inet_dist_listen_max, hi)

        case :net_kernel.start(name, %{name_domain: :longnames, net_ticktime: 10}) do
          {:ok, _} -> true
          {:error, {:already_started, _}} -> false
          {:error, reason} -> exit({:dist_start_failed, name, reason})
        end
      end

    Node.set_cookie(String.to_atom(Application.get_env(:opdoc, :cookie, "cpd2026")))
    Logger.info("[opdoc] distribution up as #{node()}")
    {:ok, %{started_here?: started_here?}}
  end

  # trap_exit: the port of `System.cmd("epmd")` and the like
  @impl true
  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, %{started_here?: true}) do
    for n <- Node.list(), do: Node.disconnect(n)
    :net_kernel.stop()
  end

  def terminate(_, _), do: :ok

  defp epmd_in_erts,
    do: Path.wildcard(Path.join([:code.root_dir(), "erts-*", "bin", "epmd"])) |> List.first()
end

defmodule Doc.Mdns do
  @moduledoc """
  mDNS contract (same idea as a_dist): every node publishes
  `<node>._opdoc._tcp.local` with TXT `app=opdoc` and `node=<node name>`.
  """
  @service_type "_opdoc._tcp"
  def service_type, do: @service_type

  @callback announce(node) :: :ok
  @callback withdraw() :: :ok
  @callback query() :: :ok
  @callback collect() :: [String.t()]

  def txt(node), do: ["app=opdoc", "node=#{node}"]

  @doc "Node name from a TXT record, or nil."
  def parse_txt(entries) when is_list(entries) do
    kv =
      for e <- entries,
          [k, v] <- [String.split(to_string(e), "=", parts: 2)],
          into: %{},
          do: {k, v}

    with %{"app" => "opdoc", "node" => n} <- kv,
         true <- Regex.match?(~r/^[A-Za-z0-9_\-]+@[0-9.]+$/, n) do
      n
    else
      _ -> nil
    end
  end

  def parse_txt(_), do: nil
end

if Code.ensure_loaded?(MdnsLite) do
  defmodule Doc.Mdns.Lite do
    @moduledoc "mdns_lite backend (Nerves and host)."
    @behaviour Doc.Mdns
    @id :opdoc

    @impl true
    def announce(node) do
      MdnsLite.add_mdns_service(%{
        id: @id,
        instance_name: Atom.to_string(node),
        type: Doc.Mdns.service_type(),
        port: 4369,
        txt_payload: Doc.Mdns.txt(node)
      })
    end

    @impl true
    def withdraw, do: MdnsLite.remove_mdns_service(@id)

    @impl true
    def query, do: MdnsLite.Responder.multicast_all(q())

    @impl true
    def collect do
      %{answer: a, additional: b} = MdnsLite.Responder.query_all_caches(q())

      for {:dns_rr, _, :txt, :in, _, _, txt, _, _, _} <- a ++ b,
          n = Doc.Mdns.parse_txt(txt),
          n != nil,
          uniq: true,
          do: n
    end

    defp q,
      do: {:dns_query, String.to_charlist(Doc.Mdns.service_type() <> ".local"), :ptr, :in, false}
  end
end

defmodule Doc.Mdns.Static do
  @moduledoc "Test backend: `collect/0` returns what `put_seen/1` configured."
  @behaviour Doc.Mdns
  def put_seen(nodes),
    do: Application.put_env(:opdoc, :static_seen, Enum.map(nodes, &to_string/1))

  @impl true
  def announce(_node), do: :ok
  @impl true
  def withdraw, do: :ok
  @impl true
  def query, do: :ok
  @impl true
  def collect, do: Application.get_env(:opdoc, :static_seen, [])
end

defmodule Doc.Discovery do
  import Bitwise, only: [>>>: 2, &&&: 2]

  @moduledoc """
  p_dist **Task 1**: clients discover each other in the network.

    * **dynamic**: mDNS (`_opdoc._tcp`), every `:discovery_interval` ms;
    * **explicit**: `:nodes` config / `OPDOC_NODES` ("ip1,ip2" or node names) and
      `Doc.connect/1` from IEx.

  Each round: announce, query, wait `:mdns_wait`, collect, `Node.connect/1` to
  the new ones (60 s backoff after a failure). Distribution then reports
  `nodeup` to the replica, which re-sends its whole history.

  The op-based groups' UDP multicast announcement is `Doc.Multicast`.

  Optional **subnet scan** (`:scan`, on by default on the Pi; `OPDOC_SCAN=on` on
  a host): every `:scan_interval` ms ask epmd on every address of the local
  subnet (at most a /24) which nodes it runs, and connect to them. The nodes of
  other groups do not announce `_opdoc._tcp`, and reaching any one of them is
  enough: Erlang's transitive connections (`connect_all`) join the rest.
  """
  use GenServer
  require Logger

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  def discover_now, do: GenServer.call(__MODULE__, :now, 30_000)

  @doc """
  Explicit target → node atoms. A full name (`x@ip`) is used as is. For a bare
  IP, epmd on that host is asked which names it has (`:erl_epmd.names/1`): each
  Pi has its own hostname/epoch, so the name cannot be guessed from ours.
  """
  def to_nodes(target) do
    t = to_string(target)

    cond do
      String.contains?(t, "@") ->
        [String.to_atom(t)]

      match?({:ok, _}, ip = :inet.parse_ipv4_address(String.to_charlist(t))) ->
        nodes_at(elem(ip, 1))

      true ->
        []
    end
  end

  @name_re ~r/\A[A-Za-z0-9_\-.]{1,64}\z/

  @doc "Node names registered in epmd at `ip` (empty if unreachable; 3 s at most)."
  def nodes_at(ip, timeout \\ 3_000) do
    task = Task.async(fn -> :erl_epmd.names(ip) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, names}} ->
        for {name, _port} <- names,
            n = to_string(name),
            Regex.match?(@name_re, n),
            do: :"#{n}@#{Doc.Net.fmt(ip)}"

      _ ->
        []
    end
  end

  def explicit_nodes do
    Application.get_env(:opdoc, :nodes, "")
    |> to_string()
    |> String.split([",", " "], trim: true)
    |> Enum.flat_map(&to_nodes/1)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    backend = Application.get_env(:opdoc, :mdns, Doc.Mdns.Static)
    :ok = backend.announce(node())
    send(self(), :tick)
    scan? = Application.get_env(:opdoc, :scan, false)
    if scan?, do: send(self(), :scan)

    {:ok,
     %{
       scan?: scan?,
       scan_interval: Application.get_env(:opdoc, :scan_interval, 10_000),
       scan_task: nil,
       backend: backend,
       interval: Application.get_env(:opdoc, :discovery_interval, 5_000),
       wait: Application.get_env(:opdoc, :mdns_wait, 1_500),
       backoff: %{},
       waiting: []
     }}
  end

  @impl true
  def handle_call(:now, from, s) do
    send(self(), :tick)
    {:noreply, %{s | waiting: [from | s.waiting]}}
  end

  @impl true
  def handle_info(:tick, s) do
    s.backend.query()
    Process.send_after(self(), :collect, s.wait)
    {:noreply, s}
  end

  def handle_info(:collect, s) do
    now = System.monotonic_time(:millisecond)

    candidates =
      (Enum.map(s.backend.collect(), &String.to_atom/1) ++ explicit_nodes())
      |> Enum.uniq()
      |> Enum.reject(&(&1 == node() or &1 in Node.list()))
      |> Enum.reject(&((until = s.backoff[&1]) && until > now))

    {ok, failed} = Enum.split_with(candidates, &Node.connect/1)
    for n <- ok, do: Logger.info("[opdoc] connected to #{n}")
    for n <- failed, do: Logger.debug(fn -> "[opdoc] cannot reach #{n}" end)
    backoff = Map.merge(Map.drop(s.backoff, ok), Map.new(failed, &{&1, now + 60_000}))

    for w <- s.waiting, do: GenServer.reply(w, Node.list())
    Process.send_after(self(), :tick, s.interval)
    {:noreply, %{s | backoff: backoff, waiting: []}}
  end

  def handle_info(:scan, s) do
    Process.send_after(self(), :scan, s.scan_interval)

    if s.scan_task do
      {:noreply, s}
    else
      {:noreply, %{s | scan_task: Task.async(fn -> scan(subnet_hosts()) end)}}
    end
  end

  def handle_info({ref, found}, %{scan_task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    for n <- found, do: Logger.info("[opdoc] subnet scan: connected to #{n}")
    {:noreply, %{s | scan_task: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, s), do: s.backend.withdraw()

  # every host of the subnet: ask its epmd for names, connect to the new ones
  defp scan(ips) do
    ips
    |> Task.async_stream(
      fn ip ->
        for n <- nodes_at(ip), n != node(), n not in Node.list(), Node.connect(n) == true, do: n
      end,
      max_concurrency: 64,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, found} -> found
      _ -> []
    end)
  end

  @doc "Every other host address of this node's subnet (capped to the /24 around it)."
  def subnet_hosts do
    ip = Doc.Net.ip()

    mask =
      with {:ok, ifs} <- :inet.getifaddrs(),
           m when m != nil <-
             Enum.find_value(ifs, fn {_, opts} ->
               if {:addr, ip} in opts, do: Keyword.get(opts, :netmask)
             end) do
        m
      else
        _ -> {255, 255, 255, 0}
      end

    hosts(ip, mask)
  end

  @doc false
  def hosts(ip, mask) do
    bits = mask |> Tuple.to_list() |> Enum.map(&popcount/1) |> Enum.sum() |> max(24)
    host_bits = 32 - bits

    base =
      Bitwise.band(
        to_int(ip),
        Bitwise.bsl(0xFFFFFFFF >>> host_bits, host_bits) |> Bitwise.band(0xFFFFFFFF)
      )

    last = Bitwise.bsl(1, host_bits) - 2

    if last < 1,
      do: [],
      else: for(i <- 1..last, (a = from_int(base + i)) != ip, do: a)
  end

  defp popcount(b), do: for(<<(bit::1 <- <<b>>)>>, reduce: 0, do: (acc -> acc + bit))
  defp to_int({a, b, c, d}), do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
  defp from_int(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
end
