defmodule Doc.DistTest do
  @moduledoc """
  `Doc.Dist` starting the distribution itself, as on the Pi: peers WITHOUT a
  name (OTP `:peer` over stdio) so the name, the epoch and the ports are ours.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  defp start_bare(base, dir) do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, pid, _} = :peer.start(%{connection: :standard_io, args: args})
    :ok = :peer.call(pid, Doc.BareHelper, :boot, [base, dir], 30_000)
    on_exit(fn -> :peer.stop(pid) end)
    pid
  end

  defp call(pid, m, f, a \\ []), do: :peer.call(pid, m, f, a, 30_000)
  defp tmp, do: Path.join(System.tmp_dir!(), "opdoc_dist_#{System.unique_integer([:positive])}")

  test "fix 1: the name carries an epoch that survives restarts and changes on reflash" do
    dir = tmp()
    p = start_bare("pi-a", dir)
    name = call(p, Node, :self)
    assert Atom.to_string(name) =~ ~r/\Api-a-[0-9a-f]{6}@127\.0\.0\.1\z/

    # reboot: same data dir → same name (its clock entry continues)
    :ok = call(p, Doc.BareHelper, :stop_dist)
    refute call(p, Node, :alive?)
    :ok = call(p, Doc.BareHelper, :start_dist)
    assert call(p, Node, :self) == name

    # reflash: /root wiped (log AND epoch) → a new name, numbering from 1 is safe
    :ok = call(p, Doc.BareHelper, :stop_dist)
    File.rm_rf!(dir)
    :ok = call(p, Doc.BareHelper, :start_dist)
    new = call(p, Node, :self)
    assert new != name
    assert Atom.to_string(new) =~ ~r/\Api-a-[0-9a-f]{6}@127\.0\.0\.1\z/
  end

  test "fix 2 and 3: listens in 4218-4228, and an IP is enough to connect to a node with another name" do
    a = start_bare("pi-a", tmp())
    b = start_bare("otra-maquina", tmp())
    na = call(a, Node, :self)
    nb = call(b, Node, :self)

    for n <- [na, nb] do
      [short, _] = String.split(Atom.to_string(n), "@")
      {:port, port, _} = :erl_epmd.port_please(String.to_charlist(short), {127, 0, 0, 1})
      assert port in 4218..4228, "#{n} listens on #{port}"
    end

    # B's name has nothing to do with A's hostname/epoch: epmd tells it
    assert nb in call(a, Doc.Discovery, :nodes_at, [{127, 0, 0, 1}])
    assert {:ok, connected} = call(a, Doc, :connect, ["127.0.0.1"])
    assert nb in connected
    assert nb in call(a, Node, :list)

    assert call(a, Doc.Discovery, :to_nodes, ["x@1.2.3.4"]) == [:"x@1.2.3.4"]
    assert call(a, Doc.Discovery, :to_nodes, ["no es ip"]) == []
    # an address that never answers (TEST-NET-1): nothing, within the bound
    {us, []} = call(a, :timer, :tc, [Doc.Discovery, :nodes_at, [{192, 0, 2, 1}, 1_000]])
    assert us < 2_000_000
  end

  test "stays connected while idle to a node with the default net_ticktime (regression)" do
    # Doc.Dist used net_ticktime 10; the other groups use Erlang's 60 (a tick
    # every 15 s), so ours cut them ~12 s after connecting: "not responding"
    a = start_bare("pi-a", tmp())
    {other, nb} = Doc.PeerHelper.start(:"default#{System.unique_integer([:positive])}", false)
    on_exit(fn -> :peer.stop(other) end)

    assert call(a, :net_kernel, :get_net_ticktime) == call(other, :net_kernel, :get_net_ticktime)
    assert call(a, Node, :connect, [nb])
    Process.sleep(20_000)
    assert nb in call(a, Node, :list), "the connection dropped while idle"
  end
end
