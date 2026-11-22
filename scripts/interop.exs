# Interop check: 3 nodes of the op-based groups' UNCHANGED code (app :crdt) and
# 3 of ours (app :opdoc), 6 nodes, one document. Run by scripts/interop.sh as a
# hidden node; it only drives the nodes through their public APIs (:erpc).
[theirs, ours] = Enum.map(System.argv(), fn s -> s |> String.split(",") |> Enum.map(&String.to_atom/1) end)
all = theirs ++ ours

defmodule I do
  def text(n), do: if(:erpc.call(n, Process, :whereis, [Doc.Supervisor]) != nil, do: :erpc.call(n, Doc, :text, []), else: :erpc.call(n, Crdt, :text, []))
  def insert(n, i, t), do: if(ours?(n), do: :erpc.call(n, Doc, :insert, [i, t]), else: :erpc.call(n, Crdt, :insert, [i, t]))
  def delete(n, i, c), do: if(ours?(n), do: :erpc.call(n, Doc, :delete, [i, c]), else: :erpc.call(n, Crdt, :delete, [i, c]))
  def ours?(n), do: :erpc.call(n, Process, :whereis, [Doc.Supervisor]) != nil

  def converge(nodes, label, timeout \\ 20_000) do
    t0 = System.monotonic_time(:millisecond)
    wait(nodes, t0, timeout, label)
  end

  defp wait(nodes, t0, timeout, label) do
    texts = Enum.map(nodes, &text/1)
    dt = System.monotonic_time(:millisecond) - t0

    cond do
      length(Enum.uniq(texts)) == 1 ->
        IO.puts("  ok  #{label}: #{length(nodes)} nodes equal after #{dt} ms (#{String.length(hd(texts))} chars)")
        hd(texts)

      dt > timeout ->
        IO.puts("  FAIL #{label}: texts differ after #{dt} ms")
        for {n, t} <- Enum.zip(nodes, texts), do: IO.puts("       #{n}: #{inspect(String.slice(t, 0, 80))}")
        System.halt(1)

      true ->
        Process.sleep(50)
        wait(nodes, t0, timeout, label)
    end
  end

  def check(cond, label), do: if(cond, do: IO.puts("  ok  #{label}"), else: (IO.puts("  FAIL #{label}"); System.halt(1)))
end

IO.puts("== I1 mesh: connect everyone (transitive connect_all)")
for n <- tl(all), do: true = :erpc.call(hd(all), Node, :connect, [n])
Process.sleep(1500)
for n <- all, do: I.check(length(:erpc.call(n, Node, :list, [])) >= 5, "#{n} sees the other 5")

IO.puts("== I2 sequential edits alternating implementations")
I.insert(hd(theirs), 0, "Hola")
I.converge(all, "their insert")
I.insert(hd(ours), 4, " mundo")
I.converge(all, "our insert")
I.delete(Enum.at(theirs, 1), 0, 1)
t = I.converge(all, "their delete of our+their chars")
I.check(t == "ola mundo", "text is \"ola mundo\"")
I.delete(Enum.at(ours, 1), 3, 6)
t = I.converge(all, "our delete (6 chars, one call)")
I.check(t == "ola", "text is \"ola\"")

IO.puts("== I3 six concurrent writers at the same index")
words = for {n, k} <- Enum.with_index(all), do: {n, "<#{k}#{String.duplicate(<<?a + k>>, 3)}>"}
words |> Enum.map(fn {n, w} -> Task.async(fn -> I.insert(n, 1, w) end) end) |> Enum.each(&Task.await(&1, 30_000))
t = I.converge(all, "6 concurrent inserts")
for {_, w} <- words, do: I.check(String.contains?(t, w), "word #{w} whole")

IO.puts("== I4 interleaved concurrent edits (200 random ops from all 6)")
:rand.seed(:exsss, {1, 2, 3})
for _ <- 1..200 do
  n = Enum.random(all)
  len = String.length(I.text(n))
  if len > 5 and :rand.uniform() < 0.35, do: I.delete(n, :rand.uniform(len) - 1, 1), else: I.insert(n, :rand.uniform(len + 1) - 1, <<?A + :rand.uniform(25)>>)
end
I.converge(all, "200 random edits")

IO.puts("== I5 our paste (balanced PosIDs) and their char-by-char typing")
I.insert(hd(ours), 0, String.duplicate("pegado-", 60))
I.insert(List.last(theirs), 0, "tecleado ")
I.converge(all, "paste of 420 chars + typing")

IO.puts("== I6 partition {their1, our1} vs the rest, edits on both sides")
[t1 | trest] = theirs
[o1 | orest] = ours
side_a = [t1, o1]
side_b = trest ++ orest
for a <- side_a, b <- side_b, do: :erpc.call(a, Node, :disconnect, [b])
Process.sleep(500)
# OTP >= 25: 'global' (prevent_overlapping_partitions, on by default) also cuts
# links INSIDE each side; discovery is off here, so re-join each side by hand.
for [h | rest] <- [side_a, side_b], n <- rest, do: :erpc.call(h, Node, :connect, [n])
Process.sleep(500)
I.check(Enum.all?(side_a, fn a -> Enum.all?(side_b, &(&1 not in :erpc.call(a, Node, :list, []))) end), "partition in place")
I.insert(t1, 0, "[A-their]")
I.insert(o1, 0, "[A-ours]")
I.insert(hd(trest), 0, "[B-their]")
I.insert(hd(orest), 0, "[B-ours]")
I.converge(side_a, "side A alone")
I.converge(side_b, "side B alone")
:erpc.call(t1, Node, :connect, [hd(orest)])
t = I.converge(all, "after healing (history re-send on nodeup)")
for w <- ~w([A-their] [A-ours] [B-their] [B-ours]), do: I.check(String.contains?(t, w), "#{w} present")

IO.puts("== I7 restart one of ours (state and clock from disk), then edit")
:ok = :erpc.call(hd(ours), Supervisor, :terminate_child, [Doc.Supervisor, Doc.Replica])
{:ok, _} = :erpc.call(hd(ours), Supervisor, :restart_child, [Doc.Supervisor, Doc.Replica])
I.insert(hd(ours), 0, "R")
t = I.converge(all, "edit after restart accepted by their nodes")
I.check(String.starts_with?(t, "R"), "restart edit visible")

IO.puts("== I8 one of theirs disconnected, both keep typing, reconnect")
lone = List.last(theirs)
for n <- all -- [lone], do: :erpc.call(lone, Node, :disconnect, [n])
Process.sleep(300)
I.insert(lone, 0, "solo-")
I.insert(List.last(ours), 0, "grupo-")
:erpc.call(lone, Node, :connect, [List.last(ours)])
# 'global' may have cut other links too (see I6): restore the full mesh
for n <- all, m <- all, n < m, do: :erpc.call(n, Node, :connect, [m])
I.converge(all, "reconnected node caught up")

IO.puts("ALL INTEROP CHECKS PASSED")
