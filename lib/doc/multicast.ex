defmodule Doc.Multicast do
  @moduledoc """
  Discovery compatible with the op-based groups (their `INTEGRATION.md`, L2),
  written from that description:

    * group `233.252.1.32`, UDP port `45892`, TTL 1, multicast loop on;
    * every 2 s one packet `"crdt-treedoc-1 " <> full node name`, no newline,
      sent on the interface of the IPv4 in our node name;
    * a packet with that tag and a name that is not ours and not connected →
      `Node.connect/1`; anything else is ignored;
    * only one socket per computer can listen on the port: if it is taken (a
      second node on the same machine) this node only announces.

  Hardening (OUR): the name is checked with a strict pattern BEFORE it becomes
  an atom (atoms are never garbage collected), at most `@max_seen` distinct
  names are kept, and a name that cannot be reached is retried after 30 s.
  """
  use GenServer
  require Logger

  @group {233, 252, 1, 32}
  @port 45_892
  @tag "crdt-treedoc-1 "
  @every 2_000
  @retry 30_000
  @max_seen 256
  @name_re ~r/\A[A-Za-z0-9_\-.]{1,64}@\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @doc "Packet announcing `node`."
  def packet(node), do: @tag <> Atom.to_string(node)

  @doc "Node name in a packet, `{:ok, atom}` or `:ignore`. Pure (no atom for invalid input)."
  def parse(<<@tag, name::binary>>) do
    if Regex.match?(@name_re, name), do: {:ok, String.to_atom(name)}, else: :ignore
  end

  def parse(_), do: :ignore

  @impl true
  def init(_) do
    ip = Doc.Net.ip()

    base = [
      :binary,
      active: true,
      reuseaddr: true,
      multicast_ttl: 1,
      multicast_loop: true,
      multicast_if: ip
    ]

    {sock, listening?} =
      case :gen_udp.open(@port, base ++ [add_membership: {@group, ip}]) do
        {:ok, s} ->
          {s, true}

        {:error, reason} ->
          Logger.info("[opdoc] multicast port #{@port} busy (#{inspect(reason)}): announce only")
          {:ok, s} = :gen_udp.open(0, base)
          {s, false}
      end

    send(self(), :announce)
    {:ok, %{sock: sock, listening?: listening?, failed: %{}}}
  end

  @impl true
  def handle_info(:announce, s) do
    _ = :gen_udp.send(s.sock, @group, @port, packet(node()))
    Process.send_after(self(), :announce, @every)
    {:noreply, s}
  end

  def handle_info({:udp, _sock, _ip, _port, data}, s) do
    now = System.monotonic_time(:millisecond)

    with {:ok, n} <- parse(data),
         true <- n != node() and n not in Node.list(),
         true <- (s.failed[n] || 0) <= now do
      if Node.connect(n) == true do
        Logger.info("[opdoc] multicast: connected to #{n}")
        {:noreply, %{s | failed: Map.delete(s.failed, n)}}
      else
        failed = if map_size(s.failed) >= @max_seen, do: %{}, else: s.failed
        {:noreply, %{s | failed: Map.put(failed, n, now + @retry)}}
      end
    else
      _ -> {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}
end
