defmodule Doc.Replica do
  @moduledoc """
  The replica: one GenServer, registered as `Crdt.Replica` (the contract,
  `Doc.Wire`), that OWNS the document, the vector clock, the causal buffer and
  the history (actor model, course deck 8).

  How the concurrency problems of the first part of the course are handled:

    * **Race conditions**: no shared memory, no locks; local edits and remote
      operations are serialized by this process's mailbox.
    * **Atomicity of a local edit**: one `handle_call` validates, numbers every
      char with the clock, applies, writes the log with ONE fsync and only then
      broadcasts. If the disk fails nothing is applied or sent.
    * **Causality** (Lamport 78, CBCAST): `Doc.Causal` applies an operation only
      after everything its clock says it depends on; otherwise it waits.
    * **Duplicates**: dropped by the clock (`m[from] <= vc[from]`).
    * **Losses / a sender that dies mid-broadcast**: every applied operation is
      forwarded once (reliable broadcast, Birman 91), and the whole history is
      re-sent on every `nodeup` and on `{:hello, node}`.
    * **Deadlock**: between nodes there are only asynchronous casts.
    * **Malformed input from other nodes**: `Doc.Wire.parse/1` ignores it.
  """
  use GenServer
  require Logger

  alias Doc.{Treedoc, Causal, Storage, Bcast, Wire}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: Wire.name())

  # ---- client API ------------------------------------------------------------
  def insert(index, text), do: GenServer.call(Wire.name(), {:local, {:insert, index, text}})

  def delete(index, count \\ 1),
    do: GenServer.call(Wire.name(), {:local, {:delete, index, count}})

  def replace(index, count, text),
    do: GenServer.call(Wire.name(), {:local, {:replace, index, count, text}})

  def append(text), do: GenServer.call(Wire.name(), {:local, {:append, text}})
  def read(index, count), do: GenServer.call(Wire.name(), {:read, index, count})
  def text, do: GenServer.call(Wire.name(), :text)
  def status, do: GenServer.call(Wire.name(), :status)
  def debug, do: GenServer.call(Wire.name(), :debug)
  def history, do: GenServer.call(Wire.name(), :history)
  def subscribe(pid \\ self()), do: GenServer.call(Wire.name(), {:subscribe, pid})

  @doc "Ask every connected node to re-send its whole history (`{:hello, node()}`)."
  def hello, do: GenServer.cast(Wire.name(), :say_hello)

  # waiting operations kept at most (a node that never sends the missing ones
  # must not exhaust the memory); the oldest are dropped, a history re-send
  # brings them back
  @max_buffer 50_000

  # ---- server ----------------------------------------------------------------
  @impl true
  def init(_arg) do
    :ok = :net_kernel.monitor_nodes(true)

    # open first: it truncates a line cut by a power failure
    fd = Storage.open()
    {ops, fd, blocked?} = load(fd)

    # replay the log: effect and vc[from] := m[from], no causal checks (the log
    # is in applied order), no forwarding
    {doc, vc, hist} =
      Enum.reduce(ops, {Treedoc.new(), %{}, []}, fn %{from: f, vc: m} = op, {d, vc, h} ->
        {Treedoc.effect(d, op), Map.update(vc, f, m[f], &max(&1, m[f])), [op | h]}
      end)

    if hist != [],
      do: Logger.info("[opdoc] recovered #{length(hist)} operations from #{Storage.path()}")

    s = %{
      doc: doc,
      vc: vc,
      buffer: [],
      # history in REVERSE applied order (cheap append); sent in applied order
      hist: hist,
      hist_len: length(hist),
      me: if(Node.alive?(), do: node()),
      fd: fd,
      # true when the log was damaged while the distribution (our name) was
      # already up: local edits would reuse sequence numbers until a restart
      blocked: blocked?,
      subs: MapSet.new(),
      applied: 0,
      duplicates: 0,
      ignored: 0,
      heard_from: %{}
    }

    if Node.list() != [] do
      send_history(s)
      Bcast.broadcast({:hello, node()})
    end

    {:ok, s}
  end

  # A line in the MIDDLE of the log cannot be decoded (a damaged SD card; a cut
  # last line was already truncated by `Storage.open/0`). Keep the valid prefix,
  # move the damaged file aside and forget the epoch: the node gets a NEW name
  # (`Doc.Dist`), so its future operations never reuse a number that the lost
  # lines may have used; the others re-send everything else on nodeup/hello.
  # If the distribution is already up (the replica restarted on its own) the
  # name cannot change now: local edits are refused until the node restarts.
  defp load(fd) do
    case Storage.load() do
      {:ok, ops} ->
        {ops, fd, false}

      {:corrupt, prefix, line} ->
        Logger.error(
          "[opdoc] log line #{line} is damaged: keeping #{length(prefix)} operations, new epoch"
        )

        :ok = File.close(fd)
        fd = Storage.replace(prefix)
        _ = File.rm(Storage.epoch_path())
        blocked? = Node.alive?()

        if blocked?,
          do: Logger.error("[opdoc] restart this node to edit again (it needs a new name)")

        {prefix, fd, blocked?}
    end
  end

  # ---- local edits -----------------------------------------------------------
  @impl true
  def handle_call({:local, _}, _from, %{blocked: true} = s),
    do: {:reply, {:error, :restart_required}, s}

  def handle_call({:local, {:insert, index, text}}, _from, s)
      when is_integer(index) and is_binary(text) do
    with true <- String.valid?(text) || {:error, :invalid_utf8},
         {:ok, me, s} <- author(s),
         seq0 = Map.get(s.vc, me, 0),
         {:ok, atoms} <- Treedoc.prepare_text(s.doc, index, String.graphemes(text), seq0, me) do
      ops =
        atoms
        |> Enum.with_index(seq0 + 1)
        |> Enum.map(fn {{pos, ch}, seq} ->
          %{op: :ins, from: me, vc: Map.put(s.vc, me, seq), pos: pos, ch: ch}
        end)

      local_ops(ops, s)
    else
      {:error, _} = e -> {:reply, e, s}
    end
  end

  def handle_call({:local, {:delete, index, count}}, _from, s)
      when is_integer(index) and is_integer(count) do
    with {:ok, positions} <- Treedoc.prepare_delete(s.doc, index, count),
         {:ok, me, s} <- if(positions == [], do: {:ok, nil, s}, else: author(s)) do
      seq0 = Map.get(s.vc, me, 0)

      ops =
        positions
        |> Enum.with_index(seq0 + 1)
        |> Enum.map(fn {pos, seq} ->
          %{op: :del, from: me, vc: Map.put(s.vc, me, seq), pos: pos}
        end)

      local_ops(ops, s)
    else
      {:error, _} = e -> {:reply, e, s}
    end
  end

  # Update: delete `count` from `index` and insert `text` there, in ONE call. Both
  # are prepared against the same state (the insert on the document with the
  # deletes applied), so no remote op can slip in between and shift the index.
  def handle_call({:local, {:replace, index, count, text}}, _from, s)
      when is_integer(index) and is_integer(count) and is_binary(text) do
    with true <- String.valid?(text) || {:error, :invalid_utf8},
         {:ok, positions} <- Treedoc.prepare_delete(s.doc, index, count),
         {:ok, me, s} <- author(s),
         seq0 = Map.get(s.vc, me, 0),
         dels =
           positions
           |> Enum.with_index(seq0 + 1)
           |> Enum.map(fn {pos, seq} ->
             %{op: :del, from: me, vc: Map.put(s.vc, me, seq), pos: pos}
           end),
         seq1 = seq0 + length(dels),
         tmp = Enum.reduce(dels, s.doc, &Treedoc.effect(&2, &1)),
         {:ok, atoms} <- Treedoc.prepare_text(tmp, index, String.graphemes(text), seq1, me) do
      ins =
        atoms
        |> Enum.with_index(seq1 + 1)
        |> Enum.map(fn {{pos, ch}, seq} ->
          %{op: :ins, from: me, vc: Map.put(s.vc, me, seq), pos: pos, ch: ch}
        end)

      local_ops(dels ++ ins, s)
    else
      {:error, _} = e -> {:reply, e, s}
    end
  end

  # Create at the end of the document as it is right now
  def handle_call({:local, {:append, text}}, from, s) when is_binary(text),
    do: handle_call({:local, {:insert, length(Treedoc.visible(s.doc)), text}}, from, s)

  def handle_call({:local, _}, _from, s), do: {:reply, {:error, :badarg}, s}

  # Read `count` visible atoms from `index`: same indices as insert/delete
  def handle_call({:read, index, count}, _from, s)
      when is_integer(index) and is_integer(count) and index >= 0 and count >= 0 do
    vis = Treedoc.visible(s.doc)

    if index + count <= length(vis),
      do: {:reply, vis |> Enum.slice(index, count) |> Enum.map_join(&elem(&1, 1)), s},
      else: {:reply, {:error, :invalid_index}, s}
  end

  def handle_call({:read, _, _}, _from, s), do: {:reply, {:error, :invalid_index}, s}

  def handle_call(:text, _from, s), do: {:reply, Treedoc.value(s.doc), s}
  def handle_call(:debug, _from, s), do: {:reply, Treedoc.entries(s.doc), s}
  def handle_call(:history, _from, s), do: {:reply, Enum.reverse(s.hist), s}

  def handle_call(:status, _from, s) do
    {:reply,
     %{
       node: node(),
       author: s.me,
       blocked: s.blocked,
       vc: s.vc,
       history: s.hist_len,
       waiting: for(m <- s.buffer, do: {m.from, m.vc[m.from], Causal.missing(s.vc, m)}),
       peers: Node.list(),
       heard_from: s.heard_from,
       ops_applied_remote: s.applied,
       ops_duplicate: s.duplicates,
       msgs_ignored: s.ignored,
       tree: Treedoc.stats(s.doc),
       text: Treedoc.value(s.doc)
     }, s}
  end

  def handle_call({:subscribe, pid}, _from, s) do
    Process.monitor(pid)
    {:reply, :ok, %{s | subs: MapSet.put(s.subs, pid)}}
  end

  def handle_call(_unknown, _from, s), do: {:reply, {:error, :unknown_call}, s}

  # The node name that authors local operations. It is `node()` while the
  # distribution is up; if the network drops, the last name is kept (it is still
  # ours and its clock entry continues). Never `nonode@nohost`: every Pi would
  # share that name and their sequence numbers would collide.
  defp author(s) do
    cond do
      Node.alive?() -> {:ok, node(), %{s | me: node()}}
      s.me != nil -> {:ok, s.me, s}
      true -> {:error, :no_network}
    end
  end

  # All the operations of one call: log (one fsync) → apply → history → send.
  defp local_ops([], s), do: {:reply, :ok, s}

  defp local_ops(ops, s) do
    case Storage.append(s.fd, ops) do
      :ok ->
        last = List.last(ops)
        doc = Enum.reduce(ops, s.doc, &Treedoc.effect(&2, &1))
        s = %{s | doc: doc, vc: Map.put(s.vc, last.from, last.vc[last.from])} |> add_history(ops)
        for op <- ops, do: Bcast.broadcast({:remote, op})
        {:reply, :ok, notify(s)}

      {:error, reason} ->
        # nothing applied, nothing sent: the clock does not advance
        {:reply, {:error, {:disk, reason}}, s}
    end
  end

  # ---- network ---------------------------------------------------------------
  @impl true
  def handle_cast({:remote, raw}, s) do
    case Wire.parse(raw) do
      {:ok, msg} -> {:noreply, remote(msg, s)}
      :ignore -> {:noreply, ignore(raw, s)}
    end
  end

  def handle_cast({:hello, n}, s) when is_atom(n) do
    Logger.info("[opdoc] hello from #{n}: re-sending history (#{s.hist_len} ops)")
    send_history(s)
    {:noreply, s}
  end

  def handle_cast(:say_hello, s) do
    if Node.alive?(), do: Bcast.broadcast({:hello, node()})
    {:noreply, s}
  end

  def handle_cast(other, s), do: {:noreply, ignore(other, s)}

  @impl true
  def handle_info({:nodeup, n}, s) do
    Logger.info("[opdoc] nodeup #{n}: re-sending history (#{s.hist_len} ops)")
    send_history(s)
    {:noreply, %{s | me: if(Node.alive?(), do: node(), else: s.me)}}
  end

  def handle_info({:nodedown, n}, s) do
    Logger.warning("[opdoc] nodedown #{n}")
    {:noreply, s}
  end

  def handle_info({:DOWN, _, :process, pid, _}, s),
    do: {:noreply, %{s | subs: MapSet.delete(s.subs, pid)}}

  def handle_info(other, s), do: {:noreply, ignore(other, s)}

  defp remote(msg, s) do
    {vc, buffer, events} = Causal.receive_msg(s.vc, s.buffer, msg)
    applied = for {:applied, m} <- events, do: m
    dups = Enum.count(events, &match?({:duplicate, _}, &1))

    for {:waiting, m} <- events do
      Logger.debug(fn ->
        "[opdoc] waiting op #{m.vc[m.from]} from #{m.from} (missing #{inspect(Causal.missing(vc, m))})"
      end)
    end

    buffer =
      if length(buffer) > @max_buffer,
        do: Enum.drop(buffer, length(buffer) - @max_buffer),
        else: buffer

    s = %{
      s
      | vc: vc,
        buffer: buffer,
        duplicates: s.duplicates + dups,
        heard_from: Map.update(s.heard_from, msg.from, 1, &(&1 + 1))
    }

    if applied == [] do
      s
    else
      # on disk before forwarding; a disk error does not stop a REMOTE op (it
      # is already in the others' histories and comes back on the next re-send)
      _ = Storage.append(s.fd, applied)
      doc = Enum.reduce(applied, s.doc, &Treedoc.effect(&2, &1))
      # reliable broadcast: forward every applied operation once, unchanged
      for m <- applied, do: Bcast.broadcast({:remote, m})
      %{s | doc: doc, applied: s.applied + length(applied)} |> add_history(applied) |> notify()
    end
  end

  defp ignore(msg, s) do
    Logger.debug(fn -> "[opdoc] ignoring: #{inspect(msg, limit: 5)}" end)
    %{s | ignored: s.ignored + 1}
  end

  defp add_history(s, ops),
    do: %{s | hist: Enum.reverse(ops, s.hist), hist_len: s.hist_len + length(ops)}

  defp send_history(s) do
    for op <- Enum.reverse(s.hist), do: Bcast.broadcast({:remote, op})
    :ok
  end

  defp notify(s) do
    if MapSet.size(s.subs) > 0 do
      text = Treedoc.value(s.doc)
      for pid <- s.subs, do: send(pid, {:opdoc_changed, text})
    end

    s
  end
end
