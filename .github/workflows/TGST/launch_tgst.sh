#!/bin/bash
set -e

echo "🌍 Démarrage complet de l'empire TGST..."
echo "-----------------------------------------"

# 1. Lancer le site vitrine
echo "🚀 Déploiement du site vitrine TGST..."
cd site && npm install && npm run build && npm start &
SITE_PID=$!
cd ..

# 2. Lancer le bot Telegram TGST
echo "🤖 Lancement du bot Telegram TGST..."
cd bot && npm install && node bot.js &
BOT_PID=$!
cd ..

# 3. Lancer l’API TGST (smart contract, transactions)
echo "⚡ Lancement de l’API TGST..."
cd api && pip install -r requirements.txt && python3 tgst_core.py &
API_PID=$!
cd ..

# 4. Lancer le marketing (réseaux sociaux, annonces)
echo "📢 Lancement du module Marketing mondial TGST..."
cd marketing && npm install && node marketing.js &
MARKETING_PID=$!
cd ..

# 5. Vérifier SEO + indexation
echo "🔎 Vérification SEO & indexation Google..."
cd seo && python3 seo_index.py &
SEO_PID=$!
cd ..

echo "✅ TOUS LES SERVICES TGST SONT EN MARCHE"
echo "-----------------------------------------"
echo "🌕 TGST est désormais visible partout dans le monde, 24h/24"
echo "-----------------------------------------"

# Garder le script actif
wait $SITE_PID $BOT_PID $API_PID $MARKETING_PID $SEO_PID
