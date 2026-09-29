# DIAN cita watcher

Watches Colombia's DIAN appointment portal (`agendamiento.dian.gov.co`) and sends a
notification the moment a matching appointment slot opens up. Pure `bash` + `curl`
(no browser, no dependencies beyond `curl`), driven by a small cron job.

It is **not** an exploit — it polls the same public scheduling API the website uses and
alerts you when a slot for the service/city you care about becomes bookable.

## Files

| File | Purpose |
|------|---------|
| `dian_api.sh` | Sourceable curl client for the DIAN scheduling API (`dian_bootstrap`, `dian_call`, `dian_cita`, `dian_fechas`, `dian_horas`). The whole portal is one endpoint: `POST /Player.aspx/ValidadorValidar`. |
| `dian_watch.sh` | Watch driver: `servicios`, `ciudades <esp>`, `city <esp> <name>`, `oficinas`, `check`, `watch [seconds]`. `check` polls every target in `watch.conf` and fires the notifier only on a **new** date+time (diffed against `state.json`). |
| `dian_cron.sh` | Cron wrapper — one non-overlapping `check` (flock-guarded). |
| `watch.conf.example` | Example target list (copy to `watch.conf`). |
| `notify_telegram.sh.example` | Example notification hook (copy to `notify_telegram.sh`, add your token). |

## Setup

```bash
cp watch.conf.example watch.conf                 # edit to your target(s)
cp notify_telegram.sh.example notify_telegram.sh # add your Telegram bot token + chat id
chmod +x *.sh
./dian_watch.sh check                            # one manual poll
```

### `watch.conf` format

```
idEspecialidad|idOficina|idCiudad|idDepartamento|idRegional|label
```

Discover the codes with the helper commands:

```bash
./dian_watch.sh servicios            # list service (especialidad) ids
./dian_watch.sh ciudades <idEsp>     # cities with an open agenda for that service
./dian_watch.sh city <idEsp> <name>  # resolve a city + write its offices to watch.conf
```

`idOficina='*'` means "re-discover offices every poll" — useful when your city has no
open agenda yet (so no office can be pinned) and you want to catch a slot the instant one
appears.

### Cron (poll every 15 minutes)

```
*/15 * * * * /path/to/dian_cita/dian_cron.sh
```

## Notes

- The city list returned by the API is **availability-driven**: a city only appears for a
  service while it currently has an open agenda, so an empty result is the normal quiet state.
- `ErrorString: "No hay agendas disponibles"` = genuinely nothing open (normal). An
  `"error en la aplicación - ID Mensaje: <guid>"` means the request itself was malformed.
- The notifier is deliberately silent unless a **new** slot appears (state diff), so it's
  safe to run frequently.
