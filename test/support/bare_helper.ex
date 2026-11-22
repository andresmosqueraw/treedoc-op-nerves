defmodule Doc.BareHelper do
  @moduledoc "Runs inside a peer WITHOUT distribution: `Doc.Dist` starts it (see dist_test)."

  def boot(base, dir) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :warning)
    _ = Application.load(:opdoc)
    for {k, v} <- [data_dir: dir, name: base], do: Application.put_env(:opdoc, k, v)
    :persistent_term.put({Doc.Net, :ip}, {127, 0, 0, 1})
    start_dist()
  end

  @doc "Like a boot of the Pi: replica FIRST (no distribution yet), then nothing else."
  def boot_replica_only(base, dir) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)
    _ = Application.load(:opdoc)

    for {k, v} <- [data_dir: dir, name: base, autostart: false],
        do: Application.put_env(:opdoc, k, v)

    :persistent_term.put({Doc.Net, :ip}, {127, 0, 0, 1})

    {:ok, sup} =
      Supervisor.start_link([Doc.Replica], strategy: :one_for_one, name: Doc.Supervisor)

    Process.unlink(sup)
    :ok
  end

  def start_dist do
    {:ok, pid} = Doc.Dist.start_link([])
    Process.unlink(pid)
    :ok
  end

  def stop_dist, do: GenServer.stop(Doc.Dist)
end
