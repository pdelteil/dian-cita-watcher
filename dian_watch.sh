#!/bin/bash
# dian_watch.sh — watch agendamiento.dian.gov.co for appointment slots and alert on Telegram.
#
# Alerts only on NEW availability (date+time it hasn't already reported), so a slot that
# stays open doesn't re-notify. State lives in state.json next to this script.
#
#   ./dian_watch.sh servicios                       list services (IdEspecialidad)
#   ./dian_watch.sh ciudades <esp>                  cities offering that service
#   ./dian_watch.sh oficinas <esp> <ciu> <dep> <reg>  offices in that city
#   ./dian_watch.sh check                           one poll of everything in watch.conf
#   ./dian_watch.sh watch [seconds]                 loop (default 900s = 15 min)
#
# watch.conf lines:  <idEspecialidad>|<idOficina>|<idCiudad>|<idDepartamento>|<label>
set -u
cd "$(dirname "$0")"
. ./dian_api.sh

CONF=${DIAN_CONF:-./watch.conf}
STATE=./state.json
LOG=./watch.log
NOTIFY=${DIAN_NOTIFY:-$HOME/daniela_claude/notify_telegram.sh}
CAT=${DIAN_CAT:-1}        # category code (1 = RUT y orientación TAC)
TIPO=${DIAN_TIPO:-1}      # 1 = Persona Natural

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

case "${1:-check}" in
  servicios)
    dian_bootstrap || exit 1
    Z=$(dian_cita 0 0 0 0)
    dian_call manejadorEncontroColas "$(jq -nc --arg c "$Z" --arg t "$TIPO" --arg k "$CAT" '[$c,"Nombre",$t,$k,"1"]')" \
      | jq -r '.ObjetosEncontrados[0][]? | "\(.IdEspecialidad)\t\(.Nombre)"'
    ;;

  ciudades)
    ESP=${2:?need idEspecialidad}
    dian_bootstrap || exit 1
    dian_call ManejadorEncontroCiudadesXCatXEspXTipoPersona \
      "$(jq -nc --arg k "$CAT" --arg e "$ESP" --arg t "$TIPO" '[$k,$e,$t]')" \
      | jq -r '.ObjetosEncontrados[0][]? |
               "ciudad=\(.IdCiudad)\tdepto=\(.Departamento.IdDepartamento)\tregional=\(.Regional.IdRegional)\t\(.Nombre) (\(.Departamento.Nombre))"'
    ;;

  city)
    # city <esp> <name-fragment>  -> resolve the city and write watch.conf with ALL its offices
    ESP=${2:?need idEspecialidad}; NAME=${3:?need city name fragment}
    dian_bootstrap || exit 1
    # Preferred source: cities that currently have an open agenda for this service.
    ROW=$(dian_call ManejadorEncontroCiudadesXCatXEspXTipoPersona \
            "$(jq -nc --arg k "$CAT" --arg e "$ESP" --arg t "$TIPO" '[$k,$e,$t]')" \
          | jq -c --arg n "$NAME" '.ObjetosEncontrados[0][]?
              | select(.Nombre|ascii_downcase|contains($n|ascii_downcase))' | head -1)
    # That list is availability-driven, so a city with zero open slots today is simply absent —
    # which is the very case we want to watch. Fall back to the full per-department city list.
    if [ -z "$ROW" ]; then
      echo "not in the open-agenda list for service $ESP; searching all departments..." >&2
      for D in $(dian_call manejadorEncontroDepartamentos '[]' \
                 | jq -r '.ObjetosEncontrados[0][]?|.IdDepartamento'); do
        ROW=$(dian_call manejadorEncontroCiudades "$(jq -nc --arg d "$D" '[$d]')" \
              | jq -c --arg n "$NAME" '.ObjetosEncontrados[0][]?
                  | select(.Nombre|ascii_downcase|contains($n|ascii_downcase))' | head -1)
        [ -n "$ROW" ] && break
        sleep 1
      done
    fi
    [ -n "$ROW" ] || { echo "no city matching '$NAME' found at all" >&2; exit 1; }
    CIU=$(jq -r .IdCiudad <<<"$ROW"); DEP=$(jq -r .Departamento.IdDepartamento <<<"$ROW")
    REG=$(jq -r .Regional.IdRegional <<<"$ROW"); CNAME=$(jq -r .Nombre <<<"$ROW")
    SNAME=$(dian_call manejadorEncontroColas \
              "$(jq -nc --arg c "$(dian_cita 0 0 0 0)" --arg t "$TIPO" --arg k "$CAT" '[$c,"Nombre",$t,$k,"1"]')" \
            | jq -r --arg e "$ESP" '.ObjetosEncontrados[0][]?|select(.IdEspecialidad==($e|tonumber))|.Nombre')
    echo "city: $CNAME (ciudad=$CIU depto=$DEP regional=$REG)"
    C=$(dian_cita "$ESP" 0 "$CIU" "$DEP")
    OFIS=$(dian_call manejadorEncontroOficinas "$(jq -nc --arg c "$C" --arg r "$REG" '[$c,$r]')" \
           | jq -r '.ObjetosEncontrados[0][]? | "\(.IdOficina)\t\(.Nombre)"')
    { echo "# idEspecialidad|idOficina|idCiudad|idDepartamento|idRegional|label"
      echo "# service $ESP = $SNAME"
      echo "# idOficina '*' = discover this city's offices on every poll (use when the"
      echo "# city has NO open agendas today, so no office can be pinned yet)"
      echo "$ESP|*|$CIU|$DEP|$REG|$CNAME (any office) - ${SNAME:0:40}"
      if [ -n "$OFIS" ]; then
        while IFS=$'\t' read -r O ON; do
          echo "#$ESP|$O|$CIU|$DEP|$REG|$ON ($CNAME) - ${SNAME:0:40}"
        done <<< "$OFIS"
      else
        echo "# (no offices listed right now: \"no hay agendas disponibles\" for this service here)"
      fi
    } > "$CONF"
    echo "wrote $CONF:"; cat "$CONF"
    ;;

  oficinas)
    ESP=${2:?esp}; CIU=${3:?ciudad}; DEP=${4:?depto}; REG=${5:?regional}
    dian_bootstrap || exit 1
    C=$(dian_cita "$ESP" 0 "$CIU" "$DEP")
    dian_call manejadorEncontroOficinas "$(jq -nc --arg c "$C" --arg r "$REG" '[$c,$r]')" \
      | jq -r '.ObjetosEncontrados[0][]? | "\(.IdOficina)\t\(.Nombre)\t\(.Direccion)"'
    ;;

  check)
    [ -f "$CONF" ] || { echo "no $CONF — run: ./dian_watch.sh city <esp> <city>" >&2; exit 1; }
    if ! grep -qE '^[0-9]' "$CONF"; then log "no targets enabled in $CONF — nothing to check"; exit 0; fi
    [ -f "$STATE" ] || echo '{}' > "$STATE"
    dian_bootstrap || { log "bootstrap FAILED"; exit 1; }
    NEW_ANY=0

    # Phase 1 — resolve targets. A '*' office means the city had no open agenda when it was
    # configured, so ask each poll which offices it has now; an empty answer is the normal
    # "still nothing" state, not an error. Every office found becomes its own target.
    TARGETS=$(mktemp)
    while IFS='|' read -r ESP OFI CIU DEP REG LABEL; do
      case "$ESP" in ''|\#*) continue ;; esac
      if [ "$OFI" != '*' ]; then
        printf '%s|%s|%s|%s|%s\n' "$ESP" "$OFI" "$CIU" "$DEP" "$LABEL" >> "$TARGETS"
        continue
      fi
      CD=$(dian_cita "$ESP" 0 "$CIU" "$DEP")
      OL=$(dian_call manejadorEncontroOficinas "$(jq -nc --arg c "$CD" --arg r "$REG" '[$c,$r]')" \
           | jq -r '.ObjetosEncontrados[0][]? | "\(.IdOficina)\t\(.Nombre)"' 2>/dev/null)
      if [ -z "$OL" ]; then log "$LABEL: no offices open yet"; sleep 3; continue; fi
      log "$LABEL: offices OPEN -> $(printf '%s' "$OL" | tr '\n\t' ' /')"
      while IFS=$'\t' read -r O ON; do
        printf '%s|%s|%s|%s|%s\n' "$ESP" "$O" "$CIU" "$DEP" "$ON - ${LABEL##*- }" >> "$TARGETS"
      done <<< "$OL"
      sleep 2
    done < "$CONF"

    # Phase 2 — price every resolved target
    while IFS='|' read -r ESP OFI CIU DEP LABEL; do
      [ -n "${ESP:-}" ] || continue
      KEY="$ESP/$OFI"
      C=$(dian_cita "$ESP" "$OFI" "$CIU" "$DEP")
      RES=$(dian_fechas "$C")
      H=$(printf '%s' "$RES" | jq -r '.DetalleAdicional // "?"' 2>/dev/null)
      if [ "$H" != "manejadorEncontroFechas" ]; then
        log "$LABEL: no dates ($H) $(printf '%s' "$RES" | jq -r '.ErrorString // ""' 2>/dev/null | head -c 80)"
        sleep 3; continue
      fi
      FECHAS=$(printf '%s' "$RES" | jq -r '.ObjetosEncontrados[0][]?' 2>/dev/null)
      [ -z "$FECHAS" ] && { log "$LABEL: 0 dates"; sleep 3; continue; }

      # for each open date, pull the times, then diff against what we already reported
      SLOTS=""
      for F in $FECHAS; do
        D=${F%%T*}
        CF=$(dian_cita "$ESP" "$OFI" "$CIU" "$DEP" "${D}T05:00:00.000Z")
        HR=$(dian_horas "$CF" | jq -r '.ObjetosEncontrados[0][]? | "\(.Contenido)|\(.NumeroAgendasDisponibles)"' 2>/dev/null)
        if [ -n "$HR" ]; then
          while IFS='|' read -r T N; do SLOTS="$SLOTS$D $T ($N)"$'\n'; done <<< "$HR"
        else
          SLOTS="$SLOTS$D (no times)"$'\n'
        fi
        sleep 2
      done
      SLOTS=$(printf '%s' "$SLOTS" | sed '/^$/d' | sort -u)

      SEEN=$(jq -r --arg k "$KEY" '.[$k] // ""' "$STATE")
      FRESH=$(comm -23 <(printf '%s\n' "$SLOTS") <(printf '%s\n' "$SEEN" | sed '/^$/d' | sort -u))

      if [ -n "$FRESH" ]; then
        NEW_ANY=1
        log "$LABEL: NEW -> $(printf '%s' "$FRESH" | tr '\n' ';')"
        # One line per date (count + the first few times) — a city opening from zero can free
        # 80+ slots, which would blow past Telegram's 4096-char limit as a raw list.
        # 12h times sort lexicographically wrong ("10:45 AM" < "8:15 AM"), and the EARLIEST
        # slot is the one that matters, so convert to minutes-past-midnight and sort on that.
        SUMMARY=$(printf '%s\n' "$FRESH" \
          | awk '{ split($2,a,":"); h=a[1]+0; m=a[2]+0;
                   if ($3=="PM" && h!=12) h+=12; if ($3=="AM" && h==12) h=0;
                   printf "%s\t%05d\t%s %s %s\n", $1, h*60+m, $2, $3, $4 }' \
          | sort -k1,1 -k2,2n \
          | awk -F'\t' '
              { n[$1]++; if (c[$1]<3) { t[$1]=t[$1] (c[$1]++?", ":"") $3 }
                if (!($1 in seen)) { seen[$1]=1; ord[++k]=$1 } }
              END { for (i=1;i<=k;i++) { d=ord[i];
                      printf "%s: %d cupo(s) — %s%s\n", d, n[d], t[d], (n[d]>3?", …":"") } }')
        MSG="*DIAN cita disponible*
$LABEL

$SUMMARY

https://agendamiento.dian.gov.co/"
        [ -x "$NOTIFY" ] && "$NOTIFY" "$MSG" >> "$LOG" 2>&1 || log "notify script missing: $NOTIFY"
      else
        log "$LABEL: $(printf '%s\n' "$SLOTS" | grep -c .) slots, none new"
      fi
      jq --arg k "$KEY" --arg v "$SLOTS" '.[$k]=$v' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      sleep 5
    done < "$TARGETS"
    rm -f "$TARGETS"
    ;;

  watch)
    IV=${2:-900}
    log "watch loop every ${IV}s"
    while :; do "$0" check; sleep "$IV"; done
    ;;

  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
