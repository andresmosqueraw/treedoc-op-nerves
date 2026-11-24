defmodule Doc do
  @moduledoc """
  Distributed document without a central server (ISIS-4218 CPD, p_dist).
  IEx interface (over `ssh` on the Pi):

  CRUD:

      Doc.insert(0, "Hola mundo")    # Create: insert at visible index
      Doc.append("fin\\n")            # Create: insert at the end
      Doc.text()                     # Read: the whole document (same on every node)
      Doc.read(0, 4)                 # Read: 4 chars from index 0 -> "Hola"
      Doc.replace(5, 5, "gente")     # Update: 5 chars from index 5 become "gente"
      Doc.delete(4, 6)               # Delete: 6 chars from index 4

  Every call returns `:ok` (or the text) or `{:error, reason}` and changes
  nothing on error (for example `{:error, :invalid_index}`).

  More:

      Doc.status()                   # vc, held ops, peers, counters, tree stats
      Doc.debug()                    # every atom with PosID and tombstones
      Doc.peers()                    # connected nodes
      Doc.connect("172.20.10.4")     # explicit connection (P5), by IP or full name
      Doc.watch()                    # print the document every time it changes
      Doc.hello()                    # ask every node to re-send its history
      Doc.history()                  # every applied operation, in order

  Operation-based Treedoc with causal delivery; speaks the op-based groups'
  contract (`Doc.Wire`), so their nodes and ours edit the same document.
  """
  defdelegate insert(index, text), to: Doc.Replica
  defdelegate delete(index, count \\ 1), to: Doc.Replica
  @doc "Update: replace `count` chars from `index` with `text`, in one call (one broadcast)."
  defdelegate replace(index, count, text), to: Doc.Replica

  @doc "Create at the end of the document."
  defdelegate append(text), to: Doc.Replica

  @doc "Read `count` chars from `index` (same indices as insert/delete)."
  defdelegate read(index, count), to: Doc.Replica

  defdelegate text(), to: Doc.Replica
  defdelegate status(), to: Doc.Replica
  defdelegate debug(), to: Doc.Replica

  @doc "Ask every connected node to re-send its whole history (also done on nodeup)."
  defdelegate hello(), to: Doc.Replica
  defdelegate history(), to: Doc.Replica

  def peers, do: Node.list()

  @doc """
  Explicit connection (P5) to a full node name, or to an IP: every node that
  epmd lists on that IP. Returns the nodes now connected, or `{:error, :not_found}`.
  """
  def connect(target) do
    case for(n <- Doc.Discovery.to_nodes(target), n != node(), Node.connect(n) == true, do: n) do
      [] -> {:error, :not_found}
      nodes -> {:ok, nodes}
    end
  end

  @doc "Print the document whenever it changes (until `Process.exit(pid, :kill)`)."
  def watch do
    leader = Process.group_leader()

    pid =
      spawn(fn ->
        Doc.Replica.subscribe()
        print_changes(leader)
      end)

    {:watching, pid}
  end

  defp print_changes(leader) do
    receive do
      {:opdoc_changed, text} -> IO.puts(leader, "📄 " <> text)
    end

    print_changes(leader)
  end
end
