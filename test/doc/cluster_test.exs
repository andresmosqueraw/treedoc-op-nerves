defmodule Doc.ClusterTest do
  @moduledoc "Real nodes (OTP :peer): broadcast, causal delivery, forwarding, partitions, restarts."
  use ExUnit.Case, async: false
  import Doc.PeerHelper, only: [call: 4, eventually: 1]
  alias Doc.PeerHelper, as: P

  @moduletag timeout: 180_000

  setup do
    peers = for n <- [:a, :b, :c], do: P.start(:"#{n}#{System.unique_integer([:positive])}")
    on_exit(fn -> for {p, _} <- peers, do: :peer.stop(p) end)
    [{pa, a}, {pb, b}, {pc, c}] = peers
    %{peers: peers, pa: pa, pb: pb, pc: pc, a: a, b: b, c: c, all: [pa, pb, pc]}
  end

  defp link(p, n), do: true = call(p, Node, :connect, [n])
  defp unlink(p, n), do: call(p, Node, :disconnect, [n])

  defp mesh(c),
    do:
      (
        link(c.pa, c.b)
        link(c.pa, c.c)
        link(c.pb, c.c)
      )

  defp texts(pids), do: Enum.map(pids, &call(&1, Doc, :text, []))

  defp converged?(pids, expected \\ nil) do
    t = texts(pids)
    length(Enum.uniq(t)) == 1 and (expected == nil or hd(t) == expected)
  end

  test "a local edit reaches every node; deletes too", c do
    mesh(c)
    :ok = call(c.pa, Doc, :insert, [0, "Hola"])
    assert eventually(fn -> converged?(c.all, "Hola") end)
    :ok = call(c.pb, Doc, :insert, [4, " mundo"])
    :ok = call(c.pc, Doc, :delete, [0, 1])
    assert eventually(fn -> converged?(c.all, "ola mundo") end)
    st = call(c.pa, Doc, :status, [])
    assert st.vc == %{c.a => 4, c.b => 6, c.c => 1}
    assert st.waiting == []
  end

  test "simultaneous writes at the same position converge, words not interleaved", c do
    mesh(c)
    :ok = call(c.pa, Doc, :insert, [0, "[]"])
    assert eventually(fn -> converged?(c.all, "[]") end)

    for {p, w} <- [{c.pa, "uno"}, {c.pb, "dos"}, {c.pc, "tres"}] do
      Task.async(fn -> call(p, Doc, :insert, [1, w]) end)
    end
    |> Enum.each(&Task.await/1)

    assert eventually(fn -> converged?(c.all) end)
    [t | _] = texts(c.all)
    for w <- ~w(uno dos tres), do: assert(String.contains?(t, w), "#{w} interleaved in #{t}")
    assert String.length(t) == 12
  end

  test "forwarding: in a chain A-B-C (A and C never connected) everything arrives", c do
    link(c.pa, c.b)
    link(c.pb, c.c)
    refute c.c in call(c.pa, Node, :list, [])
    :ok = call(c.pa, Doc, :insert, [0, "desde A"])
    :ok = call(c.pc, Doc, :insert, [0, "C: "])
    assert eventually(fn -> converged?(c.all, "C: desde A") end)
  end

  test "partition: both sides keep editing offline and converge on reconnect", c do
    mesh(c)
    :ok = call(c.pa, Doc, :insert, [0, "base"])
    assert eventually(fn -> converged?(c.all, "base") end)

    unlink(c.pc, c.a)
    unlink(c.pc, c.b)
    :ok = call(c.pa, Doc, :insert, [4, " AB"])
    :ok = call(c.pc, Doc, :insert, [0, "C "])
    :ok = call(c.pc, Doc, :delete, [2, 1])
    assert eventually(fn -> converged?([c.pa, c.pb], "base AB") end)
    assert call(c.pc, Doc, :text, []) == "C ase"

    # nodeup → each side re-sends its history; duplicates are dropped
    link(c.pc, c.a)
    assert eventually(fn -> converged?(c.all, "C ase AB") end)
    assert call(c.pa, Doc, :status, []).ops_duplicate > 0
  end

  test "restart: the clock comes back from disk, new ops are not taken as duplicates", c do
    mesh(c)
    :ok = call(c.pa, Doc, :insert, [0, "abc"])
    assert eventually(fn -> converged?(c.all, "abc") end)

    :ok = call(c.pa, P, :restart_replica, [])
    assert call(c.pa, Doc, :text, []) == "abc"
    assert call(c.pa, Doc, :status, []).vc[c.a] == 3

    :ok = call(c.pa, Doc, :insert, [3, "d"])
    assert eventually(fn -> converged?(c.all, "abcd") end)
    assert call(c.pb, Doc, :status, []).vc[c.a] == 4
  end

  test "a node that was down catches up from the others' history (hello / nodeup)", c do
    link(c.pa, c.b)
    :ok = call(c.pa, Doc, :insert, [0, "historia"])
    :ok = call(c.pb, Doc, :delete, [0, 1])
    assert eventually(fn -> converged?([c.pa, c.pb], "istoria") end)
    assert call(c.pc, Doc, :text, []) == ""
    link(c.pc, c.b)
    assert eventually(fn -> converged?(c.all, "istoria") end)
  end

  test "out of order and duplicated contract messages: held, then applied once", c do
    # a foreign node speaking only the contract, by raw casts
    f = :"f@127.0.0.1"
    # "xyz" typed one by one: each char is the right child of the previous one
    ops =
      for {ch, seq} <- Enum.with_index(["x", "y", "z"], 1),
          do: %{op: :ins, from: f, vc: %{f => seq}, pos: for(k <- 1..seq, do: {1, k, f}), ch: ch}

    [o1, o2, o3] = ops
    for o <- [o3, o2, o3], do: call(c.pa, P, :cast_raw, [c.a, {:remote, o}])
    assert eventually(fn -> length(call(c.pa, Doc, :status, []).waiting) == 2 end)
    assert call(c.pa, Doc, :text, []) == ""

    call(c.pa, P, :cast_raw, [c.a, {:remote, o1}])
    assert eventually(fn -> call(c.pa, Doc, :text, []) == "xyz" end)
    call(c.pa, P, :cast_raw, [c.a, {:remote, o1}])
    st = call(c.pa, Doc, :status, [])
    assert st.vc[f] == 3 and st.waiting == [] and st.ops_duplicate >= 1
  end

  test "garbage from the network never crashes the replica", c do
    pid = call(c.pa, Process, :whereis, [Crdt.Replica])

    for junk <- [{:remote, %{}}, {:remote, :x}, {:hello, "x"}, :boom, {:remote, %{op: :ins}}] do
      call(c.pa, P, :cast_raw, [c.a, junk])
    end

    call(c.pa, Kernel, :send, [Crdt.Replica, :raw_junk])
    :ok = call(c.pa, Doc, :insert, [0, "vivo"])
    assert call(c.pa, Process, :whereis, [Crdt.Replica]) == pid
    assert call(c.pa, Doc, :status, []).msgs_ignored >= 6
  end

  test "bad local arguments return errors and change nothing", c do
    assert call(c.pa, Doc, :insert, [5, "x"]) == {:error, :invalid_index}
    assert call(c.pa, Doc, :insert, [0, <<255>>]) == {:error, :invalid_utf8}
    assert call(c.pa, Doc, :insert, [:a, "x"]) == {:error, :badarg}
    assert call(c.pa, Doc, :delete, [0, 1]) == {:error, :invalid_index}
    assert call(c.pa, Doc, :insert, [0, ""]) == :ok
    assert call(c.pa, Doc, :status, []).vc == %{}
  end
end
