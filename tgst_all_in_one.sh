#!/usr/bin/env bash
set -euo pipefail

# ==============================
# TGST - ALL IN ONE DEPLOY (TERMUX)
# Philosophie :
# - Les fichiers du repo sont la source de vérité.
# - On complète uniquement ce qui manque (SEO/OG/sitemap/robots/404).
# - On ne touche jamais aux secrets existants.
# - Déploiement Vercel en production.
# - Option --watch pour tourner en continu (auto-pull + redeploy).
# ==============================

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; NC="\033[0m"
say() { echo -e "${GREEN}🚀 $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err() { echo -e "${RED}❌ $*${NC}" >&2; }

WATCH_MODE="${1:-}"

# 0) Pré-requis rapides
say "Vérification des prérequis (git, node, yarn, vercel)…"
command -v git >/dev/null || { err "git manquant"; exit 1; }
command -v node >/dev/null || { err "node manquant"; exit 1; }
if ! command -v yarn >/dev/null; then
  warn "yarn absent → utilisation npm"; USE_NPM=1
else
  USE_NPM=0
fi
if ! command -v vercel >/dev/null; then
  warn "Vercel CLI non trouvé → installation via yarn global"
  if command -v yarn >/dev/null; then
    yarn global add vercel
  else
    npm install -g vercel
  fi
fi

# 1) Synchronisation du repo (main = vérité)
say "Sync Git (origin/main)…"
git fetch origin main
git reset --hard origin/main

# 2) Respect des fichiers existants (on ne déplace ni n’écrase)
say "Respect des fichiers existants (assets/, css/, *.html, *.js, *.md)…"
[ -d assets ] || mkdir -p assets
[ -d css ] || mkdir -p css

# 3) Environnement : on n’écrase jamais .env existant
if [ ! -f .env ] && [ -f .env.example ]; then
  say "Création .env depuis .env.example (sans écraser d’existants)…"
  cp -n .env.example .env || true
else
  say ".env déjà présent ou pas d’exemple → OK (aucun écrasement)."
fi

# 4) Génération COMPLÉMENTS manquants (modifiables, sans casser l’écosystème)
# 4.1 – SEO/OG injection si manquants, uniquement sur fichiers présents
inject_meta () {
  local f="$1"
  [ -f "$f" ] || return 0
  # On insère des metas si pas déjà présents
  if ! grep -qi 'og:title' "$f"; then
    say "SEO/OG → injection dans $f (non invasif)"
    # On injecte en tête (juste après <head> si présent, sinon tout début)
    if grep -qi "<head" "$f"; then
      # On insère juste après la 1ère balise <head>
      awk 'BEGIN {done=0}
        /<head[^>]*>/ && done==0 {
          print $0;
          print "  <meta name=\"description\" content=\"TGST — Token Global Smart Trade. Récompenses liées aux consommations mobiles, mobile money, paris sportifs, e-bank, casino, supermarché.\" />";
          print "  <meta property=\"og:title\" content=\"TGST — Token Global Smart Trade\" />";
          print "  <meta property=\"og:description\" content=\"TGST redistribue des récompenses au cœur d’un écosystème interconnecté, avec le jeton TGST au centre.\" />";
          print "  <meta property=\"og:type\" content=\"website\" />";
          print "  <meta property=\"og:url\" content=\"https://tgst.vercel.app/\" />";
          print "  <meta property=\"og:image\" content=\"/assets/logo.png\" />";
          print "  <meta name=\"twitter:card\" content=\"summary_large_image\" />";
          done=1; next
        }
        {print $0}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      # Pas de <head>, on préfixe prudemment
      cat > "$f.tmp" <<'EOF'
<meta name="description" content="TGST — Token Global Smart Trade. Récompenses liées aux consommations mobiles, mobile money, paris sportifs, e-bank, casino, supermarché." />
<meta property="og:title" content="TGST — Token Global Smart Trade" />
<meta property="og:description" content="TGST redistribue des récompenses au cœur d’un écosystème interconnecté, avec le jeton TGST au centre." />
<meta property="og:type" content="website" />
<meta property="og:url" content="https://tgst.vercel.app/" />
<meta property="og:image" content="/assets/logo.png" />
<meta name="twitter:card" content="summary_large_image" />
EOF
      cat "$f" >> "$f.tmp" && mv "$f.tmp" "$f"
    fi
  fi
}

say "Injection SEO/OG si manquants (index.html, dashboard.html, app.html, bot.html)…"
inject_meta "index.html"
inject_meta "dashboard.html"
inject_meta "app.html"
inject_meta "bot.html"

# 4.2 – sitemap.xml (si absent)
if [ ! -f sitemap.xml ]; then
  say "Création sitemap.xml (absent)"
  cat > sitemap.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://tgst.vercel.app/</loc></url>
  <url><loc>https://tgst.vercel.app/dashboard</loc></url>
  <url><loc>https://tgst.vercel.app/app</loc></url>
  <url><loc>https://tgst.vercel.app/bot</loc></url>
</urlset>
XML
fi

# 4.3 – robots.txt (si absent)
if [ ! -f robots.txt ]; then
  say "Création robots.txt (absent)"
  cat > robots.txt <<'TXT'
User-agent: *
Allow: /
Sitemap: https://tgst.vercel.app/sitemap.xml
TXT
fi

# 4.4 – 404.html (fallback propre si route inconnue)
if [ ! -f 404.html ]; then
  say "Création 404.html (fallback)"
  cat > 404.html <<'HTML'
<!doctype html><html><head>
<meta charset="utf-8" />
<title>Page non trouvée — TGST</title>
<meta name="robots" content="noindex" />
<link rel="icon" href="/assets/logo.png" />
</head><body style="font-family:system-ui,Arial,sans-serif;padding:40px;">
  <h1>🛰️ Oups, page introuvable</h1>
  <p>Revenir à <a href="/">l’accueil TGST</a></p>
</body></html>
HTML
fi

# 4.5 – vercel.json (routes propres → sert tes pages réelles, pas de placeholder)
if [ ! -f vercel.json ]; then
  say "Création vercel.json (absent) → routes statiques propres"
  cat > vercel.json <<'JSON'
{
  "version": 2,
  "framework": null,
  "builds": [{ "src": "index.html", "use": "@vercel/static" }],
  "routes": [
    { "src": "^/$", "dest": "/index.html" },
    { "src": "^/dashboard$", "dest": "/dashboard.html" },
    { "src": "^/app$", "dest": "/app.html" },
    { "src": "^/bot$", "dest": "/bot.html" },
    { "src": "^/sitemap.xml$", "dest": "/sitemap.xml" },
    { "src": "^/robots.txt$", "dest": "/robots.txt" },
    { "src": "^/(assets/.*)$", "dest": "/$1" },
    { "src": "^/(css/.*)$", "dest": "/$1" },
    { "src": ".*", "dest": "/404.html", "status": 404 }
  ]
}
JSON
else
  say "vercel.json déjà présent → laissé tel quel (source de vérité du repo)."
fi

# 5) Dépendances (si package.json existe)
if [ -f package.json ]; then
  say "Installation des dépendances du projet"
  if [ "$USE_NPM" -eq 1 ]; then
    npm install
  else
    yarn install
  fi
else
  warn "Aucun package.json → site statique pur, c’est OK."
fi

# 6) Lien Vercel (si pas déjà lié)
if [ ! -d .vercel ]; then
  say "Lien Vercel du projet (une seule fois)…"
  vercel link --yes || true
else
  say "Projet déjà lié à Vercel (.vercel présent)."
fi

# 7) Déploiement production
say "Déploiement production Vercel"
vercel --prod --yes

say "🎉 TGST déployé en production (24/7)."

# 8) Mode surveillance continue (optionnel)
if [ "$WATCH_MODE" = "--watch" ]; then
  say "Mode surveillance activé (pull + deploy toutes les 5 minutes si nouveau commit)…"
  while true; do
    echo "⏱  Check updates…"
    git fetch origin main
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    if [ "$LOCAL" != "$REMOTE" ]; then
      say "Nouveaux commits détectés → pull + deploy"
      git reset --hard origin/main
      if [ -f package.json ]; then
        if [ "$USE_NPM" -eq 1 ]; then npm install; else yarn install; fi
      fi
      vercel --prod --yes
      say "✅ Mise à jour déployée"
    else
      echo "⏳ Aucun nouveau commit. Re-vérification dans 300s."
    fi
    sleep 300
  done
else
  say "Mode one-shot terminé. Lance avec './tgst_all_in_one.sh --watch' pour surveiller en continu."
fi
