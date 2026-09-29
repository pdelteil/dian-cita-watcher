# DIAN cita watcher

Monitorea el portal de agendamiento de citas de la DIAN (`agendamiento.dian.gov.co`) y te
**avisa apenas se libera un cupo** para el servicio y la ciudad que te interesan. Está hecho
solo con `bash` + `curl` (sin navegador ni dependencias más allá de `curl`) y se ejecuta con
una tarea de `cron`.

**No es un exploit**: consulta la misma API pública de agendamiento que usa la página web y te
notifica cuando aparece una cita disponible. Útil porque los cupos de la DIAN se agotan en
segundos y revisar a mano es inviable.

## Archivos

| Archivo | Función |
|---------|---------|
| `dian_api.sh` | Cliente `curl` (para hacer `source`) de la API de agendamiento (`dian_bootstrap`, `dian_call`, `dian_cita`, `dian_fechas`, `dian_horas`). Todo el portal es un solo endpoint: `POST /Player.aspx/ValidadorValidar`. |
| `dian_watch.sh` | Motor de monitoreo: `servicios`, `ciudades <idEsp>`, `city <idEsp> <nombre>`, `oficinas`, `check`, `watch [segundos]`. `check` revisa cada objetivo de `watch.conf` y solo dispara la notificación cuando aparece una **nueva** fecha+hora (comparada contra `state.json`). |
| `dian_cron.sh` | Envoltorio para cron — un `check` sin solapamiento (protegido con `flock`). |
| `watch.conf.example` | Lista de objetivos de ejemplo (cópiala a `watch.conf`). |
| `notify_telegram.sh.example` | Hook de notificación de ejemplo (cópialo a `notify_telegram.sh` y pon tu token). |

## Requisitos

- `bash`, `curl` y `python3` (usado para armar/parsear el JSON de las peticiones).

## Instalación y uso

```bash
cp watch.conf.example watch.conf                 # edita tu(s) objetivo(s)
cp notify_telegram.sh.example notify_telegram.sh # agrega tu token y chat de Telegram
chmod +x *.sh
./dian_watch.sh check                            # una consulta manual
```

### Formato de `watch.conf`

```
idEspecialidad|idOficina|idCiudad|idDepartamento|idRegional|etiqueta
```

Descubre los códigos con los comandos de ayuda:

```bash
./dian_watch.sh servicios            # lista los ids de servicio (especialidad)
./dian_watch.sh ciudades <idEsp>     # ciudades con agenda abierta para ese servicio
./dian_watch.sh city <idEsp> <nombre> # resuelve una ciudad y escribe sus oficinas en watch.conf
```

`idOficina='*'` significa "re-descubrir las oficinas en cada consulta" — útil cuando tu ciudad
todavía no tiene agenda abierta (por lo que no hay ninguna oficina que fijar) y quieres cazar el
cupo en el instante en que aparezca, incluso si abren una sede nueva.

### Notificaciones

El hook por defecto es `notify_telegram.sh` (puedes cambiar la ruta con la variable
`$DIAN_NOTIFY`). Recibe el texto de la alerta como `$1`, así que puedes reemplazarlo por
cualquier canal (correo, Slack, etc.). El repositorio **no incluye ningún token**: copia
`notify_telegram.sh.example` y pon el tuyo.

### Ejecutar con cron (cada 15 minutos)

```
*/15 * * * * /ruta/al/dian_cita/dian_cron.sh
```

## Notas

- La lista de ciudades que devuelve la API depende de la **disponibilidad**: una ciudad solo
  aparece para un servicio mientras tiene agenda abierta en ese momento, así que una respuesta
  vacía es el estado normal de espera.
- `ErrorString: "No hay agendas disponibles"` = no hay nada abierto (normal). En cambio
  `"error en la aplicación - ID Mensaje: <guid>"` significa que la petición estaba mal formada.
- El notificador guarda silencio a menos que aparezca un cupo **nuevo** (diferencia de estado),
  por lo que es seguro ejecutarlo con frecuencia.

## Aviso

Herramienta personal para consultar disponibilidad de citas en un portal público. Úsala de forma
responsable y respeta los términos de uso de la DIAN; no está afiliada a la DIAN.
