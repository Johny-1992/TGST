#!/bin/bash
# =====================================================
# auto_deploy_tgst_final.sh - Déploiement TGST 24h/24
# =====================================================

echo "🚀 Auto-déploiement TGST 24h/24 lancé !"

# ----------------------------
# 1️⃣ Vérification des mises à jour Git
# ----------------------------
echo "⏱ Vérification des mises à jour Git..."
git fetch origin main
git reset --hard origin/main
echo "🚀 Repo TGST déjà à jour"

# ----------------------------
# 2️⃣ Placement et vérification des fichiers existants
# ----------------------------
echo "📂 Placement des fichiers existants..."
mkdir -p public data api assets css scripts

# Fichiers principaux
[ -f index.html ] && mv index.html ./public/
[ -f dashboard.html ] && mv dashboard.html ./public/
[ -f bot.html ] && mv bot.html ./public/
[ -f app.html ] && mv app.html ./public/

# Scripts et déploiement
[ -f deploy_tgst.sh ] && mv deploy_tgst.sh ./scripts/
[ -f auto_deploy_tgst_final.sh ] && mv auto_deploy_tgst_final.sh ./scripts/

# Assets
[ -f TGST_logo.png ] && mv TGST_logo.png ./assets/logo.png

# Données et configurations
[ -f tokemics.json ] && mv tokemics.json ./data/
[ -f rewards.json ] && mv rewards.json ./data/
[ -f .env ] && cp .env ./

echo "✅ Fichiers existants et env appliqués"

# ----------------------------
# 3️⃣ Génération des éléments manquants
# ----------------------------
echo "⚡ Génération des éléments manquants..."

# Placeholders pour fichiers manquants
[ ! -f public/schema.jsonld ] && echo '{"@context":"https://schema.org","@type":"Project","name":"TGST","url":"https://tgst.vercel.app"}' > public/schema.jsonld
[ ! -f public/sitemap.xml ] && echo '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://tgst.vercel.app/</loc></url></urlset>' > public/sitemap.xml
[ ! -f public/robots.txt ] && echo -e "User-agent: *\nDisallow:" > public/robots.txt

# Meta SEO et Open Graph
[ ! -f public/meta.html ] && cat <<EOL > public/meta.html
<meta name="description" content="TGST - Le token révolutionnaire pour les récompenses sur mobile, e-bank, casino, supermarché et plus.">
<meta property="og:title" content="TGST">
<meta property="og:description" content="TGST - Le token révolutionnaire pour les récompenses sur mobile, e-bank, casino, supermarché et plus.">
<meta property="og:url" content="https://tgst.vercel.app/">
<meta property="og:type" content="website">
EOL

echo "✅ Placeholders et SEO générés"

# ----------------------------
# 4️⃣ Préparation Bot TGST
# ----------------------------
echo "🤖 Vérification du Bot TGST..."
BOT_TOKEN=$(grep BOT_TOKEN .env | cut -d '=' -f2)
if [ -z "$BOT_TOKEN" ]; then
    echo "⚠️ Bot token non trouvé dans .env"
else
    echo "✅ Bot TGST prêt à utiliser avec token"
fi

# ----------------------------
# 5️⃣ Déploiement sur Vercel
# ----------------------------
echo "🚀 Déploiement TGST sur Vercel..."
vercel --prod --yes
PROD_URL=$(vercel --prod --yes --confirm | grep "Production:" | awk '{print $2}')
echo "✅ TGST en ligne : $PROD_URL"

# ----------------------------
# 6️⃣ Auto-vérification toutes les 5 minutes
# ----------------------------
while true; do
    echo "⏱ Vérification des nouvelles mises à jour depuis GitHub..."
    git fetch origin main
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    if [ $LOCAL != $REMOTE ]; then
        echo "⚡ Nouveaux commits détectés, déploiement en cours..."
        git reset --hard origin/main
        ./scripts/auto_deploy_tgst_final.sh &
    else
        echo "⏳ Aucun nouveau commit. Prochain contrôle dans 300 secondes."
    fi
    sleep 300
done

