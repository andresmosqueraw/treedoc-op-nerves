defmodule Doc.Wire do
  @moduledoc """
  The wire format, i.e. the class contract of the op-based groups
  (`docs/INTEGRATION.md` of `fepecas/treedoc`, also used by `treedoc-nerves`).
  Implemented from that document, not from their code.

    * one process per node registered as `Crdt.Replica`;
    * casts (`GenServer.cast/2`, a plain process gets `{:"$gen_cast", m}`):

          {:remote, %{op: :ins, from: node, vc: %{node => n}, pos: [{bit, seq, node}], ch: "a"}}
          {:remote, %{op: :del, from: node, vc: %{node => n}, pos: [{bit, seq, node}]}}
          {:hello, node}      # "send me your whole history again"

    * `vc[from]` counts 1, 2, 3… per node with no gaps and no reuse; `ch` is one
      grapheme; every applied operation is forwarded once, unchanged; the whole
      history is re-sent on `nodeup` and on `hello`.

  `parse/1` validates everything that comes from another node, so a malformed
  or oversize operation is ignored and never crashes the replica.
  """

  @name Crdt.Replica
  @doc "The registered name of the replica on every node (the contract)."
  def name, do: @name

  # A legitimate PosID is as deep as the chars typed one by one in a row at the
  # end (their rule); a clock has one entry per node name ever used.
  @max_depth 10_000
  @max_vc 10_000

  @doc "Validates a `{:remote, msg}` payload. `{:ok, msg}` or `:ignore`."
  def parse(%{op: :ins, from: from, vc: vc, pos: pos, ch: ch} = m) do
    if base_ok?(from, vc, pos) and valid_char?(ch),
      do: {:ok, Map.take(m, [:op, :from, :vc, :pos, :ch])},
      else: :ignore
  end

  def parse(%{op: :del, from: from, vc: vc, pos: pos} = m) do
    if base_ok?(from, vc, pos),
      do: {:ok, Map.take(m, [:op, :from, :vc, :pos])},
      else: :ignore
  end

  def parse(_), do: :ignore

  defp base_ok?(from, vc, pos) do
    is_atom(from) and from != nil and valid_vc?(vc) and
      match?(n when is_integer(n) and n >= 1, Map.get(vc, from)) and valid_pos?(pos)
  end

  defp valid_vc?(vc) when is_map(vc) and map_size(vc) <= @max_vc,
    do: Enum.all?(vc, fn {k, n} -> is_atom(k) and is_integer(n) and n >= 0 end)

  defp valid_vc?(_), do: false

  @doc "Non-empty proper list of `{0|1, seq >= 1, node}`, at most #{@max_depth} steps."
  def valid_pos?(pos), do: steps(pos, 0)

  defp steps([], n), do: n > 0

  defp steps([{bit, seq, node} | rest], n)
       when bit in [0, 1] and is_integer(seq) and seq >= 1 and is_atom(node) and n < @max_depth,
       do: steps(rest, n + 1)

  defp steps(_, _), do: false

  @doc "A valid string with exactly one grapheme."
  def valid_char?(ch) when is_binary(ch),
    do: String.valid?(ch) and match?([_], String.graphemes(ch))

  def valid_char?(_), do: false
end
