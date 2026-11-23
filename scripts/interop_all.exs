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

  # the read APIs besides text (status / history), as each one names them
  def read_extra(n) do
    case kind(n) do
      :ours -> {:erpc.call(n, Doc, :status, []), :erpc.call(n, Doc, :history, [])}
      :carla -> {:erpc.call(n, CpdDoc, :estado, []), :erpc.call(n, CpdDoc, :historial, [])}
      _ -> {:erpc.call(n, Crdt, :status, []), :erpc.call(n, Crdt, :history, [])}
    end
  end

  def safe(f) do
    {:ok, f.()}
  catch
    k, e -> {:raised, k, e |> inspect(limit: 3) |> String.slice(0, 90)}
  end

  # reference model of the visible text (graphemes)
  def m_ins(s, i, w), do: String.slice(s, 0, i) <> w <> String.slice(s, i..-1//1)
  def m_del(s, i, c), do: String.slice(s, 0, i) <> String.slice(s, (i + c)..-1//1)

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


A.title("C1 CREATE from each implementation: empty document, start, middle, end (exact text)")
base = A.text(hd(all))
t0 = A.now()
r = A.safe(fn -> A.delete(Enum.at(all, 5), 0, String.length(base)) end)
emptied = A.converge(all, "treedoc2 deletes the whole document (#{String.length(base)} chars) in one call", 180_000)
dt = A.now() - t0

case r do
  {:ok, _} -> A.note("treedoc deleted #{String.length(base)} chars in one call; everyone empty after #{dt} ms")
  {:raised, _, e} -> A.note("treedoc's own call gave up (#{String.slice(e, 0, 60)}), but the replica kept going: everyone empty after #{dt} ms")
end

A.ok(emptied == "", "document is empty everywhere")
expect = ""

expect =
  Enum.reduce(first, expect, fn n, exp ->
    k = A.kind(n)

    exp =
      Enum.reduce([{:start, "S-#{k} "}, {:end, " E-#{k}"}, {:middle, "[M-#{k}]"}], exp, fn {where, w}, exp ->
        i = %{start: 0, end: String.length(exp), middle: div(String.length(exp), 2)}[where]
        A.insert(n, i, w)
        t = A.converge(all, "#{k} creates at #{where}")
        exp = A.m_ins(exp, i, w)
        A.ok(t == exp, "#{k} create at #{where}: exact text")
        exp
      end)

    exp
  end)

A.title("C2 READ on every node: same text, same length in graphemes, same char at every 7th position, status/history APIs")
ts = Enum.map(all, &A.text/1)
A.ok(Enum.uniq(ts) == [expect], "all 8 read exactly the expected document")
A.ok(ts |> Enum.map(&String.length/1) |> Enum.uniq() == [String.length(expect)], "same length (#{String.length(expect)} graphemes) everywhere")
A.ok(Enum.all?(ts, fn t -> Enum.all?(0..(String.length(expect) - 1)//7, &(String.at(t, &1) == String.at(expect, &1))) end), "same grapheme at every sampled position")
for n <- first do
  case A.safe(fn -> A.read_extra(n) end) do
    {:ok, _} -> A.ok(A.replica(n) != nil, "#{A.kind(n)} status and history read without error")
    other -> A.ok(false, "#{A.kind(n)} status/history raised: #{inspect(other)}")
  end
end

A.title("C3 UPDATE (= delete the range + insert the new text) from each implementation, exact text")
_ =
  Enum.reduce(first, expect, fn n, exp ->
    k = A.kind(n)
    old = "S-#{k} "
    i = :binary.match(exp, old) |> elem(0) |> then(&String.length(binary_part(exp, 0, &1)))
    new = "U-#{k}~ñ "
    A.delete(n, i, String.length(old))
    A.insert(n, i, new)
    t = A.converge(all, "#{k} replaces #{inspect(old)} with #{inspect(new)}")
    exp = exp |> A.m_del(i, String.length(old)) |> A.m_ins(i, new)
    A.ok(t == exp, "#{k} update: exact text")
    exp
  end)

for {a, b} <- [{Enum.at(first, 0), Enum.at(first, 1)}, {Enum.at(first, 2), Enum.at(first, 3)}, {Enum.at(second, 0), Enum.at(second, 3)}] do
  A.insert(a, 0, "gato ")
  A.converge(all, "word to fight over")
  A.isolate(all)
  # both replace the SAME word at the same time, without seeing each other
  A.par([
    fn -> A.delete(a, 0, 5); A.insert(a, 0, "perro ") end,
    fn -> A.delete(b, 0, 5); A.insert(b, 0, "loro ") end
  ])
  A.mesh(all)
  t = A.converge(all, "concurrent update #{A.kind(a)} vs #{A.kind(b)}")
  A.ok(t != nil and not String.contains?(t, "gato") and A.whole?(t, "perro ") and A.whole?(t, "loro "),
    "concurrent update #{A.kind(a)}/#{A.kind(b)}: old word gone once, both new words whole (#{inspect(String.slice(t || "", 0, 12))})")
  t = A.text(hd(all))
  w = String.slice(t, 0, String.length("perro loro "))
  A.delete(a, 0, String.length(w))
  A.converge(all, "cleanup")
end
expect = A.text(hd(all))

A.title("C4 DELETE from each implementation: first, last, a middle range, then everything (exact text)")
_ =
  Enum.reduce(first, expect, fn n, exp ->
    k = A.kind(n)

    Enum.reduce([{"first char", fn e -> {0, 1, e} end}, {"last char", fn e -> {String.length(e) - 1, 1, e} end},
                 {"range of 5 in the middle", fn e -> {div(String.length(e), 2), 5, e} end}], exp, fn {label, f}, exp ->
      {i, c, _} = f.(exp)
      A.delete(n, i, c)
      t = A.converge(all, "#{k} deletes #{label}")
      exp = A.m_del(exp, i, c)
      A.ok(t == exp, "#{k} delete #{label}: exact text")
      exp
    end)
  end)

for n <- first do
  A.insert(n, 0, "temporal-#{A.kind(n)}")
  A.converge(all, "text to wipe")
  len = String.length(A.text(n))
  A.delete(n, 0, len)
  A.ok(A.converge(all, "#{A.kind(n)} deletes everything (#{len} chars) in one call") == "", "#{A.kind(n)} delete all: empty everywhere")
  A.insert(n, 0, "otra vez")
  A.ok(A.converge(all, "#{A.kind(n)} creates on the emptied document") == "otra vez", "#{A.kind(n)} create after delete-all")
  A.delete(n, 0, 8)
  A.converge(all, "empty again")
end
A.insert(Enum.at(first, 3), 0, "Documento final de CRUD")
expect = A.converge(all, "a document for C5")

A.title("C5 invalid CRUD calls on each implementation: must not change any document or crash")
bad_calls = fn len ->
  [
    {"insert past the end", &A.insert(&1, len + 1, "x")},
    {"insert at -1", &A.insert(&1, -1, "x")},
    {"insert at a float index", &A.insert(&1, 1.5, "x")},
    {"insert a non-binary", &A.insert(&1, 0, :x)},
    {"insert invalid UTF-8", &A.insert(&1, 0, <<255>>)},
    {"insert empty text", &A.insert(&1, 0, "")},
    {"delete past the end", &A.delete(&1, len, 1)},
    {"delete at -1", &A.delete(&1, -1, 1)},
    {"delete more than there is", &A.delete(&1, 0, len + 1)},
    {"delete 0 chars", &A.delete(&1, 0, 0)},
    {"delete -1 chars", &A.delete(&1, 0, -1)},
    {"delete at an atom index", &A.delete(&1, :a, 1)}
  ]
end

for n <- first do
  len = String.length(expect)

  for {label, f} <- bad_calls.(len) do
    pid = A.replica(n)
    r = A.safe(fn -> f.(n) end)
    Process.sleep(150)
    shown = case r do {:ok, v} -> "returns #{inspect(v)}"; {:raised, _, e} -> "raises #{e}" end
    same? = A.text(n) == expect

    if A.replica(n) == pid and same?,
      do: A.ok(true, "#{A.kind(n)} #{label}: rejected, nothing changed (#{shown})"),
      else: A.ok(false, "#{A.kind(n)} #{label}: #{if A.replica(n) != pid, do: "REPLICA CRASHED", else: "DOCUMENT CHANGED to #{inspect(A.text(n))}"} (#{shown})")

    if A.replica(n) != pid do
      # wait for the restart and let the supervisor's restart window pass
      Enum.find_value(1..50, fn _ -> Process.sleep(100); A.replica(n) end)
      Process.sleep(5_500)
      A.converge(all, "#{A.kind(n)} back after the crash")
    end
  end
end
t = A.converge(all, "after all invalid calls")
A.ok(t == expect, "no invalid call changed any document")

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
