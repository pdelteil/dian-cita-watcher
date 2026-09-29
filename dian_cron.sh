#!/bin/bash
# Cron wrapper: one poll of watch.conf, never overlapping a previous run.
cd "$(dirname "$0")" || exit 1
exec flock -n .lock ./dian_watch.sh check >> cron.log 2>&1
