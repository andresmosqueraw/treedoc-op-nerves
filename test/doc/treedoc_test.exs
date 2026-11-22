defmodule Doc.TreedocTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Doc.Treedoc, as: T

  # apply a local edit at `me` with the clock of `vc`; returns {doc, vc, ops}
  defp edit(doc, vc, me, {:insert, i, text}) do
    seq0 = Map.get(vc, me, 0)
    {:ok, atoms} = T.prepare_text(doc, i, String.graphemes(text), seq0, me)

    ops =
      for {{pos, ch}, seq} <- Enum.with_index(atoms, seq0 + 1),
          do: %{op: :ins, pos: pos, ch: ch, from: me, vc: Map.put(vc, me, seq)}

    {Enum.reduce(ops, doc, &T.effect(&2, &1)), Map.put(vc, me, seq0 + length(ops)), ops}
  end

  test "paper scenario (figures 3-4): concurrent W and Y between c and d, then X" do
    {d1, v1, ops1} = edit(T.new(), %{}, :a, {:insert, 0, "abcdef"})
    d2 = Enum.reduce(ops1, T.new(), &T.effect(&2, &1))

    {:ok, w} = T.prepare(d1, {:insert, 3, "W"}, {Map.get(v1, :a) + 1, :a})
    {:ok, y} = T.prepare(d2, {:insert, 3, "Y"}, {1, :b})
    # W has {7, :a}, Y has {1, :b}: Y's disambiguator is smaller
    for d <- [d1, d2] do
      assert T.value(d |> T.effect(w) |> T.effect(y)) == "abcYWdef"
      assert T.value(d |> T.effect(y) |> T.effect(w)) == "abcYWdef"
    end

    d = d1 |> T.effect(w) |> T.effect(y)
    {:ok, x} = T.prepare(d, {:insert, 4, "X"}, {8, :a})
    assert T.value(T.effect(d, x)) == "abcYXWdef"
  end

  test "compare is the in-order walk" do
    a = [{1, 1, :n}]
    assert T.compare([], a) == :lt
    assert T.compare(a ++ [{0, 2, :n}], a) == :lt
    assert T.compare(a ++ [{1, 2, :n}], a) == :gt
    assert T.compare([{0, 5, :z}], [{1, 1, :a}]) == :lt
    assert T.compare([{0, 1, :b}], [{0, 1, :c}]) == :lt
    assert T.compare(a, a) == :eq
  end

  test "a paste builds a balanced subtree (depth log n, text in order)" do
    text = String.duplicate("abcdefghij", 100)
    {d, vc, ops} = edit(T.new(), %{}, :a, {:insert, 0, text})
    assert T.value(d) == text
    assert vc == %{a: 1000}
    # sequence numbers follow the text order
    assert Enum.map(ops, & &1.vc[:a]) == Enum.to_list(1..1000)
    assert T.stats(d).max_depth <= 10
    {d, _, _} = edit(d, vc, :a, {:insert, 500, "XYZ"})
    assert String.slice(T.value(d), 499, 5) == "jXYZa"
  end

  test "delete makes a tombstone, idempotent; prepare_delete is all or nothing" do
    {d, _, _} = edit(T.new(), %{}, :a, {:insert, 0, "hola"})
    {:ok, [p1, p2]} = T.prepare_delete(d, 1, 2)

    d =
      d
      |> T.effect(%{op: :del, pos: p1})
      |> T.effect(%{op: :del, pos: p2})
      |> T.effect(%{op: :del, pos: p1})

    assert T.value(d) == "ha"
    assert T.stats(d).tombstones == 2
    assert T.prepare_delete(d, 1, 2) == {:error, :invalid_index}
    assert T.prepare_delete(d, -1, 1) == {:error, :invalid_index}
    assert T.prepare_text(d, 3, ["x"], 0, :a) == {:error, :invalid_index}
  end

  test "an insert next to tombstones lands where the user typed it" do
    {d, vc, _} = edit(T.new(), %{}, :a, {:insert, 0, "abc"})
    {:ok, [pb]} = T.prepare_delete(d, 1, 1)
    d = T.effect(d, %{op: :del, pos: pb})
    {d, _, _} = edit(d, vc, :a, {:insert, 1, "X"})
    assert T.value(d) == "aXc"
  end

  test "graphemes: one operation per visible letter" do
    {d, vc, ops} = edit(T.new(), %{}, :a, {:insert, 0, "ñé👍🏽"})
    assert length(ops) == 3
    assert vc == %{a: 3}
    assert T.value(d) == "ñé👍🏽"
  end

  test "a child delivered before its parent (balanced paste) still lands in order" do
    {_, _, ops} = edit(T.new(), %{}, :a, {:insert, 0, "abcdefg"})
    d = ops |> Enum.reverse() |> Enum.reduce(T.new(), &T.effect(&2, &1))
    assert T.value(d) == "abcdefg"
  end

  property "concurrent inserts commute: any delivery order gives the same text" do
    check all(
            base <- string(:alphanumeric, min_length: 1, max_length: 8),
            edits <-
              list_of(
                tuple({integer(0..20), string(:alphanumeric, min_length: 1, max_length: 4)}),
                min_length: 2,
                max_length: 5
              ),
            seed <- integer()
          ) do
      {d0, _, base_ops} = edit(T.new(), %{}, :origin, {:insert, 0, base})
      len = String.length(base)

      # every node edits the same base concurrently
      concurrent =
        edits
        |> Enum.with_index()
        |> Enum.flat_map(fn {{i, text}, k} ->
          {_, _, ops} = edit(d0, %{origin: len}, :"n#{k}", {:insert, rem(i, len + 1), text})
          ops
        end)

      :rand.seed(:exsss, {seed, 1, 2})
      shuffled = Enum.shuffle(concurrent)
      a = Enum.reduce(base_ops ++ concurrent, T.new(), &T.effect(&2, &1))
      b = Enum.reduce(base_ops ++ shuffled, T.new(), &T.effect(&2, &1))
      assert T.value(a) == T.value(b)
      # every word arrives whole
      for {_, text} <- edits, do: assert(String.contains?(T.value(a), text))
    end
  end
end
