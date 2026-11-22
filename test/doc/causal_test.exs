defmodule Doc.CausalTest do
  use ExUnit.Case, async: true
  alias Doc.Causal, as: C

  defp m(from, vc), do: %{from: from, vc: vc}

  test "classify: duplicate, deliverable, wait" do
    vc = %{a: 2, b: 1}
    assert C.classify(vc, m(:a, %{a: 2})) == :duplicate
    assert C.classify(vc, m(:a, %{a: 1})) == :duplicate
    assert C.classify(vc, m(:a, %{a: 3, b: 1})) == :deliverable
    # gap from the same sender
    assert C.classify(vc, m(:a, %{a: 4})) == :wait
    # depends on an op of b not applied yet
    assert C.classify(vc, m(:a, %{a: 3, b: 2})) == :wait
    # unknown node starts at 0
    assert C.classify(vc, m(:c, %{c: 1, a: 2})) == :deliverable
  end

  test "next_local has no side effects and numbers 1, 2, 3" do
    assert C.next_local(%{}, :a) == {1, %{a: 1}}
    assert C.next_local(%{a: 4, b: 1}, :a) == {5, %{a: 5, b: 1}}
  end

  test "out of order: waits, then the whole chain is delivered in causal order" do
    a1 = m(:a, %{a: 1})
    a2 = m(:a, %{a: 2})
    b1 = m(:b, %{a: 2, b: 1})

    {vc, buf, ev} = C.receive_msg(%{}, [], b1)
    assert ev == [{:waiting, b1}]
    assert C.missing(vc, b1) == %{a: 2}

    {vc, buf, ev} = C.receive_msg(vc, buf, a2)
    assert ev == [{:waiting, a2}]
    assert C.missing(vc, a2) == %{a: 1}

    # a copy of a waiting op is not buffered twice
    {vc, buf, []} = C.receive_msg(vc, buf, a2)
    assert length(buf) == 2

    {vc, buf, ev} = C.receive_msg(vc, buf, a1)
    assert ev == [{:applied, a1}, {:applied, a2}, {:applied, b1}]
    assert vc == %{a: 2, b: 1}
    assert buf == []

    {^vc, [], [{:duplicate, _}]} = C.receive_msg(vc, buf, a1)
  end

  test "every permutation of a causal history delivers the same sequence of clocks" do
    ops = [
      m(:a, %{a: 1}),
      m(:b, %{a: 1, b: 1}),
      m(:a, %{a: 2, b: 1}),
      m(:c, %{c: 1}),
      m(:c, %{c: 2, a: 2})
    ]

    for perm <- perms(ops) do
      {vc, buf, applied} =
        Enum.reduce(perm, {%{}, [], []}, fn msg, {vc, buf, acc} ->
          {vc, buf, ev} = C.receive_msg(vc, buf, msg)
          {vc, buf, acc ++ for({:applied, x} <- ev, do: x)}
        end)

      assert vc == %{a: 2, b: 1, c: 2}
      assert buf == []
      assert length(applied) == 5
      # causal: each applied op's dependencies were applied before it
      Enum.reduce(applied, %{}, fn x, seen ->
        assert C.classify(seen, x) == :deliverable
        C.deliver(seen, x)
      end)
    end
  end

  defp perms([]), do: [[]]
  defp perms(l), do: for(x <- l, rest <- perms(l -- [x]), do: [x | rest])
end
