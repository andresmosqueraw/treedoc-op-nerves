# Comandos de treedoc-op-nerves

Todos los comandos de Elixir se escriben en **IEx**:
- **en la Pi:** `ssh <IP de la Pi>` abre IEx dentro de ella;
- **en el PC:** `source env.sh && OPDOC_IP=<tu IP> iex -S mix`.

Los índices cuentan **caracteres visibles** desde 0, y un emoji cuenta como 1. Cada posición es un carácter: con `"Hola mundo"`,

```
H o l a ␣ m u n d o
0 1 2 3 4 5 6 7 8 9
```

| Texto | Posiciones |
|---|---|
| `"Hola"` | 4 |
| `"á"`, `"ñ"` | 1 cada uno |
| `"👋🏽"` (emoji con tono de piel) | 1 |
| `" "` (espacio) y `"\n"` (salto de línea) | 1 cada uno |
| un carácter borrado | 0 (ya no cuenta) |

- `Doc.read(5, 5)`, `Doc.delete(5, 5)` y `Doc.replace(5, 5, …)` toman 5 caracteres desde la posición 5, es decir `"mundo"`.
- `Doc.insert(i, texto)` pone el texto **antes** del carácter que está en `i`: `insert(0, …)` al inicio, `insert(4, "!")` da `"Hola! mundo"` e `insert(10, …)` al final (10 es el largo). Por eso `insert` acepta de 0 al largo, e `insert(11, …)` da `{:error, :invalid_index}`.

Cada edición llega a **todos** los nodos conectados. Si una llamada es inválida, devuelve `{:error, motivo}` y **no cambia nada**.

## 1. CRUD del documento

| Comando | Parámetros | Qué hace | Ejemplo | Resultado |
|---|---|---|---|---|
| `Doc.insert(i, texto)` | `i` = posición (no incluida)<br>`texto` = lo que se inserta | **Create**: inserta `texto` en la posición `i` | `Doc.insert(0, "Hola mundo")` | `:ok` → `"Hola mundo"` |
| `Doc.append(texto)` | `texto` = lo que se agrega | **Create**: inserta al final del documento | `Doc.append("!\n")` | `:ok` → `"Hola mundo!\n"` |
| `Doc.text()` | ninguno | **Read**: el documento completo, igual en todos los nodos | `Doc.text()` | `"Hola mundo!\n"` |
| `Doc.read(i, n)` | `i` = posición (incluida)<br>`n` = cuántos caracteres | **Read**: `n` caracteres desde `i` | `Doc.read(5, 5)` | `"mundo"` |
| `Doc.replace(i, n, texto)` | `i` = posición (incluida)<br>`n` = cuántos caracteres<br>`texto` = lo que queda | **Update**: cambia `n` caracteres desde `i` por `texto`, en una sola llamada | `Doc.replace(5, 5, "gente")` | `:ok` → `"Hola gente!\n"` |
| `Doc.delete(i, n)` | `i` = posición (incluida)<br>`n` = cuántos caracteres (por defecto 1) | **Delete**: borra `n` caracteres desde `i` | `Doc.delete(4, 6)` | `:ok` → `"Hola!\n"` |

Errores típicos:

| Ejemplo | Resultado |
|---|---|
| `Doc.insert(99, "x")` (más allá del final) | `{:error, :invalid_index}` |
| `Doc.delete(0, 99)` (más de lo que hay) | `{:error, :invalid_index}` |
| `Doc.insert(0, <<255>>)` (UTF-8 inválido) | `{:error, :invalid_utf8}` |
| `Doc.insert(1.5, "x")` (índice no entero) | `{:error, :badarg}` |

## 2. Red: quién soy y con quién hablo

| Comando | Parámetros | Qué hace | Ejemplo | Resultado |
|---|---|---|---|---|
| `node()` | ninguno | Tu nombre de nodo | `node()` | `:"nerves-9155-308572@192.168.1.105"` |
| `Doc.peers()` | ninguno | Nodos conectados (igual que `Node.list()`) | `Doc.peers()` | `[:"carla@192.168.1.113", ...]` |
| `Doc.connect(ip)` | `ip` = IP de otro nodo | Conecta a todos los nodos que haya en esa IP | `Doc.connect("192.168.1.107")` | `{:ok, [:"nerves-08f5-c026f1@192.168.1.107"]}` o `{:error, :not_found}` |
| `Doc.connect(nombre)` | `nombre` = `"nombre@IP"` | Conecta a un nodo por su nombre completo | `Doc.connect("carla@192.168.1.113")` | `{:ok, [:"carla@192.168.1.113"]}` |
| `Node.set_cookie(cookie)` | `cookie` = átomo, p. ej. `:cpd2026` | Cambia la cookie de este nodo | `Node.set_cookie(:aislado)` | `true` |
| `Node.disconnect(nodo)` | `nodo` = nombre de `Doc.peers()` | Corta el enlace con un nodo | `Node.disconnect(:"carla@192.168.1.113")` | `true` |
| `Node.ping(nodo)` | `nodo` = nombre de `Doc.peers()` | Comprueba si un nodo responde | `Node.ping(:"carla@192.168.1.113")` | `:pong` (responde) o `:pang` (no responde) |
| `Doc.hello()` | ninguno | Pide a todos que reenvíen su historial (sirve para ponerse al día) | `Doc.hello()` | `:ok` |
| `:net_kernel.get_net_ticktime()` | ninguno | Cada cuánto se revisa que un enlace siga vivo; debe ser igual en todos | `:net_kernel.get_net_ticktime()` | `60` |

## 3. Ver qué pasa

| Comando | Parámetros | Qué hace | Ejemplo | Resultado |
|---|---|---|---|---|
| `Doc.status()` | ninguno | Estado de la réplica: reloj vectorial, pares, operaciones en espera, contadores, texto | `Doc.status()` | `%{node: ..., vc: %{...}, peers: [...], waiting: [], text: "..."}` |
| `Doc.watch()` | ninguno | Imprime el documento cada vez que alguien lo cambia | `{:watching, pid} = Doc.watch()` | `{:watching, #PID<...>}` |
| `Process.exit(pid, :kill)` | `pid` = el de `Doc.watch()` | Detiene el `watch` | `Process.exit(pid, :kill)` | `true` |
| `Doc.history()` | ninguno | Todas las operaciones aplicadas, en orden, con quién las hizo | `Doc.history() \|> Enum.take(-3)` | las 3 últimas (`%{op: :ins, from: ..., ch: "a", ...}`) |
| `Doc.debug()` | ninguno | Cada carácter con su posición en el árbol, incluidos los borrados | `Doc.debug()` | `[{[{1, 1, :"..."}], "H", false}, ...]` (`true` = borrado) |

## 4. Operar en la Pi de otro, sin entrar a ella

`:erpc.call(nodo, Modulo, :funcion, [args])` ejecuta la función **dentro de ese nodo**.

| Comando | Qué hace | Ejemplo |
|---|---|---|
| `[otro \| _] = Doc.peers()` | Guarda en `otro` el primer nodo conectado | `[otro \| _] = Doc.peers()` |
| `:erpc.call(otro, :erlang, :node, [])` | Confirma con quién hablas | → `:"carla@192.168.1.113"` |
| `:erpc.call(otro, Doc, :text, [])` | Lee su copia del documento; debe ser igual a la tuya | `:erpc.call(otro, Doc, :text, []) == Doc.text()` → `true` |
| `:erpc.call(otro, Doc, :insert, [0, "x"])` | Inserta desde su nodo | → `:ok` |
| `:erpc.call(otro, Doc, :delete, [0, 1])` | Borra desde su nodo | → `:ok` |

Esto solo funciona con nodos que tengan el módulo `Doc`, es decir, los nuestros. En los de otros grupos se usa su propia API, por ejemplo `:erpc.call(n, Crdt, :text, [])` en treedoc o `:erpc.call(n, CpdDoc, :texto, [])` en el de Carla.

## 5. Terminal (fuera de IEx)

| Comando | Parámetros | Qué hace | Ejemplo |
|---|---|---|---|
| `ssh <IP>` | `<IP>` = IP de la Pi | Abre IEx dentro de la Pi (para salir: `exit`) | `ssh 192.168.1.105` |
| `ssh <IP> '<código>'` | `<IP>` = IP de la Pi<br>`<código>` = una línea de Elixir | Ejecuta una línea de Elixir en la Pi sin abrir IEx | `ssh 192.168.1.105 'Doc.text()'` |
| `scripts/pi.sh [IP]` | `[IP]` = IP de la Pi (opcional) | Busca la Pi, prueba que es ella la que se conecta y hace las pruebas PC ↔ Pi | `MSG="Hola, soy Andrés" scripts/pi.sh` |
| `./fw.sh` | SSID y clave del wifi | Compila el firmware de la Pi | `NERVES_WIFI_SSID="cpd2026" NERVES_WIFI_PASSPHRASE="..." ./fw.sh` |
| `./fw.sh burn` | SSID y clave del wifi | Compila y graba la microSD (borra `/root`, así que la Pi vuelve con otro nombre) | `NERVES_WIFI_SSID=... NERVES_WIFI_PASSPHRASE=... ./fw.sh burn` |
| `./fw.sh upload <IP>` | `<IP>` = IP de la Pi | Compila y actualiza la Pi por wifi (conserva documento y nombre) | `NERVES_WIFI_SSID=... NERVES_WIFI_PASSPHRASE=... ./fw.sh upload 192.168.1.105` |
| `iex -S mix` | variables `OPDOC_*` | Un nodo en el PC | `source env.sh && OPDOC_IP=192.168.1.138 OPDOC_NODES=192.168.1.105 iex -S mix` |
| `mix test` | ninguno | Corre las pruebas (37) | `source env.sh && mix test` |
| `scripts/interop_all.sh` | carpetas de los otros repos | Prueba de 8 nodos con las implementaciones de los otros grupos | ver el encabezado del script |

Siempre que recompiles el firmware, pásale `NERVES_WIFI_SSID` y `NERVES_WIFI_PASSPHRASE`. Si no, la Pi arranca sin wifi.

### Variables para el nodo del PC

| Variable | Qué hace | Ejemplo |
|---|---|---|
| `OPDOC_IP` | IP con la que se anuncia el nodo | `OPDOC_IP=192.168.1.138` |
| `OPDOC_NAME` | Comienzo del nombre: queda `<nombre>-<época>@IP`. En la Pi se pasa a `./fw.sh` al compilar | `OPDOC_NAME=andres-david ./fw.sh upload 192.168.1.105` |
| `OPDOC_NODES` | IPs o nombres a los que conectarse al arrancar, separados por comas | `OPDOC_NODES=192.168.1.105,192.168.1.107` |
| `OPDOC_COOKIE` | Cookie (por defecto `cpd2026`, la de la clase) | `OPDOC_COOKIE=practica` |
| `OPDOC_DATA_DIR` | Carpeta del historial | `OPDOC_DATA_DIR=/tmp/piA` |
| `OPDOC_MDNS=off` | Sin descubrimiento por mDNS | |
| `OPDOC_MULTICAST=off` | Sin el anuncio UDP del contrato | |
| `OPDOC_SCAN=on` | Busca nodos en toda la subred /24 | |

## 6. Práctica en el PC (dos "Pis" falsas)

Usan la cookie `practica`, así que no se mezclan con los nodos de la clase.

```
# Terminal 1
cd "/home/andrew/Documents/docs/2-resolver-problema/university/concurrency-paralelism-distribution/tareas/distribucion/Proyecto Distribución/mi-repo/treedoc-op-nerves" && source env.sh && OPDOC_IP=127.0.0.1 OPDOC_NAME=piA OPDOC_COOKIE=practica OPDOC_DATA_DIR=/tmp/piA OPDOC_MDNS=off OPDOC_MULTICAST=off iex -S mix

# Terminal 2
cd "/home/andrew/Documents/docs/2-resolver-problema/university/concurrency-paralelism-distribution/tareas/distribucion/Proyecto Distribución/mi-repo/treedoc-op-nerves" && source env.sh && OPDOC_IP=127.0.0.1 OPDOC_NAME=piB OPDOC_COOKIE=practica OPDOC_DATA_DIR=/tmp/piB OPDOC_MDNS=off OPDOC_MULTICAST=off OPDOC_NODES=127.0.0.1 iex -S mix
```

Ejercicios:
1. Escribe en A (`Doc.insert(0, "Hola")`) y lee en B (`Doc.text()`).
2. En los dos a la vez: `Doc.replace(0, 4, "Chao")` en A y `Doc.replace(0, 4, "Adiós")` en B. Al final el texto es igual en ambos.
3. Partición y reconexión. Solo con `Node.disconnect`, B vuelve a conectarse en 5 s como mucho, así que primero cambia la cookie de A:
   ```elixir
   # en A: aislarse
   Node.set_cookie(:aislado)
   for n <- Node.list(), do: Node.disconnect(n)
   Doc.peers()                    # []

   # editar en los dos por separado
   Doc.insert(0, "offline ")      # en A
   Doc.insert(0, "soloB ")        # en B
   Doc.text()                     # en cada uno: distintos

   # en A: volver
   Node.set_cookie(:practica)     # en clase: :cpd2026
   Doc.connect("127.0.0.1")       # en clase: la IP de otro nodo
   Doc.text()                     # en los dos: iguales
   ```
4. Usa `Doc.watch()` en B mientras escribes en A.
