# Driver of scripts/interop_all.sh (hidden node). Only public APIs and the
# contract messages are used; no implementation is modified.
nodes = System.argv() |> hd() |> String.split(",") |> Enum.map(&String.to_atom/1)

defmodule A do
  # ---- per-implementation adapters -----------------------------------------
  def kind(n) do
    cond do
      loaded?(n, Doc) -> :ours
      loaded?(n, CpdDoc) -> :carla
      String.starts_with?(Atom.to_string(n), "nerves") -> :nerves
      true -> :treedoc
    end
  end

  defp loaded?(n, m), do: :erpc.call(n, Code, :ensure_loaded?, [m])

  def insert(n, i, t) do
    case kind(n) do
      :ours -> :erpc.call(n, Doc, :insert, [i, t])
      :carla -> :erpc.call(n, CpdDoc, :insertar, [i, t])
      _ -> :erpc.call(n, Crdt, :insert, [i, t])
    end
  end

  def delete(n, i, c) do
    case kind(n) do
      :ours -> :erpc.call(n, Doc, :delete, [i, c])
      :carla -> :erpc.call(n, CpdDoc, :borrar, [i, c])
      _ -> :erpc.call(n, Crdt, :delete, [i, c])
    end
  end

  def text(n) do
    case kind(n) do
      :ours -> :erpc.call(n, Doc, :text, [])
      :carla -> :erpc.call(n, CpdDoc, :texto, [])
      _ -> :erpc.call(n, Crdt, :text, [])
    end
  catch
    _, e -> {:error, e}
  end

  def replica(n), do: :erpc.call(n, Process, :whereis, [Crdt.Replica])

  # ---- topology --------------------------------------------------------------
  def mesh(ns), do: for(a <- ns, b <- ns, a < b, do: :erpc.call(a, Node, :connect, [b]))
  def cut(as, bs), do: for(a <- as, b <- bs, a != b, do: :erpc.call(a, :erlang, :disconnect_node, [b]))
  def peers(n), do: :erpc.call(n, Node, :list, [])

  # wait until no replica has messages queued (history re-sends finished):
  # a cast to a node that was just disconnected makes Erlang reconnect it
  def quiet(ns, tries \\ 200) do
    busy =
      Enum.any?(ns, fn n ->
        case replica(n) do
          nil -> false
          pid -> match?({:message_queue_len, q} when q > 0, :erpc.call(n, Process, :info, [pid, :message_queue_len]))
        end
      end)

    if busy and tries > 0, do: (Process.sleep(100); quiet(ns, tries - 1)), else: :ok
  end

  # isolate every node from every other one, for real
  def isolate(ns, tries \\ 20) do
    quiet(ns)
    cut(ns, ns)
    Process.sleep(500)
    if Enum.any?(ns, &(peers(&1) != [])) and tries > 0, do: isolate(ns, tries - 1), else: :ok
  end

  # ---- checks ------------------------------------------------------------------
  def start_results, do: :persistent_term.put(:res, [])
  def record(r), do: :persistent_term.put(:res, :persistent_term.get(:res) ++ [r])

  def ok(c, label) do
    if c, do: IO.puts("  ok    #{label}"), else: IO.puts("  FAIL  #{label}")
    record({c, label})
    c
  end

  def note(label), do: IO.puts("  note  #{label}")

  def converge(ns, label, timeout \\ 30_000), do: wait(ns, label, now(), timeout)

  defp wait(ns, label, t0, timeout) do
    ts = Enum.map(ns, &text/1)
    dt = now() - t0

    cond do
      length(Enum.uniq(ts)) == 1 and is_binary(hd(ts)) ->
        ok(true, "#{label}: #{length(ns)} nodes equal in #{dt} ms (#{String.length(hd(ts))} chars)")
        hd(ts)

      dt > timeout ->
        ok(false, "#{label}: texts differ after #{dt} ms")
        for {n, t} <- Enum.zip(ns, ts), do: IO.puts("          #{short(n)}: #{inspect(t, limit: 8, printable_limit: 70)}")
        nil

      true ->
        Process.sleep(50)
        wait(ns, label, t0, timeout)
    end
  end

  def now, do: System.monotonic_time(:millisecond)
  def short(n), do: n |> Atom.to_string() |> String.split("@") |> hd()
  def title(t), do: IO.puts("\n== #{t}")

  def par(fs), do: fs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 60_000))

  # a contiguous run: every char of `w` once and in one block
  def whole?(t, w), do: t != nil and String.contains?(t, w)
end

A.start_results()
by_kind = Enum.group_by(nodes, &A.kind/1)
IO.puts("nodes: " <> Enum.map_join(nodes, ", ", &"#{A.short(&1)} (#{A.kind(&1)})"))
kinds = [:ours, :treedoc, :nerves, :carla]
first = for k <- kinds, do: hd(by_kind[k])
second = for k <- kinds, do: List.last(by_kind[k])
all = first ++ second

# Carla's multicast discovery reconnects her two nodes by itself, which would
# undo the partitions and the chain below. Stopped at runtime (code unchanged).
for n <- by_kind[:carla], do: :erpc.call(n, Supervisor, :terminate_child, [CpdDoc.Supervisor, CpdDoc.Descubrimiento])

A.title("E1 full mesh of 8 nodes (explicit: -connect_all false)")
A.mesh(all)
Process.sleep(1000)
for n <- all, do: A.ok(length(A.peers(n)) == 7, "#{A.short(n)} sees the other 7")
A.converge(all, "empty document everywhere")

A.title("E2 sequential edits rotating through the 4 implementations")
A.insert(Enum.at(all, 0), 0, "Hola")
A.converge(all, "ours inserts")
A.insert(Enum.at(all, 1), 4, " mundo")
A.converge(all, "treedoc appends")
A.insert(Enum.at(all, 2), 0, "¡")
A.converge(all, "nerves prepends")
A.delete(Enum.at(all, 3), 1, 1)
t = A.converge(all, "carla deletes a char ours wrote")
A.ok(t == "¡ola mundo", "text is exactly \"¡ola mundo\" (got #{inspect(t)})")

A.title("E3 eight writers at the same index at the same time")
words = for {n, k} <- Enum.with_index(all), do: {n, "<#{k}#{A.short(n) |> String.slice(0, 3)}>"}
A.par(for {n, w} <- words, do: fn -> A.insert(n, 1, w) end)
t = A.converge(all, "8 concurrent inserts")
for {n, w} <- words, do: A.ok(A.whole?(t, w), "#{A.kind(n)} word #{w} whole (not interleaved)")

A.title("E4 graphemes: ñ, é as e+U+0301, 👍🏽 and a ZWJ family, one per implementation")
gs = ["ñ", "é", "👍🏽", "👨‍👩‍👧"]
A.par(for {n, g} <- Enum.zip(first, gs), do: fn -> A.insert(n, 0, g) end)
t = A.converge(all, "4 graphemes")
for g <- gs, do: A.ok(t != nil and length(String.split(t, g)) == 2, "#{inspect(g)} present exactly once")
A.ok(t != nil and String.length(t) == String.length("¡ola mundo") + 4 + Enum.sum(for {_, w} <- words, do: String.length(w)), "visible length counts graphemes (no half emoji)")
# each implementation deletes ONE grapheme (the first 4 visible chars, from the end)
for {n, i} <- Enum.zip(first, [3, 2, 1, 0]), do: A.delete(n, i, 1)
t = A.converge(all, "4 grapheme deletes")
for g <- gs, do: A.ok(t != nil and not String.contains?(t, g), "#{inspect(g)} fully deleted")

A.title("E5 the same char deleted by all 8 at once, and insert next to it")
A.insert(hd(all), 0, "XYZ")
A.converge(all, "XYZ")
# truly concurrent: every node isolated (same view), all delete, then re-join
A.isolate(all)
A.par(for n <- all, do: fn -> A.delete(n, 1, 1) end)
A.mesh(all)
t = A.converge(all, "8 concurrent deletes of Y")
A.ok(t != nil and String.starts_with?(t, "XZ"), "Y deleted once, X and Z untouched (#{inspect(String.slice(t || "", 0, 4))})")
A.isolate(all)
A.par([fn -> A.delete(Enum.at(all, 1), 0, 1) end, fn -> A.insert(Enum.at(all, 2), 1, "+") end, fn -> A.insert(Enum.at(all, 3), 0, "-") end])
A.mesh(all)
t = A.converge(all, "concurrent delete X / insert after X / insert before X")
A.ok(t != nil and String.starts_with?(t, "-+Z"), "result starts with \"-+Z\" (#{inspect(String.slice(t || "", 0, 4))})")

A.title("E6 400 random edits, in batches of 8 concurrent ones from all nodes")
:rand.seed(:exsss, {7, 7, 7})
for _ <- 1..50 do
  A.par(
    for n <- all do
      len = case A.text(n) do
        t when is_binary(t) -> String.length(t)
        _ -> 0
      end
      if len > 10 and :rand.uniform() < 0.35,
        do: fn -> A.delete(n, :rand.uniform(len) - 1, 1) end,
        else: fn -> A.insert(n, :rand.uniform(len + 1) - 1, <<?a + :rand.uniform(25)>>) end
    end
  )
end
A.converge(all, "400 random concurrent edits")

A.title("E7 pastes of 300 chars from the 4 implementations at the same spot, concurrently")
pastes = for {n, k} <- Enum.with_index(first), do: {n, String.duplicate(<<?A + k>>, 299) <> "|"}
A.par(for {n, p} <- pastes, do: fn -> A.insert(n, 0, p) end)
t = A.converge(all, "4 concurrent pastes")
for {n, p} <- pastes do
  if A.whole?(t, p), do: A.ok(true, "#{A.kind(n)} paste contiguous"), else: A.note("#{A.kind(n)} paste interleaved with another paste (converges, but not contiguous)")
end

A.title("E8 partition: {ours1, treedoc1, nerves1, carla1} vs the second node of each")
A.quiet(all)
A.cut(first, second)
Process.sleep(500)
A.ok(Enum.all?(first, fn a -> Enum.all?(second, &(&1 not in A.peers(a))) end), "partition in place")
for {n, k} <- Enum.with_index(all), do: A.insert(n, 0, "[#{k}]")
A.delete(Enum.at(first, 2), 40, 3)
A.delete(Enum.at(second, 3), 60, 2)
A.converge(first, "side 1 alone")
A.converge(second, "side 2 alone")
# heal through ONE cross link only: forwarding + history must carry the rest
:erpc.call(Enum.at(first, 3), Node, :connect, [Enum.at(second, 0)])
t = A.converge(all, "healed through a single carla1-ours2 link", 40_000)
for k <- 0..7, do: A.ok(A.whole?(t, "[#{k}]"), "edit [#{k}] made during the partition survives")
A.mesh(all)

A.title("E9 chain topology ours1-treedoc1-nerves1-carla1-ours2-treedoc2-nerves2-carla2 (forwarding)")
A.isolate(all)
chain = all
for [a, b] <- Enum.chunk_every(chain, 2, 1, :discard), do: :erpc.call(a, Node, :connect, [b])
Process.sleep(500)
A.quiet(all)
shape? = Enum.all?(Enum.drop(chain, 1) |> Enum.drop(-1), &(length(A.peers(&1)) == 2)) and length(A.peers(hd(chain))) == 1

unless A.ok(shape?, "chain in place (ends see 1, middle nodes 2)") do
  for n <- chain, do: IO.puts("          #{A.short(n)} -> #{Enum.map_join(A.peers(n), " ", &A.short/1)}")
end
A.par([fn -> A.insert(hd(chain), 0, "<head>") end, fn -> A.insert(List.last(chain), 0, "<tail>") end])
t = A.converge(all, "both ends' edits crossed 7 hops through every implementation")
A.ok(A.whole?(t, "<head>") and A.whole?(t, "<tail>"), "both edits whole")
A.mesh(all)

A.title("E10 crash of each implementation's replica (kill), restart from its disk, then edit")
A.quiet(all)
A.converge(all, "quiescent before the kills")

for n <- first do
  A.quiet(all)
  old = A.replica(n)
  :erpc.call(n, Process, :exit, [old, :kill])
  back = Enum.find_value(1..100, fn _ -> Process.sleep(100); p = A.replica(n); p != nil and p != old and p end)

  if A.ok(back != nil, "#{A.kind(n)} replica restarted by its supervisor") do
    Process.sleep(300)
    {mine, ref} = {A.text(n), A.text(hd(second))}
    A.ok(mine == ref, "#{A.kind(n)} recovered the document from disk (#{String.length(mine || "")} vs #{String.length(ref || "")} chars)")
    A.insert(n, 0, "{#{A.kind(n)}}")
  end
end
t = A.converge(all, "edits after restart (numbering continued, not dropped as duplicates)")
for n <- first, do: A.ok(A.whole?(t, "{#{A.kind(n)}}"), "post-restart edit of #{A.kind(n)} present")

A.title("E11 late joiner: nerves2 isolated, 60 edits elsewhere + 5 of its own, rejoins via ONE node")
lone = Enum.at(second, 2)
A.quiet(all)
A.cut([lone], all)
Process.sleep(300)
for k <- 1..60, do: A.insert(Enum.at(all -- [lone], rem(k, 7)), 0, <<?a + rem(k, 26)>>)
for _ <- 1..5, do: A.insert(lone, 0, "#")
:erpc.call(lone, Node, :connect, [Enum.at(first, 3)])
t = A.converge(all, "late joiner caught up and its offline edits spread", 40_000)
A.ok(t != nil and length(String.split(t, "#")) - 1 >= 5, "its 5 offline edits are there")
A.mesh(all)

A.title("E12 contract messages straight to each implementation: out of order + duplicated")
for {n, k} <- Enum.with_index(first) do
  f = :"fake#{k}@10.9.9.#{k + 1}"
  ops = for {ch, s} <- Enum.with_index(["x", "y", "z"], 1), do: %{op: :ins, from: f, vc: %{f => s}, pos: for(j <- 1..s, do: {1, j, f}), ch: ch}
  [o1, o2, o3] = ops
  for o <- [o3, o2, o3, o1, o2], do: :erpc.call(n, GenServer, :cast, [{Crdt.Replica, n}, {:remote, o}])
end
t = A.converge(all, "fake ops held, applied once, forwarded to all")
A.ok(t != nil and length(String.split(t, "xyz")) - 1 == 4, "\"xyz\" exactly 4 times (one per implementation that received it)")

A.title("E14 connections stay up while idle (net_ticktime equal everywhere), 25 s")
Process.sleep(25_000)
for n <- all, do: A.ok(length(A.peers(n)) == 7, "#{A.short(n)} still sees 7 after 25 s idle")
ticks = all |> Enum.map(&:erpc.call(&1, :net_kernel, :get_net_ticktime, [])) |> Enum.uniq()
A.ok(length(ticks) == 1, "same net_ticktime on all 8 nodes (#{inspect(ticks)})")

A.title("E15 final: one more edit from every node, then the same text everywhere")
A.par(for n <- all, do: fn -> A.insert(n, 0, ".") end)
A.converge(all, "final")

A.title("E13 malformed contract messages to each implementation (must ignore, never crash)")
good = fn tag -> %{op: :ins, from: :"bad#{tag}@10.8.8.8", vc: %{:"bad#{tag}@10.8.8.8" => 1}, pos: [{1, 1, :"bad#{tag}@10.8.8.8"}], ch: "!"} end
junk = [
  {"empty map", {:remote, %{}}},
  {"atom payload", {:remote, :x}},
  {"ins without fields", {:remote, %{op: :ins}}},
  {"vc without its own entry", {:remote, %{good.(1) | vc: %{}}}},
  {"two graphemes in ch", {:remote, %{good.(2) | ch: "ab"}}},
  {"empty ch", {:remote, %{good.(3) | ch: ""}}},
  {"ch not a binary", {:remote, %{good.(4) | ch: 33}}},
  {"invalid UTF-8 ch", {:remote, %{good.(5) | ch: <<255>>}}},
  {"empty pos", {:remote, %{good.(6) | pos: []}}},
  {"bit 2 in pos", {:remote, %{good.(7) | pos: [{2, 1, :z}]}}},
  {"seq 0 in pos", {:remote, %{good.(8) | pos: [{1, 0, :z}]}}},
  {"improper pos list", {:remote, %{good.(9) | pos: [{1, 1, :z} | :tail]}}},
  {"string as from", {:remote, %{good.(10) | from: "x@1.1.1.1"}}},
  {"unknown op", {:remote, %{good.(11) | op: :upd}}},
  {"hello with a string", {:hello, "x"}},
  {"unknown cast", :boom}
]

for n <- first do
  for {label, msg} <- junk do
    pid = A.replica(n)
    :erpc.call(n, GenServer, :cast, [{Crdt.Replica, n}, msg])
    Process.sleep(400)
    now = A.replica(n)

    cond do
      pid == nil ->
        A.ok(false, "#{A.kind(n)} has NO replica left to receive: #{label}")

      now == pid ->
        A.ok(true, "#{A.kind(n)} ignores: #{label}")

      true ->
        A.ok(false, "#{A.kind(n)} replica CRASHED on: #{label}")
        # wait for the restart, then let the supervisor's restart window (3 in 5 s) pass
        Enum.find_value(1..50, fn _ -> Process.sleep(100); A.replica(n) end)
        Process.sleep(5_500)
    end
  end

  try do
    :erpc.call(n, Kernel, :send, [Crdt.Replica, :raw_junk])
  catch
    _, _ -> :no_registered_replica
  end

  Process.sleep(400)
  A.ok(is_binary(A.text(n)), "#{A.kind(n)} replica alive and answering after #{length(junk) + 1} malformed messages")
end

# what each implementation KEPT from the malformed ops (the ch values used: "!", "ab", "", 33)
for n <- all do
  t = A.text(n)
  if is_binary(t), do: IO.puts("          #{A.short(n)}: begins #{inspect(String.slice(t, 0, 12))}")
end
t = A.converge(all, "documents still equal after the malformed messages (nobody kept a bad op)")
A.ok(t != nil and not String.contains?(t, "!"), "no malformed op entered any document")


res = :persistent_term.get(:res)
fails = for {false, l} <- res, do: l
IO.puts("\n#{length(res) - length(fails)} of #{length(res)} checks passed")
if fails == [], do: IO.puts("ALL CHECKS PASSED"), else: (IO.puts("FAILED:"); Enum.each(fails, &IO.puts("  - #{&1}")); System.halt(1))
