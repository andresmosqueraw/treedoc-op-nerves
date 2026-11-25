# Pitch: treedoc-op-nerves (3 minutos)

Andres Felipe Mosquera Hernandez y David Alejandro Rey Contreras

Unas 430 palabras habladas, que a ritmo tranquilo son unos 3 minutos. Cada bloque dice cuánto dura y quién habla.

Glosario: cada concepto tiene **una sola palabra**, y cada palabra significa **una sola cosa**.

| Palabra | Significa | No se dice |
|---|---|---|
| **nodo** | una máquina que corre la solución | par, cliente, máquina |
| **réplica** | el proceso del nodo, dueño del documento | actor, proceso |
| **documento** | el contenido compartido | texto, copia |
| **letra** | una unidad del documento | carácter |
| **posición** | dónde está una letra | lugar |
| **usuario** | quien edita | persona |
| **edición** | una llamada del usuario: `insert`, `replace`, `delete`… | cambio, modificación |
| **insertar** | agregar letras | escribir |
| **operación** | lo que se envía: la inserción o el borrado de **una** letra | edición remota |
| **mensaje** | cualquier cosa que llega por la red | |
| **llegar** | un mensaje entra a la réplica | recibir |
| **aplicar** | una operación modifica el documento | tocar |
| **enviar** | broadcast a **todos** los nodos conectados | difundir, comunicar, hablarse |
| **reenviar** | enviar una operación que llegó | |
| **historial** | las operaciones aplicadas, en disco | log, disco |
| **guardar** | escribir en el historial | |
| **descubrir** | encontrar otros nodos | encontrarse |
| **conectar** | abrir el enlace con un nodo | reencontrarse, volver |
| **apagarse** | un nodo deja de correr | caerse, reiniciarse |
| **a la vez** | concurrente | simultáneo |
| **inválido** | lo que no cumple el formato | mal formado |
| **terminar con el mismo documento** | converger | dar lo mismo, coincidir |

---

## 0:00 – 0:20 · La solución en una frase (Andres)

Construimos un documento colaborativo **sin servidor central**. Todos los nodos son iguales: cada uno tiene el documento **completo** y puede editar aunque no esté conectado. Al conectarse, todos **terminan con el mismo documento**.

## 0:20 – 0:50 · Descubrir y enviar (Andres)

Los nodos se descubren solos de **tres formas**:
- un anuncio **mDNS**;
- un anuncio **multicast UDP** cada dos segundos;
- un **barrido de la subred**, que pregunta a cada IP qué nodos tiene.

También se puede conectar a mano con `Doc.connect(ip)`. Si cambia la IP de un nodo, se conecta de nuevo solo.

Todo envío sale de **una sola función**, `Doc.Bcast.broadcast`. Enviar siempre es un **broadcast** a todos los nodos conectados.

## 0:50 – 1:25 · El CRDT (David)

El documento es un **Treedoc op-based**. Cada letra vive en un árbol binario y tiene una posición única, que incluye qué nodo la insertó. Por eso dos inserciones a la vez nunca chocan: aplicarlas en cualquier orden termina con el mismo documento. Un borrado solo marca la letra, así que aplicar dos veces el mismo borrado no cambia nada.

Además:
- Si dos usuarios insertan en la misma posición a la vez, lo que insertó cada uno **queda junto**: sus letras no se mezclan.
- Una edición que inserta muchas letras forma un **subárbol balanceado**, y el árbol crece log n en vez de n.

## 1:25 – 2:05 · Concurrencia y fallos (David)

Cada nodo tiene **una réplica**, la única dueña del documento. No hay memoria compartida ni locks: las ediciones y los mensajes que llegan hacen fila en su buzón.

Cada operación lleva su **reloj vectorial**: si llega antes que una operación de la que depende, **espera**; si llega repetida, **se descarta**. Para que ninguna operación se pierda, la réplica reenvía cada operación que aplica, y al conectarse envía todo su historial.

Una edición es **atómica**: se valida, se guarda y **solo después** se envía. Si un nodo se apaga, al encenderse recupera el documento desde su historial, incluso si la última línea quedó cortada.

## 2:05 – 2:40 · Cómo se usa (Andres)

Tenemos un **CRUD completo**: `insert`, `append`, `text`, `read`, `replace` y `delete`. `replace` borra e inserta en **una sola edición**, así ninguna operación que llegue se mete en medio. Una edición inválida devuelve un error y **no cambia nada**.

Cada nodo tiene un nombre con una **época** aleatoria. Si pierde su historial, arranca con un nombre nuevo y nunca reutiliza números de operación.

La réplica valida cada mensaje antes de aplicarlo. Un mensaje inválido se ignora y la réplica sigue funcionando. Para ver qué pasa dentro están `Doc.status()`, `Doc.watch()` y `Doc.history()`.

## 2:40 – 3:00 · Cierre (David)

En resumen: todos los nodos son iguales y tienen el documento completo, se descubren solos, todo lo que envían es broadcast, sobreviven a desconexiones y apagones, y siempre terminan con el mismo documento.

---

## Si hay demo en vivo (opcional, unos 30 s y fuera de los 3 minutos)

Con dos nodos, cada uno en su propia terminal:

```elixir
Doc.peers()                      # nodo A: ya se descubrieron solos
Doc.insert(0, "Hola desde A ")   # nodo A
Doc.text()                       # nodo B: llegaron las operaciones
Doc.replace(0, 4, "Chao")        # nodo B
Doc.text()                       # nodo A: llegaron las operaciones
```

---

## Dónde está cada cosa en el código

Las rutas son relativas a la raíz del repo, y la tabla sigue el orden de los bloques del pitch.

Dos cosas que pueden confundir:
- `Doc.Storage` está en `lib/doc/bcast.ex`, debajo de `Doc.Bcast`. `Doc.Dist`, `Doc.Discovery` y el mDNS están en `lib/doc/cluster.ex`.
- El código está en inglés: `effect` = aplicar, `broadcast` = enviar, `dead` = letra borrada, `ops.log` = historial.

### 0:00 · La solución en una frase
| Lo que se dice | Dónde |
|---|---|
| Sin servidor central; todos los nodos son iguales | `lib/opdoc/application.ex:15`: cada nodo arranca su propia réplica, sin ningún nodo especial |
| Cada nodo tiene el documento completo | `lib/doc/replica.ex:57` (`init`); el documento es `s.doc` |
| Puede editar aunque no esté conectado | `lib/opdoc/application.ex:15`: la réplica no depende de la red (`Doc.NetSup`, línea 20). `lib/doc/replica.ex:256` (`author`) conserva el nombre sin red |
| Al conectarse, terminan con el mismo documento | `lib/doc/replica.ex:305` (`nodeup`): envía el historial |

### 0:20 · Descubrir y enviar
| Lo que se dice | Dónde |
|---|---|
| Anuncio mDNS | `lib/doc/cluster.ex:170` (módulo), `:176` (`announce`), `:190` (`query`) |
| Multicast UDP cada dos segundos | `lib/doc/multicast.ex:24` (`@every 2_000`), `:70` (anunciar), `:76` (escuchar y conectar) |
| Barrido de la subred, que pregunta a cada IP qué nodos tiene | `lib/doc/cluster.ex:351` (`:scan`), `:373` (`scan`), `:275` (`nodes_at`, pregunta a epmd), `:390` (`subnet_hosts`) |
| Conectar a mano con `Doc.connect(ip)` | `lib/opdoc.ex:56` → `lib/doc/cluster.ex:257` (`to_nodes`) |
| Si cambia la IP, se conecta de nuevo solo | `lib/doc/net.ex:51` (`:check`), `:67–69` (para y arranca la red con la IP nueva), `:153` (escucha wlan0 y eth0) |
| Una sola función, `Doc.Bcast.broadcast`, que envía a todos los conectados | `lib/doc/bcast.ex:19` (función), `:21` (un `cast` a cada nodo de `Node.list()`) |

### 0:50 · El CRDT
| Lo que se dice | Dónde |
|---|---|
| Treedoc op-based | `lib/doc/treedoc.ex` |
| Árbol binario; posición única que incluye qué nodo insertó la letra | `lib/doc/treedoc.ex:156` (`new_pos`: cada paso es `{bit, seq, nodo}`), `:63` (`compare`: orden de las posiciones) |
| Inserciones a la vez nunca chocan | `lib/doc/treedoc.ex:175` (`effect` de inserción) |
| Un borrado solo marca la letra | `lib/doc/treedoc.ex:179` (`effect` de borrado: `dead: true`) |
| Lo que insertó cada usuario queda junto | `lib/doc/treedoc.ex:156` (regla de `new_pos`) y `:111` (`prepare_text`) |
| Subárbol balanceado, log n | `lib/doc/treedoc.ex:131–133` (`balanced`) |

### 1:25 · Concurrencia y fallos
| Lo que se dice | Dónde |
|---|---|
| Una réplica, única dueña del documento | `lib/doc/replica.ex:23` (`use GenServer`), `:28` (registrada como `Crdt.Replica`) |
| Ediciones y mensajes hacen fila en su buzón | `lib/doc/replica.ex:135` (ediciones, `handle_call`) y `:284` (mensajes, `handle_cast`) |
| Cada operación lleva su reloj vectorial | `lib/doc/replica.ex:145` y `:164` (`vc: Map.put(s.vc, me, seq)`) |
| Si llega antes que una de la que depende, espera | `lib/doc/causal.ex:44` (regla), `:68` (`:wait`), `:63` (`receive_msg`) |
| Si llega repetida, se descarta | `lib/doc/causal.ex:41` (`mi <= vi`) |
| Reenvía cada operación que aplica | `lib/doc/replica.ex:353` |
| Al conectarse envía todo su historial | `lib/doc/replica.ex:305` (`nodeup`), `:366` (`send_history`), `:291` (`hello`) |
| Edición atómica: valida, guarda y solo después envía | `lib/doc/replica.ex:267` (`local_ops`): `:268` guarda, `:273` envía, `:278` (si falla el disco, no envía nada) |
| Guardar con `fsync` | `lib/doc/bcast.ex:96–99` (`Doc.Storage.append`) |
| Al encenderse recupera el documento desde su historial | `lib/doc/bcast.ex:117` (`load`), `lib/doc/replica.ex:67` (vuelve a aplicar el historial) |
| Aunque la última línea haya quedado cortada | `lib/doc/bcast.ex:50` (`open`), `:57` (`truncate_torn_tail`) |

### 2:05 · Cómo se usa
| Lo que se dice | Dónde |
|---|---|
| CRUD: `insert`, `append`, `text`, `read`, `replace`, `delete` | `lib/opdoc.ex:31–42` (API) → `lib/doc/replica.ex:135` (insert), `:154` (delete), `:176` (replace), `:205` (append), `:211` (read), `:222` (text) |
| `replace` borra e inserta en una sola edición | `lib/doc/replica.ex:176`: un solo `handle_call` arma los borrados y las inserciones |
| Una edición inválida devuelve un error y no cambia nada | `lib/doc/replica.ex:137` (`:invalid_utf8`), `:208` (`:badarg`), `lib/doc/treedoc.ex:111` y `:143` (`:invalid_index`) |
| Nombre con época aleatoria | `lib/doc/cluster.ex:59` (`base_name`), `:72` (`epoch`), `:81` (aleatoria) |
| Si pierde su historial, arranca con un nombre nuevo | `lib/doc/bcast.ex:26`: la época se guarda junto al historial. Si el historial está dañado, `lib/doc/replica.ex:120` borra la época |
| Valida cada mensaje antes de aplicarlo | `lib/doc/replica.ex:284` → `lib/doc/wire.ex:32`, `:38`, `:44` (`parse`) |
| Un mensaje inválido se ignora y la réplica sigue funcionando | `lib/doc/replica.ex:358` (`ignore`), `:302`, `:319` |
| `Doc.status()`, `Doc.watch()`, `Doc.history()` | `lib/doc/replica.ex:226` (status), `lib/opdoc.ex:64` (watch) y `lib/doc/replica.ex:374` (aviso de cambios), `lib/doc/replica.ex:224` (history) |
