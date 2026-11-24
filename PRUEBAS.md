# Pruebas a mano, paso a paso

Para la lista de comandos, ver `COMANDOS.md`.

## Antes de empezar

1. **Entra a la Pi.** En la terminal del PC, conectado a `cpd2026`:
   ```
   nmap -n -p 4369 --open --script epmd-info "$(ip -o -4 addr show wlan0 | awk '{print $4}' | sed 's#\.[0-9]*/.*#.0/24#')" | grep -E "scan report|nerves-9155"
   ssh <IP de la Pi>
   ```
   Quedas en IEx dentro de la Pi. Todo lo que está en bloques `elixir` se escribe ahí.

   Para practicar sin la Pi, usa las dos Pis falsas del PC (sección 6 de `COMANDOS.md`) y haz lo mismo en sus IEx.
2. **Para las pruebas con dos Pis**, guarda la otra en una variable:
   ```elixir
   Doc.peers()                   # mira la lista y elige una
   otro = hd(Doc.peers())        # o: otro = :"nerves-08f5-c026f1@192.168.1.107"
   ```
3. **`append`, `read` y `replace`** funcionan en la Pi solo después de `./fw.sh upload <IP>`. Hasta entonces, haz las pruebas que usan `insert`, `delete` y `text`.

> **El documento de `cpd2026` es de toda la clase.** Cada prueba termina con un paso de **limpieza** que borra solo lo que tú escribiste. No borres texto ajeno.

---

## A. Una sola Pi

### 1. Insertar al inicio
```elixir
Doc.insert(0, "x")
Doc.read(0, 1)                # "x"
Doc.delete(0, 1)              # limpieza
```
**Debe pasar:** `:ok`, y la `x` aparece al inicio.

### 2. Insertar al final
```elixir
n = String.length(Doc.text())
Doc.insert(n, "x")
Doc.read(n, 1)                # "x"
Doc.delete(n, 1)              # limpieza
```
**Debe pasar:** la `x` queda en la última posición. `Doc.append("x")` hace lo mismo.

### 3. Leer cero caracteres
```elixir
Doc.read(0, 0)                # ""
```

### 4. Entradas inválidas
Antes de empezar, guarda el texto: `antes = Doc.text()`. Luego, una por una:
```elixir
Doc.insert(-1, "x")           # {:error, :invalid_index}
Doc.insert(9999, "x")         # {:error, :invalid_index}
Doc.insert(1.5, "x")          # {:error, :badarg}
Doc.delete(0, 99999)          # {:error, :invalid_index}
Doc.replace(0, 1, <<255>>)    # {:error, :invalid_utf8}
Doc.read(5, -1)               # {:error, :invalid_index}
Doc.text() == antes           # true: nada cambió
```

### 5. Grafemas (letras con tilde y emojis)
```elixir
Doc.insert(0, "ñ👍🏽👨‍👩‍👧")
Doc.read(0, 3)                # "ñ👍🏽👨‍👩‍👧"
Doc.read(1, 1)                # "👍🏽"  (un emoji cuenta como 1)
Doc.delete(0, 3)              # limpieza: borra los 3
```
**Debe pasar:** cada emoji cuenta como **un** carácter, aunque ocupe varios bytes. La familia 👨‍👩‍👧 también cuenta como uno.

### 6. Update (reemplazar)
```elixir
Doc.insert(0, "gato ")
Doc.replace(0, 4, "perro")
Doc.read(0, 6)                # "perro "
Doc.delete(0, 6)              # limpieza
```
**Debe pasar:** "gato" desaparece y en su lugar queda "perro", en una sola llamada.

### 7. Muchos datos
```elixir
n = String.length(Doc.text())
Doc.append(String.duplicate("abc", 1000))
String.length(Doc.text()) - n # 3000
Doc.delete(n, 3000)           # limpieza
String.length(Doc.text()) == n   # true
```
**Debe pasar:** se agregan 3000 caracteres en una llamada, y en las otras Pis también aparecen y desaparecen.

### 8. Mensaje mal formado
Mándate a ti mismo un mensaje de red inválido:
```elixir
antes = Doc.text()
pid = Process.whereis(Crdt.Replica)
GenServer.cast(Crdt.Replica, {:remote, %{}})
GenServer.cast(Crdt.Replica, {:remote, %{op: :ins, ch: 33}})
Doc.status().msgs_ignored     # aumentó en 2
Process.whereis(Crdt.Replica) == pid   # true: la réplica no se cayó
Doc.text() == antes           # true
```

### 9. Caída de la réplica
```elixir
antes = Doc.text()
pid = Process.whereis(Crdt.Replica)
Process.exit(pid, :kill)
Process.sleep(2000)
Process.whereis(Crdt.Replica) == pid   # false: es un proceso nuevo
Doc.text() == antes           # true: lo recuperó de disco
Doc.insert(0, "x"); Doc.delete(0, 1)   # sigue editando
```
Hazla **una sola vez seguida**. Si se cae 3 veces en 5 s, el supervisor se rinde.

---

## B. Dos Pis

Para las pruebas "a la vez", una persona cuenta en voz alta ("3, 2, 1, ya") y las dos presionan Enter juntas. Si estás solo, el bloque de la prueba 12 hace las dos ediciones a la vez desde una sola Pi.

### 10. Una edición llega a la otra Pi
**En A:**
```elixir
Doc.insert(0, "hola ")
```
**En B:**
```elixir
Doc.read(0, 5)                # "hola "
```
**Limpieza (en cualquiera):** `Doc.delete(0, 5)`

**Debe pasar:** B la ve en menos de un segundo.

### 11. Las dos escriben en el mismo lugar a la vez
1. **En A y en B a la vez:** A escribe `Doc.insert(0, "AAA ")` y B escribe `Doc.insert(0, "BBB ")`.
2. **En las dos:** `Doc.read(0, 8)`.
3. **Limpieza (solo en una):** `Doc.delete(0, 8)`.

**Debe pasar:** las dos muestran lo mismo, `"AAA BBB "` o `"BBB AAA "`, con cada palabra entera y sin letras mezcladas.

### 12. Lo mismo, desde una sola Pi
```elixir
otro = hd(Doc.peers())
a = Task.async(fn -> Doc.insert(0, "AAA ") end)
b = Task.async(fn -> :erpc.call(otro, Doc, :insert, [0, "BBB "]) end)
Task.await(a); Task.await(b)
Process.sleep(500)
Doc.read(0, 8)                                  # "AAA BBB " o "BBB AAA "
Doc.text() == :erpc.call(otro, Doc, :text, [])  # true
Doc.delete(0, 8)                                # limpieza
```
`:erpc.call(otro, Doc, ...)` funciona solo si la otra Pi es de las nuestras. Para otras implementaciones, ver la tabla de la sección C.

### 13. Las dos borran lo mismo a la vez
1. **En A:** `Doc.insert(0, "Z")`.
2. **En las dos:** comprueben que `Doc.read(0, 1)` da `"Z"` y anoten `n = String.length(Doc.text())`.
3. **En A y en B a la vez:** `Doc.delete(0, 1)`.
4. **En las dos:**
   ```elixir
   String.length(Doc.text()) == n - 1    # true: se borró UN carácter, no dos
   ```

**Debe pasar:** la `Z` desaparece una sola vez, y el resto del documento queda igual.

### 14. Las dos reemplazan la misma palabra a la vez
1. **En A:** `Doc.insert(0, "gato ")`. Las dos comprueben `Doc.read(0, 5)`, que debe dar `"gato "`.
2. **A la vez:** A escribe `Doc.replace(0, 4, "Chao")` y B escribe `Doc.replace(0, 4, "Adiós")`.
3. **En las dos:** `Doc.read(0, 10)`. Debe dar `"ChaoAdiós "` o `"AdiósChao "`.
4. **Limpieza (solo en una):** `Doc.delete(0, 10)`.

**Debe pasar:** "gato" desaparece, quedan las dos palabras nuevas enteras, y las dos Pis muestran el mismo texto.

### 15. Partición y reconexión
Un `Node.disconnect` solo dura unos segundos, porque el descubrimiento reconecta automáticamente. Para aislar la Pi de verdad, **cambia su cookie** antes de desconectarla: así nadie puede volver a conectarse. El `ssh` no se afecta.

1. **En A, aislarse:**
   ```elixir
   Node.set_cookie(:aislado)
   for n <- Node.list(), do: Node.disconnect(n)
   Doc.peers()                  # []
   ```
2. **Editar por separado.** En A: `Doc.insert(0, "soloA ")`. En B: `Doc.insert(0, "soloB ")`.
3. **Comprobar que están separadas:** en A, `Doc.read(0, 6)` da `"soloA "`; en B, `Doc.read(0, 6)` da `"soloB "`.
4. **En A, volver** (con la IP de B):
   ```elixir
   Node.set_cookie(:cpd2026)
   Doc.connect("<IP de B>")     # {:ok, [...]}
   Process.sleep(2000)
   Doc.read(0, 12)              # "soloA soloB " o "soloB soloA "
   ```
5. **En B:** `Doc.read(0, 12)`, que debe dar lo mismo que A.
6. **Limpieza (solo en una):** `Doc.delete(0, 12)`.

En las Pis de práctica, la cookie para volver es `:practica` y la IP es `"127.0.0.1"`.

### 16. Nodo atrasado (se apaga y vuelve)
1. **En A:** desconecta la energía de la Pi.
2. **En B:** `Doc.insert(0, "mientras A estaba apagada ")`.
3. **En A:** conecta la energía y espera unos 40 s. Busca su IP otra vez (puede cambiar) y entra con `ssh`.
4. **En A:** `Doc.read(0, 26)`, que debe dar `"mientras A estaba apagada "`.
5. **Limpieza:** `Doc.delete(0, 26)`.

**Debe pasar:** A se conecta sola al arrancar y recibe lo que se perdió.

### 17. Reinicio sin perder el documento
1. **En A:** `antes = Doc.text()`, y anota `node()`.
2. Desconecta la energía de A, conéctala otra vez, espera unos 40 s y entra de nuevo con `ssh`.
3. **En A:**
   ```elixir
   node()                       # el mismo nombre que antes
   Doc.peers()                  # vuelve a estar conectada
   ```
4. Compara `Doc.text()` con lo que había antes. Es el mismo, más lo que hayan escrito los demás mientras tanto.

### 18. Enlace quieto
1. **En las dos:** `Doc.peers()`, que debe incluir a la otra.
2. No escriban nada durante 2 minutos.
3. **En las dos:** `Doc.peers()` otra vez.

**Debe pasar:** siguen conectadas. Antes, con `net_ticktime` distinto, se cortaba a los ~12 s.

### 19. Las dos copias son iguales
```elixir
otro = hd(Doc.peers())
Doc.text() == :erpc.call(otro, Doc, :text, [])   # true
```

---

## C. En clase, con las Pis de todos (8 o más)

Cada implementación tiene su propia API:

| Implementación | Ver nodos | Leer | Escribir | Borrar |
|---|---|---|---|---|
| Nuestra (`Doc`) | `Doc.peers()` | `Doc.text()` | `Doc.insert(0, "x")` | `Doc.delete(0, 1)` |
| treedoc y treedoc-nerves (`Crdt`) | `Node.list()` | `Crdt.text()` | `Crdt.insert(0, "x")` | `Crdt.delete(0, 1)` |
| Carla (`CpdDoc`) | `Node.list()` | `CpdDoc.texto()` | `CpdDoc.insertar(0, "x")` | `CpdDoc.borrar(0, 1)` |

**Comparar tu copia con la de todos**, desde nuestra Pi. Sirve para cualquier implementación:
```elixir
for n <- Doc.peers() do
  t = Enum.find_value([{Doc, :text}, {Crdt, :text}, {CpdDoc, :texto}], fn {m, f} ->
        try do :erpc.call(n, m, f, []) catch _, _ -> nil end
      end)
  {n, t == Doc.text()}
end
# [{:"carla@192.168.1.113", true}, {:"nerves-08f5-c026f1@192.168.1.107", true}, ...]
```
Si todos dan `true`, todas las copias son iguales a la tuya.

Una persona coordina ("3, 2, 1, ya") y cada uno usa los comandos de su implementación.

### 20. Todos conectados
1. **Cada uno:** mira sus nodos conectados (`Doc.peers()` o `Node.list()`).

**Debe pasar:** cada uno ve a todos los demás.

### 21. Todos escriben a la vez
1. **A la cuenta de 3, cada uno inserta su nombre y un espacio en el índice 0.** Por ejemplo: `Doc.insert(0, "Andrés ")`, `Crdt.insert(0, "Diego ")`, `CpdDoc.insertar(0, "Carla ")`.
2. **Cada uno:** lee el inicio del documento, por ejemplo `Doc.read(0, 60)` o `String.slice(Crdt.text(), 0, 60)`.
3. **Desde nuestra Pi:** corre el bloque de comparación.
4. **Limpieza:** cada uno borra **su** nombre, buscando su posición:
   ```elixir
   t = Doc.text(); {b, _} = :binary.match(t, "Andrés ")
   Doc.delete(String.length(binary_part(t, 0, b)), 7)
   ```

**Debe pasar:** todas las Pis muestran el mismo orden de nombres, cada nombre entero.

### 22. Todos borran lo mismo a la vez
1. **Una persona:** inserta `"Z"` en el índice 0.
2. **Cada uno:** comprueba que su documento empieza con `Z` y anota su longitud: `n = String.length(Doc.text())`.
3. **A la cuenta de 3, todos borran el carácter 0:** `Doc.delete(0, 1)`, `Crdt.delete(0, 1)` o `CpdDoc.borrar(0, 1)`.
4. **Cada uno:** `String.length(Doc.text()) == n - 1`, que debe dar `true`.

**Debe pasar:** se borra **una** sola letra, la `Z`, aunque la borraron todos.

### 23. Partición en dos grupos
1. **La mitad de las Pis (grupo 1) se aíslan del resto.** En cada una:
   ```elixir
   Node.set_cookie(:grupo1)
   for n <- Node.list(), do: Node.disconnect(n)
   ```
2. **El grupo 1 se reconecta entre sí** con la IP de otra Pi del grupo 1:
   ```elixir
   Doc.connect("<IP de otra Pi del grupo 1>")    # o Node.connect(:"nombre@IP")
   ```
3. **Cada grupo escribe su nombre**, por ejemplo `Doc.insert(0, "G1 ")` y `Doc.insert(0, "G2 ")`.
4. **Comprobar:** el grupo 1 ve solo `G1`, y el grupo 2 ve solo `G2`.
5. **El grupo 1 vuelve.** En cada una de sus Pis:
   ```elixir
   Node.set_cookie(:cpd2026)
   Doc.connect("<IP de una Pi del grupo 2>")
   ```
6. **Comprobar:** después de unos segundos, todas las Pis ven `G1` y `G2`, en el mismo orden. Corre el bloque de comparación.
7. **Limpieza:** cada grupo borra lo suyo (`Doc.delete(0, 3)` si quedó al inicio; si no, búscalo como en la prueba 21).

### 24. Se apaga una
1. **Una persona:** desconecta la energía de su Pi.
2. **Los demás:** siguen escribiendo (`Doc.insert(0, "sin X ")`).
3. **Comprobar:** los demás siguen funcionando, y en sus nodos conectados ya no aparece la Pi apagada.
4. **La persona:** enciende su Pi, espera unos 40 s, entra de nuevo y lee el documento. Debe tener todo lo que se escribió mientras estaba apagada.
5. **Limpieza:** se borra lo escrito.

### 25. Se apaga la mitad
Igual que la 24, pero con la mitad de las Pis apagadas a la vez. Al encenderlas, todas deben terminar iguales; compruébalo con el bloque de comparación.

### 26. Una Pi nueva entra tarde
1. **Una persona** graba su Pi de cero con `./fw.sh burn`. Vuelve con un nombre nuevo y sin documento.
2. **La enciende** cuando los demás ya tienen el documento avanzado.
3. **En esa Pi:** `Doc.text()`, que debe ser igual al de los demás después de unos segundos. Luego `Doc.insert(0, "nueva ")`, que debe llegar a todos.
4. **Limpieza:** `Doc.delete(0, 6)`.

### 27. Enlace quieto con todos
1. Nadie escribe durante 2 minutos.
2. **Cada uno:** mira sus nodos conectados.

**Debe pasar:** todos siguen conectados con todos.

### 28. Al final: todas las copias iguales
**Desde cada Pi nuestra:** corre el bloque de comparación. **Debe pasar:** todo `true`.
