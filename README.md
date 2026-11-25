# treedoc-op-nerves: documento distribuido con Treedoc op-based sobre Raspberry Pi (ISIS-4218 CPD, `p_dist`)

**Autores:** Andres Felipe Mosquera Hernandez y David Alejandro Rey Contreras

Editor de texto colaborativo **sin servidor central**. Cada nodo (Raspberry Pi con Nerves, o un computador) guarda la réplica **completa** del documento y se comunica con los demás **solo por broadcast**.

- **CRDT:** Treedoc (Preguiça, Marquès, Shapiro y Leția, ICDCS 2009), **op-based** (CmRDT, Shapiro et al. 2011 §2.4). Cada paso del PosID lleva su desambiguador, y la regla de inserción produce el mismo árbol que Fugue (Weidner y Kleppmann 2023), así que **no intercala** texto concurrente.
- **Entrega:** causal con relojes vectoriales (CBCAST, Birman 1991) y fiable (reenvío de cada operación y del historial en `nodeup` y `hello`).
- **Interoperable** con las parejas op-based del curso (`fepecas/treedoc`, `treedoc-nerves`). Habla su contrato (`docs/INTEGRATION.md` de su repositorio), implementado a partir de esa documentación y no de su código. Probado con su código sin modificar: ver [Interoperabilidad](#interoperabilidad).

Hay una versión state-based anterior en otro repo, `pdoc`; no comparte documento con este.

## Uso rápido (IEx, o `ssh` a la Pi)

```elixir
# CRUD (cada llamada devuelve :ok, el texto o {:error, motivo}; con error no cambia nada)
Doc.insert(0, "Hola mundo")    # Create: inserta en el índice visible
Doc.append("fin\n")            # Create: inserta al final
Doc.text()                     # Read: el documento (igual en todos los nodos)
Doc.read(0, 4)                 # Read: 4 caracteres desde el índice 0 -> "Hola"
Doc.replace(5, 5, "gente")     # Update: los 5 caracteres desde el 5 pasan a ser "gente", en UNA llamada
Doc.delete(4, 6)               # Delete: borra 6 caracteres desde el índice 4
Doc.status()                   # reloj vectorial, operaciones en espera, pares, contadores
Doc.debug()                    # cada átomo con su PosID y si es tombstone
Doc.history()                  # todas las operaciones aplicadas, en orden
Doc.peers()                    # nodos conectados
Doc.connect("172.20.10.4")     # conexión explícita por IP (pregunta a epmd qué nodos hay) o por nombre completo
Doc.watch()                    # imprime el documento cada vez que cambia
Doc.hello()                    # pide a todos que reenvíen su historial
```

En el host: `source env.sh && OPDOC_IP=<tu IPv4> iex -S mix`.

## Compilar y quemar el firmware (Raspberry Pi 4)

```bash
source env.sh                                      # deps/_build fuera de la ruta con espacio
NERVES_WIFI_SSID="red" NERVES_WIFI_PASSPHRASE="clave" ./fw.sh          # solo compila
NERVES_WIFI_SSID="red" NERVES_WIFI_PASSPHRASE="clave" ./fw.sh burn     # compila y escribe la microSD
./fw.sh upload <ip>                                # actualiza una Pi por SSH (conserva /root)
ssh <ip>                                           # IEx en la Pi
```

`env.sh` explica los requisitos del host: los paquetes `erlang-ssh` y `erlang-sasl` en Arch, y `fwup` 1.12 o superior.

**Al reflashear con `burn`** se borra `/root`, y con él el log y la época. La Pi vuelve con un **nombre nuevo** (`<hostname>-<época>@IP`), recibe el documento de los demás y sus ediciones nuevas se aceptan (prueba D9). Con `upload`, `/root` se conserva y el nombre también.

## Configuración

| Variable / clave | Por defecto | Qué hace |
|---|---|---|
| `OPDOC_NAME` / `:name` | hostname | Base del nombre del nodo, que queda `<base>-<época>@IP` |
| `:epoch` | `true` | Época aleatoria guardada junto al log (`<data_dir>/opdoc/epoch`) |
| `OPDOC_COOKIE` | `cpd2026` | Cookie del curso |
| `:dist_ports` | `{4218, 4228}` | Puertos de la distribución (contrato). Abrir también el 4369 (epmd) |
| `OPDOC_NODES` | `""` | Conexión explícita: IPs o nombres completos separados por comas |
| `OPDOC_MDNS=off` | mDNS activo | Descubrimiento mDNS (`_opdoc._tcp`) |
| `OPDOC_MULTICAST=off` | activo | Anuncio UDP del contrato (`233.252.1.32:45892`, `"crdt-treedoc-1 <nodo>"`) |
| `OPDOC_SCAN=on` | activo en la Pi | Barrido de la subred (/24): pregunta a epmd de cada IP |
| `OPDOC_IP`, `OPDOC_DATA_DIR` | — | Solo en el host |

## Arquitectura

```
Doc.Supervisor (one_for_one)
 ├─ Doc.Replica  = Crdt.Replica   siempre activo: se edita aunque no haya red (CAP: disponible)
 └─ Doc.NetSup (rest_for_one)
      ├─ Doc.Net                   vigila la IPv4 y (re)arranca la pila de red
      └─ Doc.Stack                 Doc.Dist (nombre, cookie, puertos) → Doc.Discovery (mDNS, explícito, barrido) → Doc.Multicast
```

| Módulo | Qué es |
|---|---|
| `Doc.Treedoc` | CRDT puro: `new`, `prepare` (solo en el origen), `effect` (en todas las réplicas), `value` |
| `Doc.Causal` | Entrega causal pura: duplicado, entregable o en espera; vaciado del buffer; `missing/2` |
| `Doc.Wire` | El contrato: nombre `Crdt.Replica` y validación de todo lo que llega de la red |
| `Doc.Replica` | El actor dueño del documento, el reloj, el buffer y el historial |
| `Doc.Bcast` | El **único** lugar que envía a otro nodo: `GenServer.cast` a `Crdt.Replica` en `Node.list()` |
| `Doc.Storage` | Log de operaciones con `fsync` (`/root` en la Pi) |
| `Doc.Dist`, `Doc.Discovery`, `Doc.Multicast`, `Doc.Net` | Red: nombre con época, puertos, descubrimiento y cambios de IP |

## Concurrencia (P3)

- **Sin memoria compartida ni locks.** `Doc.Replica` es un actor. Las ediciones locales y las operaciones remotas se serializan en su buzón.
- **Atomicidad de una edición local.** Un solo `handle_call` hace todo en este orden: valida, numera cada grafema con el reloj, escribe el log con **un** `fsync`, aplica y transmite. Si el disco falla, no se aplica ni se envía nada y el reloj no avanza.
- **Causalidad.** Una operación se aplica solo cuando ya se aplicó todo lo que su reloj dice que la precede. Si no, espera en el buffer (como máximo 50 000).
- **Duplicados.** Se descartan por el reloj (`m[from] <= vc[from]`), así que reenviar es seguro.
- **Pérdidas o emisor que cae.** Cada operación aplicada se reenvía una vez, y el historial completo se reenvía en `nodeup` y `hello`.
- **Sin deadlocks.** Entre nodos solo hay `cast` asíncronos.
- **Entrada hostil.** `Doc.Wire.parse/1` ignora los mensajes mal formados o enormes. El nombre de un paquete multicast se valida antes de convertirlo en átomo.

## Persistencia

- **Log:** una línea por operación (`term_to_binary` + Base64). Al arrancar se reaplica, y así vuelven el documento, el reloj y el historial.
- **Última línea cortada** (corte de luz): se **trunca**. Esa operación nunca salió del nodo, porque nada se envía antes del `fsync`.
- **Línea dañada en medio:** se conserva el prefijo válido, que es un estado causalmente consistente, y el log dañado se aparta (`ops.log.corrupt-*`). Además se olvida la época, así que el nombre siguiente es nuevo y nunca se reutiliza un número de operación; los demás reenvían el resto. Si la distribución ya estaba activa, el nombre no puede cambiar en ese momento: las ediciones locales devuelven `{:error, :restart_required}` hasta reiniciar el nodo.

## Pruebas

`source env.sh && mix test`: **33 en verde** (2 propiedades y 31 tests, unos 30 s).

| Archivo | Qué cubre |
|---|---|
| `treedoc_test` | Escenario de las figuras 3 y 4 del paper, `compare`, pegado balanceado (profundidad log n), tombstones, grafemas, hijo antes que el padre, propiedad de conmutatividad |
| `fugue_test` | **No intercalado (plan §2.2):** D4 letra por letra ("Hello Alice Charlie!"), D4b (anteponer, "abcXYZ"), Fugue A.1 hacia adelante y hacia atrás en **todas** las órdenes de entrega, y una **propiedad**: trazas aleatorias con 3 réplicas, entrega desordenada por `Doc.Causal`, texto igual al de una referencia de Fugue (Algoritmo 1) |
| `causal_test` | Duplicado, espera y entrega; vaciado en cadena; todas las permutaciones de una historia causal |
| `wire_test` | Mensajes válidos y 19 formas inválidas; paquetes multicast |
| `cluster_test` | Nodos `:peer` reales: broadcast, escrituras simultáneas, reenvío en cadena A-B-C, partición, reinicio desde disco, nodo atrasado, mensajes desordenados y duplicados, basura de la red, argumentos inválidos |
| `dist_test` | La época sobrevive al reinicio y cambia al reflashear; puertos 4218–4228; `Doc.connect(ip)` hacia un nodo con otro nombre |
| `storage_test` | Última línea cortada (se trunca), línea dañada en medio (prefijo, época nueva) y lo mismo con la distribución activa (ediciones bloqueadas) |

### Interoperabilidad

```bash
TREEDOC_DIR=<checkout de fepecas/treedoc> scripts/interop.sh
```

Copia su repositorio **sin modificarlo** a una carpeta temporal, lo compila y levanta 3 nodos suyos y 3 nuestros en `127.0.0.1`. Después `scripts/interop.exs` los maneja a todos por sus API públicas:

| Escenario | Qué prueba |
|---|---|
| I1 | Malla completa |
| I2 | Ediciones alternadas entre las dos implementaciones |
| I3 | 6 escritores simultáneos en el mismo índice |
| I4 | 200 operaciones al azar |
| I5 | Pegado nuestro de 420 caracteres junto a su tecleo |
| I6 | Partición y reconexión |
| I7 | Reinicio de uno nuestro desde disco |
| I8 | Un nodo suyo aislado que se pone al día |

Criterio: el mismo texto en los 6 nodos.

## Enunciado → evidencia (P1–P8)

| | Exigencia | Cómo | Evidencia |
|---|---|---|---|
| P1 | Documento distribuido sobre Raspberry Pi | Firmware Nerves `rpi4` con la app `:opdoc` | Demo con 2 o más Pis |
| P2 | Sin servidor central | Todos los nodos son pares; descubrimiento sin directorio | D5: apagar cualquier nodo |
| P3 | Problemas de concurrencia | Actor, atomicidad, causalidad, idempotencia (arriba) | `cluster_test`, `causal_test` |
| P4 | CRDT con el estado completo en cada cliente | Réplica completa de Treedoc en cada nodo | `Doc.text()` igual en todos |
| P5 | Descubrimiento explícito o dinámico | **Ambos:** mDNS, multicast y barrido; `Doc.connect(ip)` y `OPDOC_NODES` | `dist_test`, D1 |
| P6 | Toda la comunicación por broadcast | Solo `Doc.Bcast.broadcast/1` envía a otros nodos | Revisión de código |
| P7 | Enviar las modificaciones locales | `prepare` → log → `effect` → broadcast, una operación por grafema | `cluster_test`, D2 |
| P8 | Recibir las de otros | Entrega causal → `effect`; converge (SEC, Shapiro 2011, Teorema 2.2) | `cluster_test`, `fugue_test`, `interop.sh` |

## Limitaciones

- **Tombstones:** no hay recolección de basura. Los caracteres borrados siguen en el árbol y en el historial, que crecen sin límite. Para la demo, con cientos o miles de operaciones, es aceptable.
- **Profundidad del árbol:** al teclear letra por letra al final, el camino crece un paso por carácter. Los pegados se balancean (log n). No se usa el balanceo de Preguiça §4.1 porque rompería la equivalencia con Fugue.
- **Reenvío del historial completo:** en cada `nodeup` y `hello` se envía todo el historial, que es O(historial) por conexión. Es simple y correcto; en una red grande convendría un intercambio de relojes.
- **`Bcast` nunca descarta:** en un enlace muy malo, la réplica puede esperar a que se vacíe el buffer TCP. A diferencia de pdoc, aquí perder una operación bloquearía las siguientes de ese nodo hasta el próximo reenvío del historial.
- **`prevent_overlapping_partitions`:** se desactiva en `rel/vm.args.eex` (release de la Pi). Con `mix run` en el host sigue activo, así que en una partición `global` puede cortar conexiones de más; el descubrimiento las rehace en segundos.
- **Reinicio en caliente bajo QEMU:** `nerves_runtime` 0.13.13 tiene un bug en ese caso. En la Pi real se resuelve apagando y encendiendo.

## Referencias

Preguiça et al. 2009 (Treedoc); Leția, Preguiça y Shapiro 2009; Shapiro et al. 2011 (CRDT, Teorema 2.2); Baquero, Almeida y Shoker 2017 (*pure op-based*); Birman, Schiper y Stephenson 1991 (CBCAST); Kleppmann et al. 2019 (intercalado); Weidner y Kleppmann 2023 (Fugue).
