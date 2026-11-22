defmodule Doc.WireTest do
  use ExUnit.Case, async: true
  alias Doc.{Wire, Multicast}

  @ins %{
    op: :ins,
    from: :"a@1.2.3.4",
    vc: %{:"a@1.2.3.4" => 1},
    pos: [{1, 1, :"a@1.2.3.4"}],
    ch: "x"
  }

  test "valid contract messages" do
    assert {:ok, @ins} = Wire.parse(@ins)
    del = %{@ins | op: :del} |> Map.delete(:ch)
    assert {:ok, ^del} = Wire.parse(del)
    # extra keys (e.g. a ch in a del) are tolerated and dropped
    assert {:ok, ^del} = Wire.parse(%{@ins | op: :del})
    assert {:ok, ^del} = Wire.parse(Map.put(del, :extra, 1))
  end

  test "malformed operations are ignored" do
    bad = [
      %{},
      :garbage,
      %{@ins | op: :other},
      %{@ins | ch: "ab"},
      %{@ins | ch: ""},
      %{@ins | ch: <<255>>},
      %{@ins | ch: ?x},
      %{@ins | from: "a"},
      %{@ins | from: nil},
      %{@ins | vc: %{}},
      %{@ins | vc: %{:"a@1.2.3.4" => 0}},
      %{@ins | vc: %{:"a@1.2.3.4" => -1}},
      %{@ins | vc: [1]},
      %{@ins | pos: []},
      %{@ins | pos: [{2, 1, :a}]},
      %{@ins | pos: [{1, 0, :a}]},
      %{@ins | pos: [{1, 1, "a"}]},
      %{@ins | pos: [{1, 1, :a} | :improper]},
      %{@ins | pos: List.duplicate({1, 1, :a}, 10_001)}
    ]

    for b <- bad, do: assert(Wire.parse(b) == :ignore, inspect(b, limit: 4))
  end

  test "multicast packets: tag + node name, validated before becoming an atom" do
    assert Multicast.packet(:"pi-pe@172.20.10.4") == "crdt-treedoc-1 pi-pe@172.20.10.4"
    assert Multicast.parse("crdt-treedoc-1 pi-pe@172.20.10.4") == {:ok, :"pi-pe@172.20.10.4"}
    assert Multicast.parse("crdt-treedoc-1 doc@10.0.0.7") == {:ok, :"doc@10.0.0.7"}

    for p <- [
          "crdt-treedoc-1 pi-pe@172.20.10.4\n",
          "crdt-treedoc-2 a@1.2.3.4",
          "crdt-treedoc-1 ",
          "crdt-treedoc-1 a b@1.2.3.4",
          "crdt-treedoc-1 nohost",
          "crdt-treedoc-1 " <> String.duplicate("a", 65) <> "@1.2.3.4",
          "hello"
        ] do
      assert Multicast.parse(p) == :ignore, p
    end
  end
end
