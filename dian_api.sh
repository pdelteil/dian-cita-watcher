#!/bin/bash
# dian_api.sh — minimal client for the DIAN appointment API (agendamiento.dian.gov.co)
#
# The app is a generic "Player" engine: one endpoint, POST /Player.aspx/ValidadorValidar,
# where the operation is respuestaBase.DetalleAdicional and the args are ObjetosEncontrados[].
#
#   bootstrap                       -> session cookie + anticsrf token + cadenaSW
#   call <handler> <arg-json-array> -> raw JSON of one handler
#
# Usage:  . dian_api.sh ; dian_bootstrap ; dian_call manejadorEncontroDepartamentos '[]'
set -u

DIAN_BASE=${DIAN_BASE:-https://agendamiento.dian.gov.co}
DIAN_UA=${DIAN_UA:-'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36'}
DIAN_DIR=${DIAN_DIR:-$HOME/daniela_claude/artifacts/dian_cita}
DIAN_JAR=$DIAN_DIR/.jar
DIAN_HDR=$DIAN_DIR/.hdr
DIAN_TOKF=$DIAN_DIR/.tok
mkdir -p "$DIAN_DIR"

# The CSRF token is single-use and rotates on every response, so it is kept in a FILE:
# callers run dian_call inside $( ), and a subshell's variable update would be discarded.
dian_tok() { cat "$DIAN_TOKF" 2>/dev/null; }

# --- bootstrap: session, one-shot CSRF token, and the two config blobs the API needs ---
dian_bootstrap() {
  rm -f "$DIAN_JAR"
  local html
  html=$(curl -sS -c "$DIAN_JAR" -A "$DIAN_UA" "$DIAN_BASE/?recurso=CitasDIAN")
  DIAN_TOK=$(printf '%s' "$html" | tr '<' '\n' \
             | grep -o 'name="anticsrf"[^>]*' | grep -o 'value="[^"]*"' \
             | sed 's/value="//;s/"//')
  [ -n "$DIAN_TOK" ] || { echo "dian_bootstrap: no anticsrf token" >&2; return 1; }
  printf '%s' "$DIAN_TOK" > "$DIAN_TOKF"

  # full app definition (~500 KB) — holds both validators' ObjetoBase
  curl -sS -b "$DIAN_JAR" -c "$DIAN_JAR" -A "$DIAN_UA" \
    -X POST "$DIAN_BASE/Player.aspx/ObtenerConfiguracion" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "RequestVerificationToken: $(dian_tok)" -H "g-recaptcha-response: " \
    -H "Origin: $DIAN_BASE" -H "Referer: $DIAN_BASE/?recurso=CitasDIAN" \
    --data-raw '{"rutaRecurso":"Recursos/CitasDIAN/","nombreRecurso":""}' \
    -D "$DIAN_HDR" -o "$DIAN_DIR/.conf.json" || return 1
  dian_rotate

  # CitasWeb ObjetoBase = the `configuracion` the validator expects (Acciones* emptied: client-only UI)
  # Digiturno5.InfoServicioWeb = `cadenaSW`, required by the date/time/create handlers
  jq -r '.d|fromjson|.ValidadoresDeDatos' "$DIAN_DIR/.conf.json" > "$DIAN_DIR/.vals.json"
  jq -c '(map(select(.NombreArchivo=="ValidadorDatos.CitasWeb"))[0].ObjetoBase)
         | with_entries(if (.key|startswith("Acciones")) then .value=[] else . end)' \
     "$DIAN_DIR/.vals.json" > "$DIAN_DIR/.conf_citasweb.json"
  DIAN_CADENA_SW=$(jq -r 'map(select(.NombreArchivo=="ValidadorDatos.Digiturno5"))[0].ObjetoBase.InfoServicioWeb' "$DIAN_DIR/.vals.json")
  DIAN_PROVEEDORES=$(jq -r 'map(select(.NombreArchivo=="ValidadorDatos.Digiturno5"))[0].ObjetoBase.ValidaConServicioProveedores' "$DIAN_DIR/.vals.json")
  export DIAN_CADENA_SW DIAN_PROVEEDORES
}

# the CSRF token is single-use: every response carries the next one in X-token
dian_rotate() {
  local new
  new=$(tr -d '\r' < "$DIAN_HDR" | grep -i '^X-token:' | tail -1 | awk '{print $2}')
  [ -n "${new:-}" ] && printf '%s' "$new" > "$DIAN_TOKF"
  return 0
}

# dian_call <handler> <ObjetosEncontrados as compact JSON array>
dian_call() {
  local handler="$1" args="$2" body
  body=$(jq -nc --arg h "$handler" --argjson a "$args" \
           --slurpfile c "$DIAN_DIR/.conf_citasweb.json" \
           '{nombre:"ValidadorDatos.CitasWeb",configuracion:$c[0],
             respuestaBase:{Fuente:"Validador",Encontrado:false,
                            DetalleAdicional:$h,Recurso:"CitasDIAN",
                            ObjetosEncontrados:$a}}')
  curl -sS -b "$DIAN_JAR" -c "$DIAN_JAR" -A "$DIAN_UA" \
    -X POST "$DIAN_BASE/Player.aspx/ValidadorValidar" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "RequestVerificationToken: $(dian_tok)" -H "g-recaptcha-response: " \
    -H "Origin: $DIAN_BASE" -H "Referer: $DIAN_BASE/?recurso=CitasDIAN" \
    --data-raw "$body" -D "$DIAN_HDR" | jq -r '.d // empty'
  dian_rotate
}

# ---- the appointment object every handler takes as ObjetosEncontrados[0] ----
# dian_cita <idEspecialidad> <idOficina> <idCiudad> <idEstado> [fecha ISO] [nombreCola] [nombreOficina]
dian_cita() {
  jq -nc --argjson esp "$1" --arg ofi "$2" --argjson ciu "$3" --argjson est "$4" \
         --arg fec "${5:-2001-01-01T17:00:00.000Z}" \
         --arg ncola "${6:-}" --arg nofi "${7:-}" \
    '{CodigoCita:null,CodigoCitaModificada:null,
      Cola:{IdEspecialidad:$esp,Nombre:(if $ncola=="" then null else $ncola end)},
      TipoEspecialidad:{IdTipoEspecialidad:1,Nombre:"Presencial"},
      Oficina:{IdOficina:$ofi,Nombre:(if $nofi=="" then null else $nofi end),Latitud:0,Longitud:0},
      UsuarioCliente:{IdTipoCliente:"1",IdTipoDocumento:0,Nombre:null,Apellido:null,
                      NumeroDocumento:null,CorreoElectronico:null,Celular:null,Telefono:null,
                      Direccion:null,IdCiudad:$ciu,IdEstado:$est,AceptaPoliticaDatos:false},
      Fecha:$fec,Hora:"2001-01-01T17:00:00.000Z",IdAgenda:0,
      Estado:{IdEstado:0,Nombre:null},Funcionario:{NombreAMostrar:null,Id:null},
      Archivo:null,CamposAdicionales:null,EsFlujoCitaCreacion:"true",IntegracionD5:true}'
}

# dian_fechas <cita-json>  -> available DATES
dian_fechas() {
  dian_call manejadorEncontroFechas \
    "$(jq -nc --arg c "$1" --arg sw "$DIAN_CADENA_SW" --argjson p "$DIAN_PROVEEDORES" '[$c,$sw,$p]')"
}

# dian_horas <cita-json with Fecha set>  -> available TIMES for that date
dian_horas() {
  dian_call manejadorEncontroHoras "$(jq -nc --arg c "$1" '[$c]')"
}
