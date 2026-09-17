#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Overnight chain: everything that does NOT need the exhausted gpt-oss-120b
# daily budget. Pass A resumes tomorrow from its cache.
#
# Stages here are CPU-only (embeddings, clustering, dictionaries, topic model)
# and are ordered so nothing competes for cores with the embedding run that is
# still finishing.
# ---------------------------------------------------------------------------
set -u
cd "D:/GERMANY/NOTES/R"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "waiting for the embedding run to finish"
while [ ! -f data/derived/embeddings.parquet ]; do sleep 60; done
# make sure the file is fully written before anything reads it
prev=0
while :; do
  cur=$(stat -c %s data/derived/embeddings.parquet 2>/dev/null || echo 0)
  [ "$cur" = "$prev" ] && [ "$cur" -gt 1000000 ] && break
  prev=$cur; sleep 30
done
log "embeddings ready ($(du -h data/derived/embeddings.parquet | cut -f1))"

log "S8  lexical layer (dictionaries over the full corpus)"
Rscript R/08_lexicon.R > logs_lexicon.txt 2>&1
log "S8  done -> $(grep -c . logs_lexicon.txt) lines"

log "S11b data-driven topics (HDBSCAN over embeddings)"
python R/11b_topics_embed.py 120000 > logs_topics_embed.txt 2>&1
log "S11b done"

log "S11 seeded LDA"
Rscript R/11_topics.R > logs_topics.txt 2>&1
log "S11 done"

log "overnight chain complete"
