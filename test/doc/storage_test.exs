defmodule Doc.StorageTest do
  @moduledoc """
  The operation log after power cuts and damage. A cut LAST line is truncated
  (it never left the node); a damaged line in the MIDDLE keeps only the valid
  prefix and forces a new node name, so no sequence number is ever reused.
  """
  use ExUnit.Case, async: false
  alias Doc.PeerHelper, as: P

  @moduletag timeout: 120_000

  defp tmp,
    do: Path.join(System.tmp_dir!(), "opdoc_storage_#{System.unique_integer([:positive])}")

  defp call(pid, m, f, a \\ []), do: :peer.call(pid, m, f, a, 30_000)

  # "abc" typed by `n`, as the replica logs it
  defp ops(n) do
    for {ch, k} <- Enum.with_index(~w(a b c), 1),
        do: %{op: :ins, from: n, vc: %{n => k}, pos: for(j <- 1..k, do: {1, j, n}), ch: ch}
  end

  defp line(op), do: Base.encode64(:erlang.term_to_binary(op)) <> "\n"

  defp write_log(dir, content) do
    File.mkdir_p!(Path.join(dir, "opdoc"))
    File.write!(Path.join([dir, "opdoc", "ops.log"]), content)
  end

  defp log(dir), do: File.read!(Path.join([dir, "opdoc", "ops.log"]))

  # the operations in the log (bytes may differ between VMs: map key order)
  defp logged(dir) do
    content = log(dir)
    assert String.ends_with?(content, "\n")

    for l <- String.split(content, "\n", trim: true),
        do: :erlang.binary_to_term(Base.decode64!(l))
  end

  defp start_bare(base, dir) do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, pid, _} = :peer.start(%{connection: :standard_io, args: args})
    :ok = call(pid, Doc.BareHelper, :boot_replica_only, [base, dir])
    on_exit(fn -> :peer.stop(pid) end)
    pid
  end

  test "a cut last line is truncated (not closed with a newline) and the log keeps working" do
    dir = tmp()
    [a, b, c] = ops(:"x@1.2.3.4")
    write_log(dir, line(a) <> line(b) <> binary_part(line(c), 0, 9))

    p = start_bare("pi", dir)
    assert call(p, Doc, :text) == "ab"
    assert call(p, Doc, :status).vc == %{:"x@1.2.3.4" => 2}
    # the fragment is gone: the file is exactly the two whole lines
    assert log(dir) == line(a) <> line(b)
    refute call(p, Doc, :status).blocked
  end

  test "a damaged MIDDLE line (no network yet, as at boot): prefix kept, file aside, new epoch" do
    dir = tmp()
    [a, b, c] = ops(:"x@1.2.3.4")
    write_log(dir, line(a) <> "!!dañada!!\n" <> line(b) <> line(c))
    File.write!(Path.join([dir, "opdoc", "epoch"]), "aaaaaa")

    p = start_bare("pi", dir)
    # only the prefix: skipping the line would leave vc[x] with a hole for ever
    assert call(p, Doc, :text) == "a"
    assert call(p, Doc, :status).vc == %{:"x@1.2.3.4" => 1}
    assert logged(dir) == [a]
    assert [_] = Path.wildcard(Path.join([dir, "opdoc", "ops.log.corrupt-*"]))
    # the epoch was forgotten: the name that comes up now is a new one
    refute File.exists?(Path.join([dir, "opdoc", "epoch"]))
    refute call(p, Doc, :status).blocked

    :ok = call(p, Doc.BareHelper, :start_dist)
    refute call(p, Node, :self) |> Atom.to_string() |> String.contains?("aaaaaa")
    assert call(p, Doc, :insert, [1, "z"]) == :ok
  end

  test "a damaged middle line found with the distribution ALREADY up: local edits refused" do
    dir = tmp()
    {pid, _node} = P.start(:"st#{System.unique_integer([:positive])}", false)
    on_exit(fn -> :peer.stop(pid) end)
    [a, b, _] = ops(:"x@1.2.3.4")
    write_log(dir, line(a) <> "basura\n" <> line(b))

    :ok = call(pid, P, :boot, [dir])
    st = call(pid, Doc, :status)
    assert st.blocked
    assert st.text == "a"
    assert call(pid, Doc, :insert, [0, "q"]) == {:error, :restart_required}
    # remote operations are still applied
    :ok = call(pid, P, :cast_raw, [call(pid, Node, :self), {:remote, b}])
    assert P.eventually(fn -> call(pid, Doc, :text) == "ab" end)
  end
end
