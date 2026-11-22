defmodule Doc.Causal do
  @moduledoc """
  Causal delivery with vector clocks (Lamport 1978; Birman, Schiper, Stephenson
  1991 — CBCAST; course deck 20). Pure: it only decides; `Doc.Replica` applies.

  A vector clock is `%{node => n}`: how many operations of each node this
  replica has applied (a missing key is 0). Every operation carries the clock of
  its origin right after it, so `m[from]` is its sequence number and `m[k]` says
  how many operations of `k` the origin had applied before creating it.

  Rule when an operation from `i` with clock `m` arrives at a replica with `vc`
  (the same rule as the op-based group's contract, so both interoperate):

    * **duplicate** if `m[i] <= vc[i]` (already applied: drop it);
    * **deliverable** if `m[i] == vc[i] + 1` and `m[k] <= vc[k]` for every other `k`
      (everything it depends on was applied): apply, then `vc[i] := m[i]`;
    * otherwise **wait** in the buffer; after each delivery the buffer is checked
      again until nothing changes.

  Delivering exactly once and in causal order is the precondition of Shapiro
  2011 Theorem 2.2 for an op-based CRDT to converge.
  """

  @type vc :: %{optional(node()) => non_neg_integer()}
  @type msg :: %{required(:from) => node(), required(:vc) => vc, optional(atom) => any}

  @doc "Sequence number and clock of the next local operation of `me` (no side effects)."
  @spec next_local(vc, node()) :: {pos_integer(), vc}
  def next_local(vc, me) do
    seq = Map.get(vc, me, 0) + 1
    {seq, Map.put(vc, me, seq)}
  end

  @doc "`:duplicate`, `:deliverable` or `:wait`."
  @spec classify(vc, msg) :: :duplicate | :deliverable | :wait
  def classify(vc, %{from: i, vc: m}) do
    mi = Map.get(m, i, 0)
    vi = Map.get(vc, i, 0)

    cond do
      mi <= vi ->
        :duplicate

      mi == vi + 1 and Enum.all?(m, fn {k, n} -> k == i or n <= Map.get(vc, k, 0) end) ->
        :deliverable

      true ->
        :wait
    end
  end

  @doc "Clock after delivering `msg`."
  @spec deliver(vc, msg) :: vc
  def deliver(vc, %{from: i, vc: m}), do: Map.put(vc, i, Map.get(m, i, 0))

  @doc """
  Receives one message. Returns `{vc, buffer, events}` where `events` is the
  ordered list of `{:applied, msg}` (to apply in that order), `{:duplicate, msg}`
  and `{:waiting, msg}`. The buffer never holds two copies of the same
  `{from, m[from]}`.
  """
  @spec receive_msg(vc, [msg], msg) :: {vc, [msg], list}
  def receive_msg(vc, buffer, msg) do
    case classify(vc, msg) do
      :duplicate ->
        {vc, buffer, [{:duplicate, msg}]}

      :wait ->
        if Enum.any?(buffer, &same_op?(&1, msg)),
          do: {vc, buffer, []},
          else: {vc, buffer ++ [msg], [{:waiting, msg}]}

      :deliverable ->
        {vc, buffer, applied} = drain(deliver(vc, msg), buffer, [msg])
        {vc, buffer, Enum.map(applied, &{:applied, &1})}
    end
  end

  # Deliver from the buffer until nothing changes; drop what became duplicate.
  defp drain(vc, buffer, applied) do
    buffer = Enum.reject(buffer, &(classify(vc, &1) == :duplicate))

    case Enum.find(buffer, &(classify(vc, &1) == :deliverable)) do
      nil -> {vc, buffer, Enum.reverse(applied)}
      m -> drain(deliver(vc, m), List.delete(buffer, m), [m | applied])
    end
  end

  defp same_op?(a, b), do: a.from == b.from and a.vc[a.from] == b.vc[b.from]

  @doc "What a waiting message still needs: `%{node => last seq needed}`."
  @spec missing(vc, msg) :: %{node() => non_neg_integer()}
  def missing(vc, %{from: i, vc: m}) do
    for {k, n} <- m,
        need = if(k == i, do: n - 1, else: n),
        need > Map.get(vc, k, 0),
        into: %{},
        do: {k, need}
  end
end
