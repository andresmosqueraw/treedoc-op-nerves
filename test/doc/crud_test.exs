defmodule Doc.CrudTest do
  @moduledoc """
  The CRUD API on real nodes (OTP :peer): Create (`insert`, `append`), Read
  (`text`, `read`), Update (`replace`), Delete (`delete`). Every edit reaches the
  other node; invalid calls return an error and change nothing.
  """
  use ExUnit.Case, async: false
  import Doc.PeerHelper, only: [call: 4, eventually: 1]
  alias Doc.PeerHelper, as: P
  @moduletag timeout: 120_000

  setup do
    peers = for n <- [:a, :b], do: P.start(:"crud#{n}#{System.unique_integer([:positive])}")
    on_exit(fn -> for {p, _} <- peers, do: :peer.stop(p) end)
    [{pa, _a}, {pb, b}] = peers
    true = call(pa, Node, :connect, [b])
    %{pa: pa, pb: pb}
  end

  defp both(c, expected),
    do:
      eventually(fn ->
        call(c.pa, Doc, :text, []) == expected and call(c.pb, Doc, :text, []) == expected
      end)

  test "create, read, update, delete: each one reaches the other node", c do
    # Create
    :ok = call(c.pa, Doc, :insert, [0, "Hola mundo"])
    assert both(c, "Hola mundo")
    :ok = call(c.pb, Doc, :append, ["!"])
    assert both(c, "Hola mundo!")

    # Read
    assert call(c.pb, Doc, :read, [0, 4]) == "Hola"
    assert call(c.pa, Doc, :read, [5, 6]) == "mundo!"
    assert call(c.pa, Doc, :read, [11, 0]) == ""

    # Update: one call, on the other node
    :ok = call(c.pb, Doc, :replace, [5, 5, "gente"])
    assert both(c, "Hola gente!")
    # shorter and longer replacements, with graphemes
    :ok = call(c.pa, Doc, :replace, [0, 4, "Chao 👋🏽"])
    assert both(c, "Chao 👋🏽 gente!")
    assert call(c.pb, Doc, :read, [5, 1]) == "👋🏽"
    # count 0 is an insert; empty text is a delete
    :ok = call(c.pa, Doc, :replace, [0, 0, "¡"])
    :ok = call(c.pb, Doc, :replace, [6, 2, ""])
    assert both(c, "¡Chao gente!")

    # Delete
    :ok = call(c.pb, Doc, :delete, [0, 1])
    assert both(c, "Chao gente!")
  end

  test "replace is ONE call: one log write, numbered in order, deletes before inserts", c do
    :ok = call(c.pa, Doc, :insert, [0, "abc"])
    assert both(c, "abc")
    before = length(call(c.pa, Doc, :history, []))
    :ok = call(c.pa, Doc, :replace, [1, 1, "XY"])
    new = call(c.pa, Doc, :history, []) |> Enum.drop(before)
    assert Enum.map(new, & &1.op) == [:del, :ins, :ins]
    me = hd(new).from
    assert Enum.map(new, & &1.vc[me]) == [4, 5, 6]
    assert both(c, "aXYc")
  end

  test "invalid calls return an error and change nothing", c do
    :ok = call(c.pa, Doc, :insert, [0, "abc"])
    assert both(c, "abc")

    for {f, args} <- [
          {:replace, [2, 5, "x"]},
          {:replace, [-1, 1, "x"]},
          {:replace, [4, 0, "x"]},
          {:replace, [0, 1, <<255>>]},
          {:replace, [0, 1, :x]},
          {:read, [2, 5]},
          {:read, [-1, 1]},
          {:read, [0, :a]},
          {:append, [<<255>>]},
          {:append, [:x]}
        ] do
      assert {:error, _} = call(c.pa, Doc, f, args), "#{f}#{inspect(args)}"
    end

    Process.sleep(300)
    assert call(c.pa, Doc, :text, []) == "abc"
    assert call(c.pb, Doc, :text, []) == "abc"
  end
end
