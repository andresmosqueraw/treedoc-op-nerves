defmodule Doc.FugueTest do
  @moduledoc """
  Plan §2.2: Treedoc with a disambiguator on every step and our insertion rule
  builds the SAME tree as Fugue (Weidner & Kleppmann 2023, Algorithm 1), so it
  inherits Fugue's non-interleaving. Evidence on the REAL `Doc.Treedoc` and
  `Doc.Causal`, typing one char per operation (a paste is balanced on purpose
  and is out of this equivalence):

    * D4 (Kleppmann 2019, Fig. 2) and D4b (Fugue, Fig. 2), letter by letter;
    * forward and backward non-interleaving (Fugue A.1) in EVERY delivery order;
    * property: random traces, 3 replicas, messages delivered out of order
      through `Doc.Causal`; every replica's text equals Fugue's.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Doc.{Treedoc, Causal}

  # ---- minimal Fugue reference (Algorithm 1): node id => {parent, side, ch | :tomb}
  defmodule Fugue do
    def kids(s, id, side), do: for({c, {^id, ^side, _}} <- s, do: c) |> Enum.sort()

    def walk(s, id),
      do:
        Enum.flat_map(kids(s, id, :l), &walk(s, &1)) ++
          if(id == :root, do: [], else: [id]) ++ Enum.flat_map(kids(s, id, :r), &walk(s, &1))

    def text(s), do: for(id <- walk(s, :root), (v = elem(s[id], 2)) != :tomb, into: "", do: v)
    def visible(s), do: for(id <- walk(s, :root), elem(s[id], 2) != :tomb, do: id)

    # insert at visible index i: right child of the left neighbour if it has
    # none, else left child of the next node in the full order
    def insert(s, i, _id) do
      l = if i == 0, do: :root, else: Enum.at(visible(s), i - 1)

      if kids(s, l, :r) == [] do
        {l, :r}
      else
        order = walk(s, :root)

        r =
          if l == :root,
            do: hd(order),
            else: Enum.at(order, Enum.find_index(order, &(&1 == l)) + 1)

        {r, :l}
      end
    end
  end

  # ---- replicas running both CRDTs side by side --------------------------------
  defp replica, do: %{td: Treedoc.new(), fg: %{}, vc: %{}, buf: []}

  # local op on replica `me`: one char insert or one delete; returns {rep, msg}
  defp local(r, me, {:ins, i, ch}) do
    {seq, vc} = Causal.next_local(r.vc, me)
    {:ok, eff} = Treedoc.prepare(r.td, {:insert, i, ch}, {seq, me})
    {par, side} = Fugue.insert(r.fg, i, {seq, me})
    msg = %{from: me, vc: vc, op: {:ins, eff, {seq, me}, par, side, ch}}
    {apply_op(%{r | vc: vc}, msg.op), msg}
  end

  defp local(r, me, {:del, i}) do
    {seq, vc} = Causal.next_local(r.vc, me)
    {:ok, eff} = Treedoc.prepare(r.td, {:delete, i}, {seq, me})
    msg = %{from: me, vc: vc, op: {:del, eff, Enum.at(Fugue.visible(r.fg), i)}}
    {apply_op(%{r | vc: vc}, msg.op), msg}
  end

  defp apply_op(r, {:ins, eff, id, par, side, ch}),
    do: %{r | td: Treedoc.effect(r.td, eff), fg: Map.put(r.fg, id, {par, side, ch})}

  defp apply_op(r, {:del, eff, id}),
    do: %{r | td: Treedoc.effect(r.td, eff), fg: Map.update!(r.fg, id, &put_elem(&1, 2, :tomb))}

  defp receive_msg(r, msg) do
    {vc, buf, events} = Causal.receive_msg(r.vc, r.buf, msg)

    Enum.reduce(
      for({:applied, m} <- events, do: m),
      %{r | vc: vc, buf: buf},
      &apply_op(&2, &1.op)
    )
  end

  defp texts(r), do: {Treedoc.value(r.td), Fugue.text(r.fg)}

  # run `edits` (per node, in order) concurrently: each node applies its own,
  # then receives the other's messages in the given order
  defp concurrent(prefix_msgs, scripts) do
    base = Enum.reduce(prefix_msgs, replica(), &receive_msg(&2, &1))

    for {me, edits} <- scripts, into: %{} do
      {msgs, r} = Enum.map_reduce(edits, base, fn e, r -> local(r, me, e) |> swap() end)
      {me, {r, msgs}}
    end
  end

  defp swap({a, b}), do: {b, a}

  defp type(r, me, i, text) do
    text
    |> String.graphemes()
    |> Enum.with_index(i)
    |> Enum.map_reduce(r, fn {ch, k}, r -> local(r, me, {:ins, k, ch}) |> swap() end)
    |> swap()
  end

  # every interleaving of two lists keeping each one's order
  defp merges([], b), do: [b]
  defp merges(a, []), do: [a]

  defp merges([x | a] = l, [y | b] = m),
    do: for(t <- merges(a, m), do: [x | t]) ++ for(t <- merges(l, b), do: [y | t])

  test "D4: \"Hello!\" then \" Alice\" and \" Charlie\" typed concurrently before \"!\"" do
    {base, m0} = type(replica(), :a, 0, "Hello!")
    {ra, ma} = type(base, :a, 5, " Alice")
    {rb, mb} = type(Enum.reduce(m0, replica(), &receive_msg(&2, &1)), :b, 5, " Charlie")

    ok = ["Hello Alice Charlie!", "Hello Charlie Alice!"]
    # each side receives the other's ops, in order and in reverse (buffered)
    for {r, msgs} <- [{ra, mb}, {rb, ma}],
        order <- [msgs, Enum.reverse(msgs), Enum.shuffle(msgs)] do
      {td, fg} = texts(Enum.reduce(order, r, &receive_msg(&2, &1)))
      assert td == fg
      assert td in ok, "interleaved: #{td}"
    end

    # and both sides end equal
    a = Enum.reduce(mb, ra, &receive_msg(&2, &1))
    b = Enum.reduce(ma, rb, &receive_msg(&2, &1))
    assert texts(a) == texts(b)
  end

  test "D4b: two offline nodes PREPEND their items, then a header (backward typing)" do
    # A types c, b, a always at index 0; B types Z, Y, X at index 0
    {ra, ma} =
      Enum.map_reduce(~w(c b a), replica(), fn ch, r -> local(r, :a, {:ins, 0, ch}) |> swap() end)
      |> swap()

    {rb, mb} =
      Enum.map_reduce(~w(Z Y X), replica(), fn ch, r -> local(r, :b, {:ins, 0, ch}) |> swap() end)
      |> swap()

    a = Enum.reduce(mb, ra, &receive_msg(&2, &1))
    b = Enum.reduce(Enum.reverse(ma), rb, &receive_msg(&2, &1))
    assert texts(a) == texts(b)
    {td, fg} = texts(a)
    assert td == fg
    assert td in ["abcXYZ", "XYZabc"]

    {a, mh} = type(a, :a, 0, "Lista: ")
    b = Enum.reduce(mh, b, &receive_msg(&2, &1))
    assert texts(a) == texts(b)
    assert elem(texts(b), 0) =~ ~r/\ALista: (abcXYZ|XYZabc)\z/
  end

  test "Fugue A.1: no forward or backward interleaving, in every causal delivery order" do
    for {name, a_edits} <- [
          forward: [{:ins, 0, "a"}, {:ins, 1, "b"}],
          backward: [{:ins, 0, "b"}, {:ins, 0, "a"}]
        ] do
      %{a: {_, ma}, b: {_, mb}} = concurrent([], a: a_edits, b: [{:ins, 0, "x"}])

      # a third replica receives the three ops in every interleaving
      for order <- merges(ma, mb) ++ merges(Enum.reverse(ma), mb) do
        {td, fg} = texts(Enum.reduce(order, replica(), &receive_msg(&2, &1)))
        assert td == fg
        assert td in ["abx", "xab"], "#{name}: #{td}"
      end
    end
  end

  property "random traces: every replica converges and equals Fugue (3 replicas, out-of-order delivery)" do
    check all(seed <- integer(1..1_000_000), steps <- integer(10..45), max_runs: 300) do
      :rand.seed(:exsss, {seed, 7, 11})
      nodes = [:n0, :n1, :n2]
      reps = Map.new(nodes, &{&1, %{rep: replica(), inbox: []}})

      reps =
        Enum.reduce(1..steps, reps, fn _, reps ->
          me = Enum.random(nodes)
          %{rep: r, inbox: inbox} = reps[me]

          if inbox != [] and :rand.uniform() < 0.5 do
            # deliver ANY pending message (not necessarily causal: Causal buffers)
            m = Enum.random(inbox)
            Map.put(reps, me, %{rep: receive_msg(r, m), inbox: List.delete(inbox, m)})
          else
            n = String.length(Treedoc.value(r.td))

            edit =
              if n > 0 and :rand.uniform() < 0.25,
                do: {:del, :rand.uniform(n) - 1},
                else: {:ins, :rand.uniform(n + 1) - 1, <<Enum.random(?a..?z)>>}

            {r, msg} = local(r, me, edit)

            reps
            |> Map.put(me, %{reps[me] | rep: r})
            |> Map.new(fn {k, v} ->
              {k, if(k == me, do: v, else: %{v | inbox: v.inbox ++ [msg]})}
            end)
          end
        end)

      # drain everything, in random order
      final =
        for {_, %{rep: r, inbox: inbox}} <- reps,
            do: Enum.reduce(Enum.shuffle(inbox), r, &receive_msg(&2, &1))

      for r <- final do
        assert r.buf == []
        {td, fg} = texts(r)
        assert td == fg
      end

      assert final |> Enum.map(&texts/1) |> Enum.uniq() |> length() == 1
    end
  end
end
