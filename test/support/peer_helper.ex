defmodule Doc.PeerHelper do
  @moduledoc """
  Real BEAM peers on 127.0.0.1 (OTP `:peer`), each running the replica
  (`Crdt.Replica`) with its own data dir. Started with `-connect_all false` so
  the tests decide exactly who is connected to whom (partitions, chains).
  """

  def start(name, boot? \\ true) do
    args =
      Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++
        [~c"-connect_all", ~c"false", ~c"-setcookie", ~c"cpd2026"]

    {:ok, pid, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: args,
        connection: :standard_io
      })

    dir =
      Path.join(
        System.tmp_dir!(),
        "opdoc_peer_#{name}_#{System.os_time()}_#{:rand.uniform(1_000_000)}"
      )

    File.rm_rf!(dir)
    if boot?, do: :ok = :peer.call(pid, __MODULE__, :boot, [dir], 30_000)
    {pid, node}
  end

  def boot(dir) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :warning)
    _ = Application.load(:opdoc)

    for {k, v} <- [autostart: false, data_dir: dir, mdns: Doc.Mdns.Static, multicast: false],
        do: Application.put_env(:opdoc, k, v)

    {:ok, sup} =
      Supervisor.start_link([Doc.Replica], strategy: :one_for_one, name: Doc.Supervisor)

    Process.unlink(sup)
    :ok
  end

  def call(pid, m, f, a \\ []), do: :peer.call(pid, m, f, a, 30_000)

  @doc "Restart the replica (simulates a crash/reboot; the state comes from disk)."
  def restart_replica do
    :ok = Supervisor.terminate_child(Doc.Supervisor, Doc.Replica)
    {:ok, _} = Supervisor.restart_child(Doc.Supervisor, Doc.Replica)
    :ok
  end

  @doc "Cast a raw payload to `Crdt.Replica` on `node` (from inside a peer)."
  def cast_raw(node, payload), do: GenServer.cast({Crdt.Replica, node}, payload)

  def eventually(fun, tries \\ 80)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, tries) do
    fun.() or
      (
        Process.sleep(100)
        eventually(fun, tries - 1)
      )
  end
end
