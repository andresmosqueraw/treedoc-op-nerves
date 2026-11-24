# Pruebas PC <-> Pi, corridas por scripts/pi.sh dentro de un nodo opdoc real en el PC.
# Cada línea dice QUIÉN hace la acción: [PC] este portátil, [PI] la Raspberry
# (las llamadas :erpc.call(pi, ...) se ejecutan DENTRO de la Pi).
Logger.configure(level: :warning)
pi_ip = System.fetch_env!("PI_IP")
pi = String.to_atom(System.fetch_env!("PI_NODE"))
:net_kernel.monitor_nodes(true)
{:ok, results} = Agent.start_link(fn -> [] end)
t0 = System.monotonic_time(:millisecond)

clock = fn -> {_, {h, m, s}} = :calendar.local_time(); :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> to_string() end
log = fn who, msg -> IO.puts("  #{clock.()} [#{who}] #{msg}") end
pc = fn msg -> log.("PC", msg) end
pim = fn msg -> log.("PI", msg) end
short = fn t -> inspect(String.slice(t || "", 0, 50)) <> if(String.length(t || "") > 50, do: "…", else: "") end

ok = fn good, label ->
  IO.puts("           #{if good, do: "ok  ", else: "FAIL"}  #{label}")
  Agent.update(results, &[good | &1])
  good
end

# ejecuta en la Pi y muestra qué nodo lo ejecutó
on_pi = fn f, args ->
  r = :erpc.call(pi, Doc, f, args)
  where = :erpc.call(pi, :erlang, :node, [])
  pim.("Doc.#{f}(#{Enum.map_join(args, ", ", &inspect/1)}) ejecutado en #{where} -> #{inspect(r)}")
  r
end

on_pc = fn f, args ->
  r = apply(Doc, f, args)
  pc.("Doc.#{f}(#{Enum.map_join(args, ", ", &inspect/1)}) ejecutado en #{node()} -> #{inspect(r)}")
  r
end

# PC y Pi con el mismo texto (y que cumpla `pred`) en a lo más `ms`
converge = fn pred, ms ->
  s = System.monotonic_time(:millisecond)
  r =
    Enum.find_value(1..div(ms, 200), fn _ ->
      a = Doc.text()
      b = try do :erpc.call(pi, Doc, :text, []) catch _, _ -> nil end
      if a == b and pred.(a), do: {:ok, a}, else: (Process.sleep(200); nil)
    end)

  case r do
    {:ok, t} ->
      IO.puts("           PC y PI tienen el MISMO texto tras #{System.monotonic_time(:millisecond) - s} ms (#{String.length(t)} caracteres): #{short.(t)}")
      r

    nil ->
      a = Doc.text()
      b = try do :erpc.call(pi, Doc, :text, []) catch _, _ -> nil end
      IO.puts("           tras #{ms} ms: PC #{short.(a)}  /  PI #{short.(b)}")
      {:error, a}
  end
end

# borra exactamente `mark` (texto nuestro) en el nodo `n`; nunca toca texto ajeno
del_mark = fn on, n, mark ->
  t = :erpc.call(n, Doc, :text, [])

  case :binary.match(t, mark) do
    {b, _} -> on.(:delete, [String.length(binary_part(t, 0, b)), String.length(mark)])
    :nomatch -> :nomatch
  end
end

step = fn title -> IO.puts("\n  --- #{title}") end

step.("A. conexión")
pc.("soy el nodo #{node()} (este portátil). Busco a la Pi #{pi} en Node.list() ...")

connected =
  Enum.find_value(1..50, fn k ->
    if pi in Node.list() do
      true
    else
      if rem(k, 10) == 0, do: pc.("todavía no; Doc.connect(#{inspect(pi_ip)}) -> #{inspect(Doc.connect(pi_ip))}")
      Process.sleep(200)
      nil
    end
  end) || false

pc.("Node.list() del PC: #{inspect(Node.list())}")
ok.(connected, "PC conectado a la Pi (#{pi})")

unless connected do
  IO.puts("           ¿Llegan los puertos 4369 y 4218-4228? A mano: Doc.connect(\"#{pi_ip}\")")
  System.halt(1)
end

seen = :erpc.call(pi, Node, :list, [])
pim.("Node.list() de la Pi (ahora incluye al PC): #{inspect(seen)}")
ok.(node() in seen, "la Pi también ve al PC (la conexión es de ida y vuelta)")

tp = :erpc.call(pi, :net_kernel, :get_net_ticktime, [])
pc.("net_ticktime: PC #{:net_kernel.get_net_ticktime()} s, PI #{tp} s")
ok.(:net_kernel.get_net_ticktime() == tp, "mismo net_ticktime en ambos")

step.("B. el PC recibe el documento que tiene la Pi")
{_, t} = converge.(fn _ -> true end, 15_000)
ok.(is_binary(t), "el PC recibió el documento de la Pi")

stamp = clock.()

step.("C. el PC escribe -> ¿llega a la Pi?")
on_pc.(:insert, [0, "[laptop #{stamp}] "])
{r, _} = converge.(&String.contains?(&1, "[laptop #{stamp}] "), 10_000)
ok.(r == :ok, "la edición del PC aparece en la Pi")

step.("D. la Pi escribe -> ¿llega al PC?")
on_pi.(:insert, [0, "[pi #{stamp}] "])
{r, _} = converge.(&String.contains?(&1, "[pi #{stamp}] "), 10_000)
ok.(r == :ok, "la edición de la Pi aparece en el PC")

step.("E. los dos escriben a la vez en el mismo lugar")
t1 = Task.async(fn -> on_pc.(:insert, [0, "<L>"]) end)
t2 = Task.async(fn -> on_pi.(:insert, [0, "<P>"]) end)
Task.await(t1); Task.await(t2)
{r, _} = converge.(&(String.contains?(&1, "<L>") and String.contains?(&1, "<P>")), 10_000)
ok.(r == :ok, "ediciones concurrentes: el mismo texto en ambos")

step.("F. la Pi borra (solo nuestras marcas) -> ¿llega al PC?")
del_mark.(on_pi, pi, "<L>")
del_mark.(on_pi, pi, "<P>")
{r, _} = converge.(&(not String.contains?(&1, "<L>") and not String.contains?(&1, "<P>")), 10_000)
ok.(r == :ok, "el borrado de la Pi aparece en el PC")

step.("G. 70 s sin tráfico (antes la conexión se cortaba a los ~12 s)")
down =
  Enum.find_value(1..7, fn k ->
    receive do
      {:nodedown, ^pi} -> true
    after
      10_000 -> pc.("#{k * 10} s quieto: ¿la Pi sigue en Node.list()? #{pi in Node.list()}"); nil
    end
  end)

ok.(down != true and pi in Node.list(), "siguen conectados tras 70 s sin tráfico")

step.("H. editar después de la pausa")
on_pc.(:insert, [0, "[fin #{stamp}] "])
{r, _} = converge.(&String.contains?(&1, "[fin #{stamp}] "), 10_000)
ok.(r == :ok, "la edición después de la pausa llega")

step.("I. limpieza: borrar nuestras marcas (mitad desde cada lado)")
del_mark.(on_pc, node(), "[laptop #{stamp}] ")
del_mark.(on_pi, pi, "[pi #{stamp}] ")
del_mark.(on_pc, node(), "[fin #{stamp}] ")
{r, _} = converge.(&(not String.contains?(&1, stamp)), 10_000)
ok.(r == :ok, "marcas de prueba borradas en ambos lados")

step.("J. mensaje de conexión: lo escribe LA PI al final del documento y se queda")
msg = (case System.get_env("MSG") do m when m in [nil, ""] -> "Me conecté desde #{pi}"; m -> m end) <> "\n"
cur = :erpc.call(pi, Doc, :text, [])
# en una línea propia: si el documento no termina en salto de línea, se antepone uno
line = if cur == "" or String.ends_with?(cur, "\n"), do: msg, else: "\n" <> msg
on_pi.(:insert, [String.length(cur), line])
{r, _} = converge.(&String.contains?(&1, msg), 10_000)
ok.(r == :ok, "mensaje de conexión en el documento compartido: #{inspect(msg)}")

all = Agent.get(results, & &1)
IO.puts("\n  #{Enum.count(all, & &1)} de #{length(all)} comprobaciones pasaron (#{div(System.monotonic_time(:millisecond) - t0, 1000)} s)")
System.halt(if Enum.all?(all), do: 0, else: 1)
