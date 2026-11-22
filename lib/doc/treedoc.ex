defmodule Doc.Treedoc do
  @moduledoc """
  Treedoc: sequence CRDT for text (Preguiça, Marquès, Shapiro, Leția, ICDCS 2009),
  **operation-based** (CmRDT, Shapiro et al. 2011 §2.4). Pure: no processes,
  network or files. Same behaviour as the course (deck 20):

      new/0 · prepare/3 (origin only, no side effects) · effect/2 (every replica) · value/1

  Convergence (Shapiro 2011, Theorem 2.2): with causal delivery (`Doc.Causal`),
  an op-based object whose concurrent operations commute is SEC. Here:

    * two concurrent inserts have different PosIDs (unique disambiguators), so
      they touch different nodes of the tree and commute;
    * deletes only mark a tombstone and are idempotent; a delete of a PosID
      commutes with everything except the insert of that same PosID, which
      causally precedes it (it was visible to whoever deleted it).

  ## PosID (the class contract, `INTEGRATION.md` of the op-based group)

  A path in an extended binary tree; EVERY step carries its disambiguator:

      [{bit, seq, node}, ...]   bit 0 = left, 1 = right
                                {seq, node}: number of the operation in the
                                vector clock of `node` (unique, UDIS §3.3.1)

  The empty path `[]` is the virtual root. The text is the in-order walk:
  left subtree, the node, right subtree; siblings with the same bit (mini-nodes
  of one major node) are ordered by `{seq, node}`. As a comparison
  (`compare/2`): if `a` is a prefix of `b`, `b` goes before `a` when its next
  bit is 0 and after when it is 1; otherwise the first different step decides,
  comparing `{bit, seq, node}` as tuples (bit first, then seq, then node).

  ## Inserting (§3.4 of their DESIGN.md, the same rule as the paper's density)

      if right != nil and left is a prefix of right:  right ++ [{0, seq, node}]
      otherwise:                                      left  ++ [{1, seq, node}]

  `left`/`right` are the neighbours in the FULL order (tombstones included).
  A whole string inserted in one call (`prepare_text/5`) forms a balanced subtree
  placed with that same rule (depth log n instead of n, see the function).

  ## State

      %{root: node}     node = %{atom: nil | String.t(), dead: boolean, kids: %{step => node}}
  """

  @type step :: {0 | 1, pos_integer(), node()}
  @type pos :: [step]
  @type op :: {:insert, non_neg_integer(), String.t()} | {:delete, non_neg_integer()}
  @type eff :: %{op: :ins, pos: pos, ch: String.t()} | %{op: :del, pos: pos}

  @empty %{atom: nil, dead: false, kids: %{}}

  @doc "Empty document: only the virtual root."
  def new, do: %{root: @empty}

  # ---------------------------------------------------------------------------
  # Order
  # ---------------------------------------------------------------------------

  @doc "Total order of PosIDs (in-order walk). Returns `:lt`, `:eq` or `:gt`."
  @spec compare(pos, pos) :: :lt | :eq | :gt
  def compare([], []), do: :eq
  def compare([s | a], [s | b]), do: compare(a, b)
  def compare([], [{0, _, _} | _]), do: :gt
  def compare([], [{1, _, _} | _]), do: :lt
  def compare([{0, _, _} | _], []), do: :lt
  def compare([{1, _, _} | _], []), do: :gt
  def compare([sa | _], [sb | _]), do: if(sa < sb, do: :lt, else: :gt)

  # ---------------------------------------------------------------------------
  # prepare (origin only)
  # ---------------------------------------------------------------------------

  @doc "One operation on visible indexes → the effect message (PosID resolved)."
  @spec prepare(map, op, {pos_integer(), node()}) :: {:ok, eff} | {:error, :invalid_index}
  def prepare(state, {:insert, index, ch}, {seq, node}) when is_binary(ch) do
    case prepare_text(state, index, [ch], seq - 1, node) do
      {:ok, [{pos, ^ch}]} -> {:ok, %{op: :ins, pos: pos, ch: ch}}
      error -> error
    end
  end

  def prepare(state, {:delete, index}, _dot) do
    case prepare_delete(state, index, 1) do
      {:ok, [pos]} -> {:ok, %{op: :del, pos: pos}}
      error -> error
    end
  end

  def prepare(_state, _op, _dot), do: {:error, :invalid_index}

  @doc """
  A whole string at `index` in one step (a paste, or a word typed in IEx). Char
  `k` (0-based) gets the disambiguator `{seq0 + k + 1, node}`: one operation per
  char, numbered in text order, exactly as the vector clock will number them.

  Char by char at the end, every char would be the right child of the previous
  one (depth n; measured on the state-based version: 1000 chars → 11.5 s).
  Instead the middle char is placed between `left` and `right` with the rule of
  the moduledoc, the left half goes in its left subtree and the right half in
  its right subtree, recursively. A subtree is contiguous in the in-order walk,
  so every new char still lies between `left` and `right`, in text order, and
  the depth grows by ⌈log₂(n+1)⌉. Any rule that puts the PosID between the
  neighbours is valid (density; their DESIGN.md §3.4 says the same).

  Returns `{pos, ch}` in text order (= increasing seq = sending order).
  """
  @spec prepare_text(map, integer, [String.t()], non_neg_integer(), node()) ::
          {:ok, [{pos, String.t()}]} | {:error, :invalid_index}
  def prepare_text(state, index, chars, seq0, node) do
    vis = visible(state)

    if is_integer(index) and index >= 0 and index <= length(vis) do
      left = if index == 0, do: [], else: elem(Enum.at(vis, index - 1), 0)
      right = next_after(state, left)
      items = Enum.with_index(chars, seq0 + 1)

      atoms =
        items
        |> balanced(&new_pos(left, right, &1, node), node)
        |> Enum.sort_by(fn {_pos, _ch, seq} -> seq end)
        |> Enum.map(fn {pos, ch, _seq} -> {pos, ch} end)

      {:ok, atoms}
    else
      {:error, :invalid_index}
    end
  end

  defp balanced([], _place, _node), do: []

  defp balanced(items, place, node) do
    {l, [{ch, seq} | r]} = Enum.split(items, div(length(items), 2))
    p = place.(seq)

    [{p, ch, seq} | balanced(l, &(p ++ [{0, &1, node}]), node)] ++
      balanced(r, &(p ++ [{1, &1, node}]), node)
  end

  @doc "PosIDs of `count` visible chars from `index`, all or nothing."
  @spec prepare_delete(map, integer, integer) :: {:ok, [pos]} | {:error, :invalid_index}
  def prepare_delete(state, index, count) do
    vis = visible(state)

    if is_integer(index) and is_integer(count) and index >= 0 and count >= 0 and
         index + count <= length(vis) do
      {:ok, vis |> Enum.slice(index, count) |> Enum.map(&elem(&1, 0))}
    else
      {:error, :invalid_index}
    end
  end

  @doc "New PosID strictly between `left` and `right` (consecutive in the full order)."
  @spec new_pos(pos, pos | nil, pos_integer(), node()) :: pos
  def new_pos(left, right, seq, node) do
    if right != nil and List.starts_with?(right, left),
      do: right ++ [{0, seq, node}],
      else: left ++ [{1, seq, node}]
  end

  # ---------------------------------------------------------------------------
  # effect (every replica)
  # ---------------------------------------------------------------------------

  @doc """
  Applies an operation. Insert: the atom at `pos` (missing ancestors are created
  empty: a balanced paste may deliver a child before its parent; positions are
  paths, so the order is still right). Delete: tombstone, idempotent.

  A PosID is unique, so two different chars for one PosID only come from a
  buggy node; the smaller char wins so that every replica keeps the same one.
  """
  @spec effect(map, eff) :: map
  def effect(state, %{op: :ins, pos: pos, ch: ch}) do
    %{state | root: update(state.root, pos, fn n -> %{n | atom: min_char(n.atom, ch)} end)}
  end

  def effect(state, %{op: :del, pos: pos}) do
    %{state | root: update(state.root, pos, &%{&1 | dead: true})}
  end

  defp min_char(nil, ch), do: ch
  defp min_char(old, ch), do: min(old, ch)

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc "Visible text."
  @spec value(map) :: String.t()
  def value(state), do: state |> visible() |> Enum.map_join(&elem(&1, 1))

  @doc "Every atom in order as `{pos, ch, dead?}` (tombstones included)."
  def entries(state), do: walk(state.root, []) |> Enum.reverse()

  @doc "Visible atoms in order as `{pos, ch}`."
  def visible(state), do: for({p, ch, false} <- entries(state), do: {p, ch})

  @doc "Statistics: atoms, tombstones, max/avg path length."
  def stats(state) do
    e = entries(state)
    depths = Enum.map(e, fn {p, _, _} -> length(p) end)

    %{
      atoms: length(e),
      tombstones: Enum.count(e, fn {_, _, d} -> d end),
      max_depth: Enum.max(depths, fn -> 0 end),
      avg_depth: if(depths == [], do: 0, else: Float.round(Enum.sum(depths) / length(depths), 1))
    }
  end

  # ---------------------------------------------------------------------------
  # Tree helpers
  # ---------------------------------------------------------------------------

  defp update(node, [], fun), do: fun.(node)

  defp update(node, [step | rest], fun) do
    child = Map.get(node.kids, step, @empty)
    %{node | kids: Map.put(node.kids, step, update(child, rest, fun))}
  end

  # In-order walk accumulating in reverse: left kids (by step), self, right kids.
  defp walk(node, path, acc \\ [])

  defp walk(node, path, acc) do
    {lefts, rights} =
      node.kids
      |> Enum.sort_by(fn {step, _} -> step end)
      |> Enum.split_with(fn {{bit, _, _}, _} -> bit == 0 end)

    acc = Enum.reduce(lefts, acc, fn {s, kid}, acc -> walk(kid, path ++ [s], acc) end)
    acc = if node.atom != nil, do: [{path, node.atom, node.dead} | acc], else: acc
    Enum.reduce(rights, acc, fn {s, kid}, acc -> walk(kid, path ++ [s], acc) end)
  end

  # The atom right after `pos` in the full order (tombstones included), or nil.
  defp next_after(state, []), do: state |> entries() |> List.first() |> then(&(&1 && elem(&1, 0)))

  defp next_after(state, pos) do
    state
    |> entries()
    |> Enum.find_value(fn {p, _, _} -> if compare(p, pos) == :gt, do: p end)
  end
end
