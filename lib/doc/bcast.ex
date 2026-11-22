defmodule Doc.Bcast do
  @moduledoc """
  p_dist: "Toda la comunicación entre los nodos se debe realizar por medio de
  broadcasts de los mensajes a todos los nodos conectados."

  This is the ONLY place that sends a message to another node: every payload
  (operations, forwards, the history and `hello`) is cast to `Crdt.Replica`
  (`Doc.Wire.name/0`, the contract) on every node in `Node.list()`.

  Unlike the state-based version, a message is NEVER dropped on purpose: with
  causal delivery a missing operation of a node blocks all its later ones at the
  receiver until the next history re-send (nodeup / hello). So this is a plain
  send that relies on TCP; on a very bad link it may wait for the buffer to
  drain (the state-based pdoc can drop instead, its next full state repairs it).
  """

  @doc "Cast `payload` to `Crdt.Replica` on all connected nodes. Returns how many."
  @spec broadcast(term) :: non_neg_integer
  def broadcast(payload) do
    peers = Node.list()
    for n <- peers, do: GenServer.cast({Doc.Wire.name(), n}, payload)
    length(peers)
  end
end

defmodule Doc.Storage do
  @moduledoc """
  Append-only log of the operations this node applied (its own and the others'),
  in the order it applied them (that order respects causality), one per line
  (`term_to_binary` + Base64). On Nerves it lives in `/root` (the writable f2fs
  partition; the rootfs is read-only squashfs).

  It is what keeps the vector clock across reboots: without it the node would
  number its operations from 1 again and every other node would drop them as
  duplicates. A batch is written with ONE `:file.sync` BEFORE anything is sent.
  """
  require Logger

  def path, do: Path.join([Application.get_env(:opdoc, :data_dir, "data"), "opdoc", "ops.log"])

  @doc "This installation's epoch (`Doc.Dist`): next to the log, so both are lost together."
  def epoch_path, do: Path.join(Path.dirname(path()), "epoch")

  @doc """
  Opens the log for appending. If the last line was cut by a power failure (no
  final newline), that fragment is TRUNCATED: the operation never left the node
  (nothing is sent before the fsync), and closing it with a newline would leave
  a broken line in the middle of the log.
  """
  def open do
    File.mkdir_p!(Path.dirname(path()))
    truncate_torn_tail(path())
    {:ok, fd} = File.open(path(), [:append, :binary, :raw])
    fd
  end

  defp truncate_torn_tail(path) do
    with {:ok, data} when data != "" <- File.read(path),
         false <- String.ends_with?(data, "\n") do
      keep =
        case :binary.matches(data, "\n") do
          [] -> 0
          m -> (m |> List.last() |> elem(0)) + 1
        end

      Logger.warning(
        "[opdoc] last log line was cut (power failure?): truncating #{byte_size(data) - keep} bytes"
      )

      {:ok, f} = :file.open(path, [:read, :write, :binary, :raw])
      {:ok, _} = :file.position(f, keep)
      :ok = :file.truncate(f)
      :ok = :file.sync(f)
      :ok = :file.close(f)
    end

    :ok
  end

  @doc """
  Moves a damaged log aside (`ops.log.corrupt-<time>`) and starts a new one with
  `ops` (the valid prefix), with one fsync. Returns the new fd.
  """
  def replace(ops) do
    aside = "#{path()}.corrupt-#{System.os_time(:second)}"
    :ok = File.rename(path(), aside)
    Logger.error("[opdoc] damaged log moved to #{aside}")
    fd = open()
    :ok = append(fd, ops)
    fd
  end

  @doc "Appends operations with a single fsync. `:ok` or `{:error, reason}` (never raises)."
  def append(_fd, []), do: :ok

  def append(fd, ops) do
    lines = Enum.map(ops, &[Base.encode64(:erlang.term_to_binary(&1)), ?\n])

    with :ok <- :file.write(fd, lines), :ok <- :file.sync(fd) do
      :ok
    else
      {:error, reason} = e ->
        Logger.error("[opdoc] could not persist #{length(ops)} operation(s): #{inspect(reason)}")
        e
    end
  end

  @doc """
  Every logged operation in order: `{:ok, ops}`, or `{:corrupt, prefix, line}`
  when line `line` (1-based) cannot be decoded. Only the PREFIX is returned: the
  log is in applied (causal) order, so the prefix is a consistent state, while
  skipping a line would leave a gap in the vector clock for ever. (A cut LAST
  line never gets here: `open/0` truncates it.) Not decoded with `[:safe]`: the
  file is our own and the PosIDs contain node names (atoms) that may not exist
  yet right after boot.
  """
  def load do
    case File.read(path()) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {line, k}, {:ok, acc} ->
          case decode(line) do
            {:ok, op} -> {:cont, {:ok, [op | acc]}}
            :error -> {:halt, {:corrupt, acc, k}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          {:corrupt, acc, k} -> {:corrupt, Enum.reverse(acc), k}
        end

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  defp decode(line) do
    case :erlang.binary_to_term(Base.decode64!(line)) do
      %{from: f, vc: %{}} = op when is_atom(f) -> {:ok, op}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def wipe, do: File.rm(path())
end
